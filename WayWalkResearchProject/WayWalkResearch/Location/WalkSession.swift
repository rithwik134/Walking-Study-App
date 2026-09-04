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

/// Tunable thresholds for the two-stage trigger. Grouped into one injectable
/// value rather than scattered `private let`s so tests can vary them, and so
/// the numbers that must be calibrated on a real device walk are visible in
/// one place.
///
/// `wakeRadius` deliberately does **not** come from the route JSON.
/// `Waypoint.triggerRadius` is the distance at which a prompt fires; the
/// CoreLocation region is a separate, much coarser thing, and conflating them
/// is what this design exists to undo.
struct TriggerTuning {
    /// Radius of the `CLCircularRegion`. Coarse on purpose — its only job is
    /// to wake the app (and relaunch it if iOS suspended it) before the
    /// participant is close. Entering it fires nothing.
    var wakeRadius: CLLocationDistance = 100

    /// Worst horizontal accuracy a fix may have and still be allowed to fire a
    /// prompt. Deliberately tighter than `closestApproachAccuracyLimit` (50m):
    /// a fix whose own error bar is ±50m claiming "you are 8m away" is not
    /// evidence of being within 10m, and believing it would recreate the early
    /// firing this design removes.
    ///
    /// **The riskiest number here.** If accuracy on the route is routinely
    /// worse than this, the fine trigger starves and every waypoint falls
    /// through to a backstop, firing late — worse than the old behaviour.
    /// `gps_accuracy_m` in the CSV and the debug panel exist to measure it.
    var triggerAccuracyLimit: CLLocationAccuracy = 25

    /// Consecutive qualifying fixes inside the radius before the prompt plays.
    /// Replaces the old wall-clock dwell; see the class doc.
    var confirmingFixCount = 2

    /// Backstop B: how close the participant must have got for a "they passed
    /// it" inference to be credible at all.
    var backstopApproachDistance: CLLocationDistance = 30
    /// Backstop B: how far past their closest approach they must then travel.
    var backstopRecedeDistance: CLLocationDistance = 50
    /// Backstop B can be switched off for early device walks without touching
    /// backstop A, which is the more conservative of the two.
    var isRecedeBackstopEnabled = true
}

/// One GPS fix, captured as a unit.
///
/// The position, its accuracy and the time it was *measured* have to travel
/// together: a row that logs coordinates from one fix and a timestamp from
/// another is worse than one that logs neither. Keeping them in a single
/// assignment makes that divergence structurally impossible.
struct FixSnapshot: Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: CLLocationAccuracy
    /// `CLLocation.timestamp` — when the hardware took the reading, which
    /// under iOS's batching can be well before the app was handed it.
    let timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
        timestamp = location.timestamp
    }
}

/// Drives one walk: plays each waypoint's prompt exactly once, in sequence,
/// and never repeats one unless the walk is restarted. Waypoints are handled
/// strictly in order — waypoint N+1 is not armed until N has fired — so two
/// waypoints can never compete.
///
/// **Triggering is two-stage, and the split is the whole design.**
///
/// 1. **Wake-up (coarse).** A single `CLCircularRegion` of
///    `tuning.wakeRadius` (~100m) is monitored. Entering it fires *nothing*.
///    Its only job is to guarantee the app is awake — region monitoring is
///    what Apple supports for relaunching a suspended app while the phone is
///    locked, which continuous GPS polling cannot do.
/// 2. **Fire (fine).** The prompt plays when `tuning.confirmingFixCount`
///    consecutive location fixes, each accurate to within
///    `tuning.triggerAccuracyLimit`, put the participant inside the
///    waypoint's real `triggerRadius`.
///
/// This inverts an earlier design in which region entry *was* the trigger.
/// Real-device measurements (Shevchenko & Reips 2023, *Behavior Research
/// Methods* 56:6411) found iOS clamps small geofences upward — 10m fences
/// fired 75-183m out, with no differentiation between 10m, 50m and 100m. With
/// waypoints a median ~50m apart, that did not merely fire early: waypoint N
/// fired, N+1 was armed, the arm-time `requestState` immediately answered
/// "inside" because N+1 was well within the clamp, and the route chain-fired
/// several prompts at a participant standing still. `handleWakeEntry` no
/// longer delivering anything is what closes that off.
///
/// **Why a run of fixes rather than a wall-clock dwell.** The old design held
/// arrival for 2 seconds before playing. iOS coalesces fixes while locked, so
/// a batch arrives having been measured seconds ago; adding wall-clock delay
/// on top only makes an already-late prompt later. A run of consecutive fixes
/// costs nothing when they arrive in one batch. Note the distinction from the
/// bug this replaced: raw distance must never cancel a *timer* (a single noisy
/// fix would kill every confirmation), but here there is no timer — a fix
/// outside the radius resets a run that the same stream has to re-earn, which
/// is symmetric.
///
/// **Backstops.** A waypoint that never fires blocks the entire rest of the
/// walk, so two independent inferences of "they have passed it" exist:
/// leaving the wake region (works when GPS is too poor to fire but cell/wifi
/// positioning still reports region state), and receding well past a close
/// approach (works when the participant was never inside the wake region, so
/// no exit event will ever arrive). Both are marked in the CSV `note` column.
@MainActor
final class WalkSession: NSObject, ObservableObject {
    @Published var isActive = false

    /// Nil for most of a walk — see `WalkBanner`.
    @Published private(set) var banner: WalkBanner?

    @Published var lastTriggeredWaypointName: String?
    @Published private(set) var triggeredWaypointIDs: Set<String> = []
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// The most recent fix, whatever its quality — position, accuracy and
    /// measurement time as one unit. Updated from every delivered fix, *not*
    /// accuracy-gated like `lastUsableFix`, so `gps_accuracy_m` keeps meaning
    /// "how good was the fix these coordinates came from".
    @Published private(set) var currentFix: FixSnapshot?

    // Live readouts derived from the snapshot, so position, accuracy and fix
    // time can never disagree about which fix they came from.
    var currentLatitude: Double? { currentFix?.latitude }
    var currentLongitude: Double? { currentFix?.longitude }
    var currentAccuracy: CLLocationAccuracy? { currentFix?.horizontalAccuracy }

    // Debug / test-mode readouts.
    @Published private(set) var distanceToNext: CLLocationDistance?
    @Published private(set) var isNextWaypointArmed = false
    @Published private(set) var isConfirmingArrival = false
    @Published private(set) var currentWaypointNumber = 0

    /// Whether the participant has been reported inside the coarse wake region
    /// for the armed waypoint. Surfaced in the debug panel, and the precondition
    /// for backstop A — you cannot have passed what you never reached.
    @Published private(set) var hasEnteredWakeRegion = false

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

    /// Whether the most recent usable fix put the participant inside the armed
    /// waypoint's `triggerRadius`. Drives Manual Mode's cue button colour — a
    /// hint about *when* to play, never a gate on being able to.
    ///
    /// Tracks the latest qualifying fix rather than the confirmed run, so it
    /// lights as soon as there is evidence rather than waiting for the
    /// automatic path. It will therefore flicker at the boundary, and it now
    /// lights at `triggerRadius` (~10m) rather than at CoreLocation's much
    /// coarser region entry — much less warning than before, but honest, and
    /// it finally matches the circle the maps draw to true scale.
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

    /// Smallest distance to the armed waypoint seen since it was armed, in
    /// metres. Reset every time a new waypoint is armed.
    ///
    /// Only fixes accurate enough to be believable contribute: a reading with
    /// ±100m accuracy that happens to land near the waypoint would otherwise
    /// record a closest approach the participant never actually made, which is
    /// worse than recording nothing.
    private var closestApproachToArmed: CLLocationDistance?
    /// Worst horizontal accuracy a fix may have and still count.
    private let closestApproachAccuracyLimit: CLLocationAccuracy = 50
    /// The most recent fix good enough to measure from, kept so a newly armed
    /// waypoint starts from the participant's known position rather than from
    /// nothing.
    private var lastUsableFix: CLLocation?

    private var lastFlagEventID: UUID?

    private let locationManager: LocationProviding
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

    /// Consecutive qualifying fixes so far inside the armed waypoint's radius.
    /// Reaching `tuning.confirmingFixCount` fires the prompt.
    private var inRadiusRun = 0
    /// Consecutive qualifying fixes so far satisfying backstop B's recede test.
    private var recedeRun = 0

    /// How often to re-ask CoreLocation whether the participant is inside the
    /// armed waypoint's wake region.
    ///
    /// `didEnterRegion` only fires on a genuine outside→inside transition, so
    /// a transition that never arrives would otherwise leave
    /// `hasEnteredWakeRegion` false forever and disable backstop A. Now that
    /// region state only feeds the backstop rather than the trigger, this is
    /// no longer load-bearing — the interval could be relaxed to reduce
    /// wake-ups if battery ever matters more than backstop latency.
    private let stateRecheckInterval: TimeInterval = 5.0
    private var stateRecheckTask: Task<Void, Never>?

    /// Why a backstop fired, for the CSV `note`.
    private enum BackstopReason: String {
        /// Left the coarse wake region without ever confirming arrival.
        case wakeExit = "wake_exit"
        /// Came close, then travelled well past without ever confirming.
        case receded

        var note: String { "backstop: \(rawValue)" }
    }

    // There is deliberately no cross-waypoint trigger debounce. An earlier
    // version ignored any confirmed arrival within 4s of the previous one,
    // which was both redundant and actively harmful: `triggeredWaypointIDs`
    // already guarantees a waypoint fires at most once, and any waypoint the
    // participant was already standing inside when it was armed could never
    // satisfy it — wedging that waypoint and every waypoint after it.

    let tuning: TriggerTuning

    init(
        audioPlayer: AudioPromptPlaying = SpeechPromptPlayer(),
        locationManager: LocationProviding = CLLocationManager(),
        tuning: TriggerTuning = TriggerTuning()
    ) {
        self.audioPlayer = audioPlayer
        self.locationManager = locationManager
        self.tuning = tuning
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
        closestApproachToArmed = nil
        clearConfirmationProgress()
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
        clearConfirmationProgress()
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
            horizontalAccuracy: currentAccuracy,
            fixTimestamp: currentFix?.timestamp
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

    /// Registers the coarse wake region for exactly the next un-triggered
    /// waypoint. Only one region is ever monitored at once — the previous one
    /// (if any) is stopped first — which is what makes cross-waypoint
    /// misfires impossible.
    private func armNextWaypoint() {
        clearConfirmationProgress()
        cancelStateRecheck()
        // A new waypoint has not been approached yet, whatever was true of the
        // last one.
        hasEnteredWakeRegion = false
        closestApproachToArmed = nil

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

        // Seed the closest approach with where the participant is *now*.
        // Without this, a waypoint played before the next fix arrives — which
        // happens whenever prompts are cued faster than roughly one per
        // second, and on every waypoint after the first when the location
        // stream is idle — recorded nothing at all.
        if let fix = lastUsableFix {
            closestApproachToArmed = fix.distance(
                from: CLLocation(latitude: waypoint.latitude, longitude: waypoint.longitude)
            )
        }

        // `tuning.wakeRadius`, NOT `waypoint.triggerRadius`. This region only
        // wakes the app; the prompt fires from the fix stream in
        // `evaluateTrigger`. Exit is still wanted — it is backstop A.
        let region = CLCircularRegion(
            center: waypoint.coordinate,
            radius: tuning.wakeRadius,
            identifier: waypoint.id
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        currentRegion = region
        locationManager.startMonitoring(for: region)
        // Covers the participant already being inside the wake region when it
        // becomes active — routine, since waypoints are a median ~50m apart and
        // the region is 100m — which `didEnterRegion` would never report,
        // having seen no transition. Harmless now: the reply only sets
        // `hasEnteredWakeRegion`. Under the old design, where this reply
        // *fired the prompt*, it was the chain-fire mechanism.
        locationManager.requestState(for: region)
        // …and keep asking, so a transition that never arrives still enables
        // backstop A rather than leaving it disabled for the whole leg.
        startStateRecheck(for: region)

        isNextWaypointArmed = true
    }

    /// Single funnel for `didEnterRegion` and `didDetermineState(.inside)`.
    ///
    /// **This must never deliver a prompt.** It records only that the
    /// participant is somewhere within the coarse wake region, which enables
    /// backstop A and tells the researcher's debug panel the app is tracking.
    /// Firing here is exactly what chain-fired the route: iOS reports "inside"
    /// from up to ~100m away, and with waypoints a median ~50m apart the reply
    /// to the arm-time `requestState` arrived before the participant had moved
    /// at all. The prompt now comes from `evaluateTrigger` instead.
    private func handleWakeEntry(regionIdentifier: String) {
        guard isActive else { return }
        guard let currentRegion, currentRegion.identifier == regionIdentifier else {
            // Stray event for a region we're no longer monitoring — ignore.
            return
        }
        guard currentIndex < walkQueue.count else { return }
        let waypoint = walkQueue[currentIndex]
        guard waypoint.id == regionIdentifier else { return }
        guard !triggeredWaypointIDs.contains(waypoint.id) else { return }

        hasEnteredWakeRegion = true
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

        deliverPrompt(for: waypoint, at: Date(), source: .manual)
    }

    /// Backstop A. Leaving a ~100m region without ever having confirmed
    /// arrival means the participant has definitively passed this waypoint, so
    /// fire it rather than let it block the rest of the walk.
    ///
    /// This is the backstop that survives poor GPS: region state comes from
    /// CoreLocation's own filtered positioning, which keeps working on cell
    /// and wifi alone in exactly the conditions where no fix is accurate
    /// enough for `evaluateTrigger` to fire.
    private func handleWakeExit(regionIdentifier: String) {
        // Manual mode never plays on its own — that is the entire contract of
        // the mode.
        guard isActive, sessionMode != .manual else { return }
        guard currentRegion?.identifier == regionIdentifier else { return }
        // You cannot have passed what you never reached. Guards against an
        // exit for a waypoint approached from outside and never entered.
        guard hasEnteredWakeRegion else { return }
        guard currentIndex < walkQueue.count,
              walkQueue[currentIndex].id == regionIdentifier,
              !triggeredWaypointIDs.contains(regionIdentifier)
        else { return }

        fireBackstop(reason: .wakeExit)
    }

    /// Drops all in-flight confirmation progress, making the armed waypoint
    /// eligible to be confirmed from scratch.
    ///
    /// The predecessor of this method cleared a `pendingWaypointID` that
    /// `handleCandidateArrival` read as "a confirmation is already counting
    /// down"; leaving it set silently discarded every future arrival for that
    /// waypoint and — because the next waypoint is only armed after this one
    /// fires — killed the rest of the walk. That property is gone: with a run
    /// of fixes rather than a timer there is no restart to suppress, and
    /// `triggeredWaypointIDs` already guarantees a waypoint fires at most
    /// once. The invariant is discharged rather than maintained, but the
    /// hazard it guarded against is worth remembering before adding state
    /// here that a trigger path reads as "already in progress".
    private func clearConfirmationProgress() {
        inRadiusRun = 0
        recedeRun = 0
        isConfirmingArrival = false
        isInsideCurrentRadius = false
    }

    /// Periodically re-asks CoreLocation whether we are inside the armed wake
    /// region, so a transition that never arrives still enables backstop A.
    ///
    /// Stops asking once the answer is known — unlike the old design, where
    /// this drove the trigger itself and so had to keep polling for the whole
    /// leg, the answer here is a latch.
    private func startStateRecheck(for region: CLCircularRegion) {
        stateRecheckTask?.cancel()
        let interval = stateRecheckInterval
        stateRecheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.isActive,
                      self.currentRegion?.identifier == region.identifier,
                      !self.triggeredWaypointIDs.contains(region.identifier),
                      !self.hasEnteredWakeRegion
                else { return }
                self.locationManager.requestState(for: region)
            }
        }
    }

    private func cancelStateRecheck() {
        stateRecheckTask?.cancel()
        stateRecheckTask = nil
    }

    /// The fine trigger: decides, from one location fix, whether the armed
    /// waypoint's prompt is now due. This and `playCurrentWaypoint` are the
    /// only paths that deliver a prompt.
    ///
    /// Called once per fix, in order, including for every fix in a coalesced
    /// batch — a batch delivered after a locked-screen gap may contain the
    /// entire approach, and dropping all but the last would skip the arrival.
    private func evaluateTrigger(with fix: CLLocation) {
        guard isActive, currentIndex < walkQueue.count else { return }
        let waypoint = walkQueue[currentIndex]
        guard !triggeredWaypointIDs.contains(waypoint.id) else { return }
        guard fix.horizontalAccuracy > 0 else { return }

        let target = CLLocation(latitude: waypoint.latitude, longitude: waypoint.longitude)
        let distance = fix.distance(from: target)

        // The two decisions below need different qualities of evidence, and
        // gating both on the tighter limit made the backstop unreachable in
        // exactly the conditions it exists for. A simulated walk with every
        // fix at ±40m accuracy fired *nothing at all* — the fine trigger
        // rightly refused, and the backstop never got the chance to.

        // Fine trigger: claiming "you are within 10m" demands a fix whose own
        // error bar is smaller than the claim. A fix too imprecise to believe
        // is not evidence in *either* direction, so it must neither confirm
        // arrival nor break a run built from good fixes — hence leaving the
        // runs untouched rather than resetting them.
        if fix.horizontalAccuracy <= tuning.triggerAccuracyLimit {
            if distance <= waypoint.triggerRadius {
                isInsideCurrentRadius = true
                inRadiusRun += 1
                recedeRun = 0
            } else {
                isInsideCurrentRadius = false
                inRadiusRun = 0
            }
            isConfirmingArrival = inRadiusRun > 0

            // Manual mode takes the hint but never the action: the flags above
            // colour the cue button, and the researcher decides when to play.
            guard sessionMode != .manual else { return }

            if inRadiusRun >= tuning.confirmingFixCount {
                deliverPrompt(for: waypoint, at: Date(), source: .automatic)
                return
            }
        }

        guard sessionMode != .manual else { return }

        // Backstop B: they got genuinely close, then travelled well past,
        // without any fix ever confirming arrival. Covers the case backstop A
        // cannot — a participant who never entered the wake region at all, so
        // no exit event will ever arrive.
        //
        // "They are tens of metres past where they got closest" is a far
        // coarser claim than "they are within 10m", so it tolerates a far
        // coarser fix — the same 50m limit that `closestApproachToArmed` is
        // itself measured with, which is what makes the comparison meaningful.
        guard tuning.isRecedeBackstopEnabled,
              fix.horizontalAccuracy <= closestApproachAccuracyLimit,
              let closest = closestApproachToArmed,
              closest <= tuning.backstopApproachDistance,
              distance >= closest + tuning.backstopRecedeDistance
        else {
            recedeRun = 0
            return
        }
        recedeRun += 1
        if recedeRun >= tuning.confirmingFixCount {
            fireBackstop(reason: .receded)
        }
    }

    /// Fires the armed waypoint because it was demonstrably passed without a
    /// close-enough fix ever confirming arrival.
    ///
    /// The row is logged as `trigger_source = automatic` with a `backstop: …`
    /// note, because the participant's own movement did cause it. It is **not**
    /// evidence of arrival at the waypoint: `closest_approach_m` on these rows
    /// exceeds the trigger radius by definition, which is both the diagnostic
    /// and a reliable way to filter them out in analysis.
    private func fireBackstop(reason: BackstopReason) {
        guard isActive, currentIndex < walkQueue.count else { return }
        let waypoint = walkQueue[currentIndex]
        guard !triggeredWaypointIDs.contains(waypoint.id) else { return }

        deliverPrompt(for: waypoint, at: Date(), source: .automatic, note: reason.note)
    }

    /// Records the waypoint, speaks it, and advances to the next one.
    ///
    /// Shared by the automatic path (`evaluateTrigger`), the backstops and the
    /// manual one (`playCurrentWaypoint`) so they cannot drift apart in what
    /// they log or how they advance — the only difference should be *when*
    /// this runs, not what it does.
    private func deliverPrompt(
        for waypoint: Waypoint,
        at firedAt: Date,
        source: TriggerSource,
        note: String? = nil
    ) {
        logger?.append(
            type: .waypointTrigger,
            timestamp: firedAt,
            waypoint: waypoint,
            triggerSource: source,
            closestApproachMetres: closestApproachToArmed,
            latitude: currentLatitude,
            longitude: currentLongitude,
            horizontalAccuracy: currentAccuracy,
            fixTimestamp: currentFix?.timestamp,
            note: note
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
        Task { @MainActor in self.handleWakeEntry(regionIdentifier: region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        Task { @MainActor in self.handleWakeEntry(regionIdentifier: region.identifier) }
    }

    /// The trigger path. Every fix in the batch is processed in order, not
    /// just `locations.last`: iOS coalesces updates — routinely while the
    /// screen is locked, the normal state during a walk — so a single delivery
    /// can contain an entire approach, and keeping only the newest fix would
    /// step straight over the arrival.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        Task { @MainActor in
            // Fixes are arriving, so whatever failed has recovered.
            self.locationError = nil

            for fix in locations {
                // Order within each fix is load-bearing:
                //  1. the snapshot first, so a prompt fired by this fix logs
                //     the position and measurement time that caused it;
                //  2. closest approach next, so if it fires, `armNextWaypoint`
                //     seeds the next waypoint from this fix;
                //  3. the trigger last.
                self.currentFix = FixSnapshot(fix)
                self.foldIntoClosestApproach(fix)
                self.evaluateTrigger(with: fix)
                // Delivering advanced `currentIndex` and armed the next
                // waypoint, so remaining fixes in this batch are evaluated
                // against it — correct catch-up through a batched approach,
                // and only able to fire again if the participant genuinely was
                // within the next waypoint's radius too.
                guard self.isActive, self.currentIndex < self.walkQueue.count else { break }
            }

            self.updateDistanceToNext()
        }
    }

    /// Folds one fix into the running minimum distance to the armed waypoint.
    ///
    /// Only fixes precise enough to believe are counted: a reading with ±100m
    /// accuracy that happens to land near the waypoint would record an
    /// approach the participant never made, and an invented number is worse
    /// for choosing a radius than no number at all. This limit is deliberately
    /// looser than `tuning.triggerAccuracyLimit` — a fix good enough to
    /// measure with is not necessarily good enough to fire on.
    private func foldIntoClosestApproach(_ location: CLLocation) {
        guard isActive, currentIndex < walkQueue.count else { return }
        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= closestApproachAccuracyLimit
        else { return }

        let target = walkQueue[currentIndex]
        let targetLocation = CLLocation(latitude: target.latitude, longitude: target.longitude)
        lastUsableFix = location
        let distance = location.distance(from: targetLocation)
        if distance < (closestApproachToArmed ?? .greatestFiniteMagnitude) {
            closestApproachToArmed = distance
        }
    }

    /// Live "how far to the next waypoint" readout for the debug panel and
    /// Manual Mode's cue hint. Observational only.
    private func updateDistanceToNext() {
        guard currentIndex < walkQueue.count, let fix = currentFix else {
            distanceToNext = nil
            return
        }
        let target = walkQueue[currentIndex]
        distanceToNext = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.handleWakeExit(regionIdentifier: region.identifier) }
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
