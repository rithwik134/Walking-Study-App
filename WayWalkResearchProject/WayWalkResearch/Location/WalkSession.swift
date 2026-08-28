import Foundation
import CoreLocation
import Combine

/// The only status the researcher screens surface, shown as a floating banner
/// under the header.
///
/// Deliberately just two cases. An earlier free-text `statusMessage` narrated
/// every internal transition — "Waiting to arrive at…", "Confirming arrival
/// at…" — which meant a permanent line of text that was almost always saying
/// something unremarkable, and so stopped being read at all. These are the two
/// states worth interrupting for: a prompt is being spoken right now, or the
/// walk is over.
enum WalkBanner: Equatable {
    /// A prompt is being spoken. Shown for the duration of the speech.
    case playing(waypointName: String)
    /// The route finished or the walk was ended. Stays on screen.
    case ended
}

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

    /// Nil for most of a walk — see `WalkBanner`.
    @Published private(set) var banner: WalkBanner?

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

    /// Which condition this walk is running. Published so the researcher
    /// screens can show the participant exactly the script that will be
    /// spoken, rather than guessing.
    @Published private(set) var informationLevel: InformationLevel = .navigationOnly

    /// How the walk in progress is being run.
    @Published private(set) var sessionMode: SessionMode = .study

    /// Whether every waypoint has been played.
    ///
    /// Published rather than inferred from `currentWaypointNumber`: that value
    /// deliberately stays on the last waypoint once the route finishes, so a
    /// view deriving completion from it would never see the route end.
    @Published private(set) var routeIsComplete = false

    /// Manual mode only: whether the participant is currently inside the armed
    /// waypoint's trigger radius. Drives the cue button's colour — it is a
    /// hint about *when* to play, never a gate on being able to.
    @Published private(set) var isInsideCurrentRadius = false

    // MARK: - Session logging

    /// Every waypoint fire and flag is written to disk as it happens — see
    /// `SessionLogger` for why the file is rewritten rather than appended.
    private(set) var logger: SessionLogger?

    /// The CSV for the walk that just finished, for the export screen.
    @Published private(set) var lastSessionFileURL: URL?
    /// Time of the most recent flag, for the "Last flag: 10:47:32" readout.
    @Published private(set) var lastFlagTime: Date?
    /// Non-nil when a log write has failed — surfaced in the UI rather than
    /// silently losing study data.
    @Published private(set) var loggingError: String?

    /// Most recent CoreLocation failure. Kept separate from `banner` so an
    /// error cannot hide a prompt that is playing. Cleared as soon as fixes
    /// start arriving again.
    @Published private(set) var locationError: String?

    /// Waypoint names whose prompts are queued or being spoken, in the order
    /// the synthesiser will speak them. The front is what is audible *now*,
    /// which is what the banner must show — where waypoints are close enough
    /// to fire seconds apart, the most recently triggered one is not the one
    /// the participant is currently hearing.
    private var speakingQueue: [String] = []

    private var lastFlagEventID: UUID?

    private let locationManager = CLLocationManager()
    private let audioPlayer: AudioPromptPlaying

    /// The voice prompts will actually be spoken in, for the debug panel.
    /// Quality depends on which voices the participant's phone has downloaded,
    /// so this is the only way to confirm on-device that a better voice took
    /// effect. See `SpeechPromptPlayer`.
    var audioVoiceDescription: String { audioPlayer.voiceDescription }

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
    /// When CoreLocation first reported arrival at `pendingWaypointID` —
    /// logged alongside the prompt time so the record distinguishes "arrived"
    /// from "prompt started".
    private var pendingArrivalTime: Date?
    /// The in-flight dwell-timer task, cancelled if the participant leaves
    /// the radius early.
    private var confirmationTask: Task<Void, Never>?

    /// How often to re-ask CoreLocation whether the participant is inside the
    /// armed waypoint's region.
    ///
    /// `didEnterRegion` only fires on a genuine outside→inside transition, and
    /// `requestState` used to be called once, at arm time. If a dwell was
    /// cancelled by a jittery `didExitRegion` — routine at the radii this
    /// route uses — and CoreLocation's state then settled back to "inside"
    /// without another transition, no further event ever arrived and the walk
    /// stopped dead at that waypoint. Re-asking periodically costs almost
    /// nothing next to the continuous location updates already running, and
    /// converts a permanent stall into a few seconds' delay.
    private let stateRecheckInterval: TimeInterval = 5.0
    private var stateRecheckTask: Task<Void, Never>?

    // There is deliberately no cross-waypoint trigger debounce. An earlier
    // version ignored any confirmed arrival within 4s of the previous one,
    // which was both redundant and actively harmful: `triggeredWaypointIDs`
    // already guarantees a waypoint fires at most once, and because the dwell
    // (2s) is always shorter than that window was (4s), any waypoint the
    // participant was already standing inside when it was armed could never
    // satisfy it — wedging that waypoint and every waypoint after it.

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

    func start(
        walk: Walk,
        informationLevel: InformationLevel,
        participantID: String,
        mode: SessionMode = .study
    ) {
        walkQueue = walk.waypoints
        currentIndex = 0
        self.informationLevel = informationLevel
        triggeredWaypointIDs = []
        lastTriggeredWaypointName = nil
        lastFlagTime = nil
        lastFlagEventID = nil
        loggingError = nil
        locationError = nil
        lastSessionFileURL = nil
        banner = nil
        speakingQueue.removeAll()
        routeIsComplete = false
        cancelConfirmation()
        isActive = true

        let logger = SessionLogger(
            participantID: participantID,
            walkID: walk.id,
            informationLevel: informationLevel,
            mode: mode
        )
        self.logger = logger
        sessionMode = mode
        reportLoggingState()

        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        locationManager.startUpdatingLocation()
        armNextWaypoint()
    }

    func end() {
        isActive = false
        speakingQueue.removeAll()
        banner = .ended
        isNextWaypointArmed = false
        isInsideCurrentRadius = false
        cancelConfirmation()
        cancelStateRecheck()

        if let logger {
            logger.finish()
            lastSessionFileURL = logger.fileURL
            reportLoggingState()
        }

        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        currentRegion = nil
        locationManager.stopUpdatingLocation()
        audioPlayer.stop()
    }

    // MARK: - Flags

    /// Records a researcher flag at the instant this is called.
    ///
    /// The timestamp is stamped and written to disk here, *before* any note
    /// UI is presented. That ordering is the whole design: a flag marks a
    /// moment, and the moment is when the button was pressed — not when
    /// somebody finished typing about it, and not conditional on them
    /// finishing at all.
    @discardableResult
    func addFlag() -> UUID? {
        guard let logger else { return nil }
        let now = Date()
        let id = logger.append(
            type: .flag,
            timestamp: now,
            latitude: currentLatitude,
            longitude: currentLongitude,
            horizontalAccuracy: currentAccuracy
        )
        lastFlagTime = now
        lastFlagEventID = id
        reportLoggingState()
        return id
    }

    /// Attaches optional free text to an already-recorded flag. Safe to call
    /// with nil or whitespace — the flag simply stays note-less.
    func attachNote(_ note: String?, to eventID: UUID) {
        logger?.attachNote(note, to: eventID)
        reportLoggingState()
    }

    /// Retracts the most recent flag, for a mis-tap. Only the most recent one
    /// can be undone, and only once.
    func undoLastFlag() {
        guard let logger, let id = lastFlagEventID else { return }
        logger.remove(eventID: id)
        lastFlagEventID = nil
        lastFlagTime = nil
        reportLoggingState()
    }

    var canUndoLastFlag: Bool { lastFlagEventID != nil }

    private func reportLoggingState() {
        guard let logger else { return }
        loggingError = logger.lastWriteError.map {
            "Could not save session log: \($0.localizedDescription)"
        }
    }

    /// Registers a geofence for exactly the next un-triggered waypoint. Only
    /// one region is ever monitored at once — the previous one (if any) is
    /// stopped first — which is what makes cross-waypoint misfires impossible.
    private func armNextWaypoint() {
        cancelConfirmation()
        cancelStateRecheck()
        // A new waypoint has not been arrived at yet, whatever was true of the
        // last one.
        isInsideCurrentRadius = false

        if let currentRegion {
            locationManager.stopMonitoring(for: currentRegion)
            self.currentRegion = nil
        }

        guard currentIndex < walkQueue.count else {
            isNextWaypointArmed = false
            routeIsComplete = true
            // If a prompt is still being spoken, its completion sets this
            // instead — otherwise the last waypoint's banner would be replaced
            // before it had been read.
            if banner == nil { banner = .ended }
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
        // …and keep asking, so a transition that never arrives (or a dwell
        // cancelled by GPS jitter) recovers instead of stalling the walk.
        startStateRecheck(for: region)

        isNextWaypointArmed = true
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

        // Manual mode never plays on arrival. Arrival only lights the cue
        // button; the researcher decides when the prompt is actually spoken.
        // The arrival time is still recorded, so the log keeps both "when they
        // reached it" and "when it was played".
        if sessionMode == .manual {
            isInsideCurrentRadius = true
            if pendingArrivalTime == nil { pendingArrivalTime = Date() }
            return
        }

        // didEnterRegion and requestState's didDetermineState can both report
        // the same arrival in quick succession — don't restart the timer if
        // a confirmation for this exact waypoint is already counting down.
        guard pendingWaypointID != waypoint.id else { return }

        beginConfirmation(for: waypoint)
    }

    /// Play the current waypoint's prompt now, without waiting for arrival.
    ///
    /// Two callers, same mechanics:
    ///
    /// - **Manual mode**, where this is the only way a prompt ever plays.
    /// - **A normal walk**, where it is the failsafe: if a geofence does not
    ///   fire, the walk would otherwise stall at that waypoint forever, since
    ///   the next one is only armed once the current one fires. Forcing it
    ///   both delivers the instruction the participant was owed and unblocks
    ///   the rest of the route.
    ///
    /// Deliberately callable whether or not the participant is inside the
    /// radius — a failsafe that only works when the geofence agrees is not a
    /// failsafe. Repeated presses queue rather than interrupt, because
    /// `AVSpeechSynthesizer.speak` appends to its own queue and nothing here
    /// calls `stop()` mid-walk.
    ///
    /// The resulting row is marked `trigger_source = manual`, so a forced
    /// prompt is never mistaken in analysis for the participant's own arrival.
    func playCurrentWaypoint() {
        guard isActive, currentIndex < walkQueue.count else { return }
        let waypoint = walkQueue[currentIndex]
        guard !triggeredWaypointIDs.contains(waypoint.id) else { return }

        deliverPrompt(for: waypoint, at: Date(), arrivedAt: pendingArrivalTime, source: .manual)
    }

    /// Cancels an in-progress dwell confirmation if CoreLocation reports the
    /// participant has genuinely left the waypoint's radius before the
    /// confirmation window completed. Only acts if this exit is for the
    /// waypoint currently being confirmed — a stray exit event for a region
    /// we've already moved past is ignored.
    private func handleExit(regionIdentifier: String) {
        if sessionMode == .manual {
            guard currentRegion?.identifier == regionIdentifier else { return }
            // The cue button goes grey again, but `pendingArrivalTime` is
            // deliberately kept: they did arrive, and that first arrival is
            // what the log should compare the play time against even if they
            // drifted out and back before pressing.
            isInsideCurrentRadius = false
            return
        }
        guard pendingWaypointID == regionIdentifier else { return }
        cancelConfirmation()
    }

    private func beginConfirmation(for waypoint: Waypoint) {
        confirmationTask?.cancel()
        pendingWaypointID = waypoint.id
        pendingArrivalTime = Date()
        isConfirmingArrival = true

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
        clearPendingConfirmation()
    }

    /// Drops the in-flight confirmation state, making the waypoint eligible to
    /// be confirmed again. Every early return in `confirmArrival` goes through
    /// here — leaving `pendingWaypointID` set is what wedged the walk.
    private func clearPendingConfirmation() {
        pendingWaypointID = nil
        pendingArrivalTime = nil
        isConfirmingArrival = false
    }

    /// Periodically re-asks CoreLocation whether we are inside the armed
    /// region, so a missed or cancelled transition recovers on its own.
    ///
    /// This uses CoreLocation's own filtered geofence state — the same source
    /// as `didEnterRegion` — rather than comparing raw GPS distance, so it
    /// cannot make prompts fire earlier than they otherwise would. It only
    /// recovers arrivals that would have been missed entirely.
    private func startStateRecheck(for region: CLCircularRegion) {
        stateRecheckTask?.cancel()
        let interval = stateRecheckInterval
        stateRecheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.isActive,
                      self.currentRegion?.identifier == region.identifier,
                      !self.triggeredWaypointIDs.contains(region.identifier)
                else { return }
                // A confirmation for this waypoint is already counting down;
                // asking again would only be discarded.
                if self.pendingWaypointID != region.identifier {
                    self.locationManager.requestState(for: region)
                }
            }
        }
    }

    private func cancelStateRecheck() {
        stateRecheckTask?.cancel()
        stateRecheckTask = nil
    }

    /// Called once the dwell timer completes without being cancelled. This is
    /// the only place a prompt actually plays.
    ///
    /// Every exit path from here must leave `pendingWaypointID` clear.
    /// `handleCandidateArrival` reads a non-nil `pendingWaypointID` as "a
    /// confirmation for this waypoint is already counting down" and discards
    /// the event — so returning early while it is still set silently discards
    /// every future arrival for that waypoint, and because the next waypoint
    /// is only armed at the bottom of this method, kills the rest of the walk.
    private func confirmArrival(waypointID: String) {
        // The one case that must not clear the pending state: it belongs to a
        // different waypoint, so it is not ours to touch.
        guard pendingWaypointID == waypointID else { return }

        guard isActive,
              currentIndex < walkQueue.count,
              walkQueue[currentIndex].id == waypointID,
              !triggeredWaypointIDs.contains(waypointID)
        else {
            clearPendingConfirmation()
            return
        }

        let waypoint = walkQueue[currentIndex]
        let firedAt = Date()
        let arrivalTime = pendingArrivalTime

        clearPendingConfirmation()
        confirmationTask = nil
        deliverPrompt(for: waypoint, at: firedAt, arrivedAt: arrivalTime, source: .geofence)
    }

    /// Records the waypoint, speaks it, and advances to the next one.
    ///
    /// Shared by the automatic path (`confirmArrival`) and the manual one
    /// (`playCurrentWaypoint`) so the two cannot drift apart in what they log
    /// or how they advance — the only difference between the modes should be
    /// *when* this runs, not what it does.
    ///
    /// `arrivedAt` is when CoreLocation first reported the participant inside
    /// the radius. In manual mode that is deliberately not the same as
    /// `firedAt`: the gap between them is how long the researcher waited
    /// before cueing, which is the thing this mode exists to capture.
    private func deliverPrompt(
        for waypoint: Waypoint,
        at firedAt: Date,
        arrivedAt: Date?,
        source: TriggerSource
    ) {
        logger?.append(
            type: .waypointTrigger,
            timestamp: firedAt,
            regionEntryTime: arrivedAt,
            waypoint: waypoint,
            triggerSource: source,
            latitude: currentLatitude,
            longitude: currentLongitude,
            horizontalAccuracy: currentAccuracy
        )
        reportLoggingState()

        triggeredWaypointIDs.insert(waypoint.id)
        lastTriggeredWaypointName = waypoint.name
        isNextWaypointArmed = false

        playPrompt(for: waypoint)

        currentIndex += 1
        armNextWaypoint()
    }

    /// Exactly one prompt per waypoint. Condition 1 plays the navigation
    /// script only. Condition 2 plays the contextual script only — it already
    /// contains the navigation instruction at its start, so the two are never
    /// concatenated or played back to back.
    private func playPrompt(for waypoint: Waypoint) {
        let script = waypoint.script(for: informationLevel)

        // Context-only waypoints have no navigation script, so in Navigation
        // Only nothing is spoken. Claiming "Playing" for silence would be a
        // lie, and the completion may never arrive for an empty utterance,
        // which would leave the banner stuck.
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let name = waypoint.name
        speakingQueue.append(name)
        // Only take over the banner if nothing is already being spoken —
        // otherwise this prompt is queued behind one the participant is still
        // listening to, and saying so would be wrong.
        if speakingQueue.count == 1 { banner = .playing(waypointName: name) }
        audioPlayer.play(
            key: waypoint.audioKey(for: informationLevel),
            script: script
        ) { [weak self] in
            // Delegate callbacks are not guaranteed on the main actor.
            Task { @MainActor in self?.promptDidFinish(waypointName: name) }
        }
    }

    /// Clears the banner when the speech that raised it ends.
    ///
    /// Guarded on the banner still being *this* prompt's: where waypoints are
    /// close enough to queue, a later prompt has already replaced the banner
    /// and the earlier one finishing must not wipe it.
    private func promptDidFinish(waypointName: String) {
        if let index = speakingQueue.firstIndex(of: waypointName) {
            speakingQueue.remove(at: index)
        }
        // Whatever is now at the front is what the participant can hear.
        if let nowSpeaking = speakingQueue.first {
            banner = .playing(waypointName: nowSpeaking)
        } else {
            banner = routeIsComplete ? .ended : nil
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
            // Fixes are arriving again, so whatever failed has recovered.
            self.locationError = nil

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

    // Location failures go to their own property rather than overwriting
    // `statusMessage`. A single transient GPS error used to replace "Waiting
    // to arrive at 7" permanently, leaving the researcher with no idea which
    // waypoint was armed for the rest of the walk.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locationError = "Location error: \(error.localizedDescription)" }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in self.locationError = "Region monitoring failed: \(error.localizedDescription)" }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationStatus = status }
    }
}
