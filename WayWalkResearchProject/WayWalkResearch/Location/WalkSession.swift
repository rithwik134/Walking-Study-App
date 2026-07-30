import Foundation
import CoreLocation
import Combine

/// Drives one walk: monitors a geofence for exactly one waypoint at a time,
/// plays the correct prompt exactly once when entered, and never repeats a
/// waypoint unless the walk is restarted. Waypoints are handled strictly in
/// sequence — the region for waypoint N+1 is not registered with
/// CLLocationManager until waypoint N has fired — so it is not possible for
/// two regions to compete or for GPS drift near one waypoint to be
/// misread as arrival at another.
///
/// Entering a waypoint's radius does not fire its prompt immediately —
/// arrival must be held continuously for `confirmationDwellTime` first
/// (trigger confirmation). If CoreLocation reports the participant has
/// genuinely left the radius before that window elapses (via didExitRegion,
/// not a raw distance comparison — ordinary GPS noise is too unreliable for
/// that at small radii), the confirmation is cancelled and nothing plays.
///
/// Uses CLLocationManager region monitoring (not continuous distance
/// polling) because region monitoring is designed by Apple to keep working —
/// and to relaunch the app briefly if needed — while the phone is locked or
/// the app is backgrounded, which continuous GPS polling from a suspended
/// app cannot do reliably. Continuous location updates are also requested,
/// in parallel, but purely to feed the debug / test-mode readouts — they no
/// longer make any triggering or cancellation decisions.
@MainActor
final class WalkSession: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var statusMessage = "Not started"
    @Published var lastTriggeredWaypointName: String?
    @Published private(set) var triggeredWaypointIDs: Set<String> = []
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // Debug / test-mode readouts. Purely observational — none of these feed
    // back into triggering logic.
    @Published private(set) var currentAccuracy: CLLocationAccuracy?
    @Published private(set) var currentLatitude: Double?
    @Published private(set) var currentLongitude: Double?
    @Published private(set) var distanceToNext: CLLocationDistance?
    @Published private(set) var isNextWaypointArmed = false
    @Published private(set) var isConfirmingArrival = false
    @Published private(set) var currentWaypointNumber = 0

    private let locationManager = CLLocationManager()
    private let audioPlayer: AudioPromptPlaying
    private var informationLevel: InformationLevel = .navigationOnly

    /// The full waypoint sequence for the walk in progress, in order.
    private var walkQueue: [Waypoint] = []
    /// Index into walkQueue of the waypoint currently armed (not yet triggered).
    private var currentIndex = 0
    /// The single region currently being monitored — there is never more than one.
    private var currentRegion: CLCircularRegion?

    /// How long a participant must remain continuously inside a waypoint's
    /// radius before its prompt plays (trigger confirmation).
    private let confirmationDwellTime: TimeInterval = 2.0
    /// The waypoint ID currently being confirmed, if any.
    private var pendingWaypointID: String?
    /// The in-flight dwell-timer task, cancelled if the participant leaves
    /// the radius early.
    private var confirmationTask: Task<Void, Never>?

    /// Debounce guard: ignore a confirmed arrival within this many seconds of
    /// the last one, so a momentary GPS blip immediately after a trigger
    /// can't fire a second prompt back to back.
    private let minTriggerInterval: TimeInterval = 4.0
    private var lastTriggerTime: Date?

    init(audioPlayer: AudioPromptPlaying = SpeechPromptPlayer()) {
        self.audioPlayer = audioPlayer
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    /// Call once, e.g. on HomeView.onAppear. "Always" authorization is what
    /// lets region-entry events reach the app while locked or backgrounded —
    /// "When In Use" is not sufficient for this experiment.
    func requestPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    func start(walk: Walk, informationLevel: InformationLevel) {
        walkQueue = walk.waypoints
        currentIndex = 0
        self.informationLevel = informationLevel
        triggeredWaypointIDs = []
        lastTriggeredWaypointName = nil
        lastTriggerTime = nil
        cancelConfirmation()
        isActive = true

        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        locationManager.startUpdatingLocation()
        armNextWaypoint()
    }

    func end() {
        isActive = false
        statusMessage = "Walk ended"
        isNextWaypointArmed = false
        cancelConfirmation()
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        currentRegion = nil
        locationManager.stopUpdatingLocation()
        audioPlayer.stop()
    }

    /// Registers a geofence for exactly the next un-triggered waypoint. Only
    /// one region is ever monitored at once — the previous one (if any) is
    /// stopped first — which is what makes cross-waypoint misfires impossible.
    private func armNextWaypoint() {
        cancelConfirmation()

        if let currentRegion {
            locationManager.stopMonitoring(for: currentRegion)
            self.currentRegion = nil
        }

        guard currentIndex < walkQueue.count else {
            statusMessage = "Route complete"
            isNextWaypointArmed = false
            return
        }

        let waypoint = walkQueue[currentIndex]
        currentWaypointNumber = currentIndex + 1

        let region = CLCircularRegion(
            center: waypoint.coordinate,
            radius: waypoint.triggerRadius,
            identifier: waypoint.id
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        currentRegion = region
        locationManager.startMonitoring(for: region)
        // Covers the case where the participant is already standing inside
        // this waypoint's radius the moment it becomes active — didEnterRegion
        // alone would never fire for that. Because only one region is ever
        // armed, this can't cross-trigger a different waypoint. Entry here
        // still goes through the same dwell-time confirmation as any other.
        locationManager.requestState(for: region)

        isNextWaypointArmed = true
        statusMessage = "Waiting to arrive at \(waypoint.name)"
    }

    /// Single funnel for both didEnterRegion and didDetermineState. Starts
    /// (or ignores, if already running) the dwell-time confirmation — it does
    /// not play anything itself.
    private func handleCandidateArrival(regionIdentifier: String) {
        guard isActive else { return }
        guard let currentRegion, currentRegion.identifier == regionIdentifier else {
            // Stray event for a region we're no longer monitoring — ignore.
            return
        }
        guard currentIndex < walkQueue.count else { return }
        let waypoint = walkQueue[currentIndex]
        guard waypoint.id == regionIdentifier else { return }
        guard !triggeredWaypointIDs.contains(waypoint.id) else { return }

        // didEnterRegion and requestState's didDetermineState can both report
        // the same arrival in quick succession — don't restart the timer if
        // a confirmation for this exact waypoint is already counting down.
        guard pendingWaypointID != waypoint.id else { return }

        beginConfirmation(for: waypoint)
    }

    /// Cancels an in-progress dwell confirmation if CoreLocation reports the
    /// participant has genuinely left the waypoint's radius before the
    /// confirmation window completed. Only acts if this exit is for the
    /// waypoint currently being confirmed — a stray exit event for a region
    /// we've already moved past is ignored.
    private func handleExit(regionIdentifier: String) {
        guard pendingWaypointID == regionIdentifier else { return }
        cancelConfirmation()
    }

    private func beginConfirmation(for waypoint: Waypoint) {
        confirmationTask?.cancel()
        pendingWaypointID = waypoint.id
        isConfirmingArrival = true
        statusMessage = "Confirming arrival at \(waypoint.name)…"

        confirmationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.confirmationDwellTime))
            guard !Task.isCancelled else { return }
            self.confirmArrival(waypointID: waypoint.id)
        }
    }

    /// Cancels any in-flight dwell confirmation — called when the participant
    /// drifts back outside the radius before the dwell time completes, and
    /// defensively whenever a walk starts, ends, or advances to the next
    /// waypoint.
    private func cancelConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
        isConfirmingArrival = false
        guard let pendingID = pendingWaypointID else { return }
        pendingWaypointID = nil
        if isActive, currentIndex < walkQueue.count, walkQueue[currentIndex].id == pendingID {
            statusMessage = "Waiting to arrive at \(walkQueue[currentIndex].name)"
        }
    }

    /// Called once the dwell timer completes without being cancelled. This is
    /// the only place a prompt actually plays.
    private func confirmArrival(waypointID: String) {
        guard isActive else { return }
        guard pendingWaypointID == waypointID else { return } // cancelled or superseded
        guard currentIndex < walkQueue.count else { return }
        let waypoint = walkQueue[currentIndex]
        guard waypoint.id == waypointID else { return }
        guard !triggeredWaypointIDs.contains(waypoint.id) else { return }

        if let last = lastTriggerTime, Date().timeIntervalSince(last) < minTriggerInterval {
            return
        }
        lastTriggerTime = Date()

        pendingWaypointID = nil
        confirmationTask = nil
        isConfirmingArrival = false

        triggeredWaypointIDs.insert(waypoint.id)
        lastTriggeredWaypointName = waypoint.name
        isNextWaypointArmed = false
        statusMessage = "Playing: \(waypoint.name)"

        playPrompt(for: waypoint)

        currentIndex += 1
        armNextWaypoint()
    }

    /// Exactly one prompt per waypoint. Condition 1 plays the navigation
    /// script only. Condition 2 plays the contextual script only — it already
    /// contains the navigation instruction at its start, so the two are never
    /// concatenated or played back to back.
    private func playPrompt(for waypoint: Waypoint) {
        switch informationLevel {
        case .navigationOnly:
            audioPlayer.play(key: "\(waypoint.id)_nav", script: waypoint.navigationPrompt, completion: nil)

        case .navigationPlusContext:
            let script = (waypoint.contextualPrompt?.isEmpty == false)
                ? waypoint.contextualPrompt!
                : waypoint.navigationPrompt // graceful fallback if a waypoint has no contextual script
            audioPlayer.play(key: "\(waypoint.id)_context", script: script, completion: nil)
        }
    }
}

extension WalkSession: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in self.handleCandidateArrival(regionIdentifier: region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        Task { @MainActor in self.handleCandidateArrival(regionIdentifier: region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLatitude = location.coordinate.latitude
            self.currentLongitude = location.coordinate.longitude
            self.currentAccuracy = location.horizontalAccuracy

            // Purely informational (debug panel / test mode) — this no longer
            // drives any triggering or cancellation decision. A previous
            // version cancelled the dwell confirmation whenever a single raw
            // GPS fix read as outside the radius, but ordinary GPS noise
            // (commonly ±5-15m) does that constantly for small radii, which
            // was cancelling confirmations before the 2-second dwell could
            // ever complete. Departure is now detected via didExitRegion
            // instead, which uses CoreLocation's own filtered geofence
            // state rather than a single noisy fix.
            guard self.currentIndex < self.walkQueue.count else {
                self.distanceToNext = nil
                return
            }
            let target = self.walkQueue[self.currentIndex]
            let targetLocation = CLLocation(latitude: target.latitude, longitude: target.longitude)
            self.distanceToNext = location.distance(from: targetLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.handleExit(regionIdentifier: region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.statusMessage = "Location error: \(error.localizedDescription)" }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in self.statusMessage = "Region monitoring failed: \(error.localizedDescription)" }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationStatus = status }
    }
}
