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
    /// - On an `automatic` row it is, in effect, **the distance at which iOS
    ///   actually fired the fence** — the measurement that reveals how far the
    ///   effective radius sits from the configured one.
    /// - On a `manual` row it is how near they got without the fence firing,
    ///   which says whether the radius was too small or they were off-route.
    ///
    /// Empty only when no fix accurate enough to trust arrived at all.
    let closestApproachMetres: Double?

    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?

    /// Optional free text attached to a flag after the fact.
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
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
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
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
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
