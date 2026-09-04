import Foundation

/// The kinds of moment worth recording during a walk. Raw values are written
/// straight into the `event_type` CSV column, so they are snake_case rather
/// than Swift-style — the CSV is read by researchers and by the desktop
/// analyser, not by this app.
enum SessionEventType: String, Codable {
    case sessionStart = "session_start"
    case waypointTrigger = "waypoint_trigger"
    case flag
    case sessionEnd = "session_end"
}

/// What caused a waypoint's prompt to play.
///
/// A prompt the researcher forced is not the same observation as one the
/// participant's own arrival produced — the participant may not have been at
/// the waypoint, or even near it. Recording which is which per row is what
/// keeps a rescued walk analysable instead of quietly contaminated.
enum TriggerSource: String, Codable {
    /// Fired by CoreLocation reporting arrival, after the dwell confirmation.
    case automatic
    /// Played by the researcher pressing the cue button.
    case manual
}

/// One row of a session log.
///
/// `timestamp` is always stamped at the instant the event happened — for a
/// flag that means the moment the button was pressed, *not* the moment an
/// optional note was saved afterwards. That is why `note` is the only `var`
/// here: it can be filled in later without disturbing the time it refers to.
struct SessionEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let index: Int
    let type: SessionEventType
    let timestamp: Date

    let waypointID: String?
    let waypointName: String?
    let waypointOrder: Int?

    /// `waypointTrigger` only: whether the participant's arrival fired this or
    /// the researcher did.
    let triggerSource: TriggerSource?

    /// The closest the participant got to this waypoint, in metres, while it
    /// was armed. Recorded for both trigger sources, and they answer different
    /// questions:
    ///
    /// It is a minimum over the whole approach, not the distance at any one
    /// moment — see `triggerDistanceMetres` for that — and answers *"did they
    /// ever get near this waypoint"*:
    ///
    /// - A large value means they never came close, which is a route or
    ///   wayfinding problem rather than a technical one.
    /// - A small value on a row that needed a backstop means they *were*
    ///   there and no fix was accurate enough to confirm it, which points at
    ///   `TriggerTuning.triggerAccuracyLimit` rather than at the radius.
    ///
    /// Only fixes accurate to within 50m contribute, so it cannot invent an
    /// approach the participant never made. Empty when no such fix arrived.
    let closestApproachMetres: Double?

    /// `waypointTrigger` only: how far from the waypoint the participant was
    /// **at the moment the prompt played**, in metres.
    ///
    /// Distinct from `closestApproachMetres`, and the two answer different
    /// questions. Closest approach asks *"did they ever get near this
    /// waypoint"* — the radius-sizing question. This asks *"where were they
    /// when they heard it"*, which for a navigation study is usually the one
    /// that matters: an instruction to turn is only useful if it arrives
    /// before the turn.
    ///
    /// For a clean automatic fire the two are nearly equal. For a backstop
    /// they diverge sharply — a participant can have passed within 2m and only
    /// be told 70m later, and closest approach alone would hide that entirely.
    ///
    /// Measured from the same fix as `latitude`/`longitude`, so read it
    /// against `gps_accuracy_m` and `fix_age_s`: with a stale or imprecise fix
    /// this is where the app *believed* they were.
    let triggerDistanceMetres: Double?

    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?

    /// When the GPS fix that `latitude`/`longitude`/`horizontalAccuracy`
    /// describe was actually *measured* — not when the app received it.
    ///
    /// iOS coalesces location updates while the screen is locked, which is the
    /// normal state during a walk, so a fix taken at 10:00:00 can be delivered
    /// at 10:00:20. Without this the row would claim a position for `timestamp`
    /// that the participant had already left twenty seconds and thirty metres
    /// earlier, and nothing in the file would say so. The difference between
    /// the two is written to the CSV as `fix_age_s`.
    ///
    /// Nil for rows with no position at all (`sessionStart`, `sessionEnd`).
    let fixTimestamp: Date?

    /// Optional free text. Two producers: a note the researcher attaches to a
    /// flag after the fact, and a `backstop: …` marker written at append time
    /// when a waypoint was fired by a backstop rather than by a confirmed
    /// arrival (see `WalkSession`).
    var note: String?

    init(
        id: UUID = UUID(),
        index: Int,
        type: SessionEventType,
        timestamp: Date,
        waypointID: String? = nil,
        waypointName: String? = nil,
        waypointOrder: Int? = nil,
        triggerSource: TriggerSource? = nil,
        closestApproachMetres: Double? = nil,
        triggerDistanceMetres: Double? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        fixTimestamp: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.index = index
        self.type = type
        self.timestamp = timestamp
        self.waypointID = waypointID
        self.waypointName = waypointName
        self.waypointOrder = waypointOrder
        self.triggerSource = triggerSource
        self.closestApproachMetres = closestApproachMetres
        self.triggerDistanceMetres = triggerDistanceMetres
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.fixTimestamp = fixTimestamp
        self.note = note
    }
}

/// Everything needed to identify a session, repeated on every CSV row so a
/// single exported file is self-describing even when separated from its
/// filename.
struct SessionMetadata: Codable, Equatable {
    let sessionID: String
    let participantID: String
    let walkID: WalkID
    let informationLevel: InformationLevel
    let mode: SessionMode
    let startedAt: Date
    var endedAt: Date?
    let timeZoneIdentifier: String

    init(
        sessionID: String,
        participantID: String,
        walkID: WalkID,
        informationLevel: InformationLevel,
        mode: SessionMode = .study,
        startedAt: Date,
        endedAt: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.sessionID = sessionID
        self.participantID = participantID
        self.walkID = walkID
        self.informationLevel = informationLevel
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
