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

    /// When CoreLocation first reported arrival, for `waypointTrigger` only.
    /// Prompts do not play on entry — arrival must be held for
    /// `WalkSession.confirmationDwellTime` first — so this is earlier than
    /// `timestamp` by that dwell. Recording both removes any ambiguity about
    /// whether a waypoint time means "arrived" or "prompt started".
    let regionEntryTime: Date?

    let waypointID: String?
    let waypointName: String?
    let waypointOrder: Int?

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
        regionEntryTime: Date? = nil,
        waypointID: String? = nil,
        waypointName: String? = nil,
        waypointOrder: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.index = index
        self.type = type
        self.timestamp = timestamp
        self.regionEntryTime = regionEntryTime
        self.waypointID = waypointID
        self.waypointName = waypointName
        self.waypointOrder = waypointOrder
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
    let startedAt: Date
    var endedAt: Date?
    let timeZoneIdentifier: String

    init(
        sessionID: String,
        participantID: String,
        walkID: WalkID,
        informationLevel: InformationLevel,
        startedAt: Date,
        endedAt: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.sessionID = sessionID
        self.participantID = participantID
        self.walkID = walkID
        self.informationLevel = informationLevel
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
