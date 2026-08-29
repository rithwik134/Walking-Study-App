import Foundation

/// Records one walk to a CSV file in `Documents/Sessions/`.
///
/// The in-memory `events` array is the source of truth and the whole file is
/// regenerated and written atomically after *every* mutation. That sounds
/// wasteful and isn't: a session is roughly 25 rows / 4 KB, so a full rewrite
/// costs microseconds. In exchange it buys two things an append-only
/// `FileHandle` cannot:
///
/// 1. **Crash safety at every step.** A walk lasts 20-40 minutes with the
///    screen locked. If iOS jetsams the app or it crashes, whatever happened
///    up to that instant is already on disk — nothing is buffered.
/// 2. **Late edits.** A flag's optional note arrives *after* its row has been
///    written. Rewriting patches it in place; appending would need a
///    seek-and-splice.
///
/// Deliberately not `@MainActor` and with an injectable directory, so the CSV
/// generation can be unit-tested without a `WalkSession` or a device.
final class SessionLogger {
    private(set) var metadata: SessionMetadata
    private(set) var events: [SessionEvent] = []

    /// Set if a write fails, so the UI can warn rather than silently losing a
    /// session. Cleared on the next successful write.
    private(set) var lastWriteError: Error?

    let fileURL: URL

    private let isoFormatter: ISO8601DateFormatter
    private let localTimeFormatter: DateFormatter

    /// The columns of the exported CSV, in order. Kept as one list so the
    /// header and the row builder can never drift apart.
    static let columns = [
        "session_id", "participant_id", "walk", "information_level", "session_mode",
        "event_index", "event_type",
        "time_iso", "time_local", "elapsed_s", "region_entry_local",
        "waypoint_order", "waypoint_id", "waypoint_name", "trigger_source",
        "closest_approach_m",
        "latitude", "longitude", "gps_accuracy_m",
        "note"
    ]

    /// Default location for session files: `Documents/Sessions/`. Exposed to
    /// the app (and overridable in tests) rather than recomputed in each
    /// caller.
    static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// Every marker a file name may carry, for `SessionStore` to recognise
    /// when parsing one back apart.
    static let fileNameMarkers: Set<String> = Set(SessionMode.allCases.compactMap(\.fileNameMarker))

    init(
        participantID: String,
        walkID: WalkID,
        informationLevel: InformationLevel,
        mode: SessionMode = .study,
        startedAt: Date = Date(),
        directory: URL = SessionLogger.defaultDirectory
    ) {
        let safeParticipant = Self.sanitise(participantID)
        let timeZone = TimeZone.current

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.timeZone = timeZone
        stamp.locale = Locale(identifier: "en_US_POSIX")

        let sessionID = "\(safeParticipant)_\(walkID.rawValue)_\(stamp.string(from: startedAt))"

        self.metadata = SessionMetadata(
            sessionID: sessionID,
            participantID: participantID,
            walkID: walkID,
            informationLevel: informationLevel,
            mode: mode,
            startedAt: startedAt,
            timeZoneIdentifier: timeZone.identifier
        )

        // A non-study run is marked in the file name as well as in every row,
        // so it is obvious in a Finder listing without opening anything.
        let marker = mode.fileNameMarker.map { "\($0)_" } ?? ""
        self.fileURL = directory.appendingPathComponent("WayWalk_\(marker)\(sessionID).csv")

        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.timeZone = timeZone
        self.isoFormatter.formatOptions = [.withInternetDateTime]

        self.localTimeFormatter = DateFormatter()
        self.localTimeFormatter.dateFormat = "HH:mm:ss"
        self.localTimeFormatter.timeZone = timeZone
        self.localTimeFormatter.locale = Locale(identifier: "en_US_POSIX")

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        append(type: .sessionStart, timestamp: startedAt)
    }

    // MARK: - Recording

    @discardableResult
    func append(
        type: SessionEventType,
        timestamp: Date = Date(),
        regionEntryTime: Date? = nil,
        waypoint: Waypoint? = nil,
        triggerSource: TriggerSource? = nil,
        closestApproachMetres: Double? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        note: String? = nil
    ) -> UUID {
        let event = SessionEvent(
            index: events.count,
            type: type,
            timestamp: timestamp,
            regionEntryTime: regionEntryTime,
            waypointID: waypoint?.id,
            waypointName: waypoint?.name,
            waypointOrder: waypoint?.order,
            triggerSource: triggerSource,
            closestApproachMetres: closestApproachMetres,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            note: note
        )
        events.append(event)
        flush()
        return event.id
    }

    /// Fills in the optional note on an already-recorded event. The event's
    /// original `timestamp` is untouched — that is the entire point of
    /// separating the two.
    func attachNote(_ note: String?, to eventID: UUID) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        events[index].note = (trimmed?.isEmpty == false) ? trimmed : nil
        flush()
    }

    /// Removes an event entirely — used by "undo last flag" after a mis-tap.
    /// Later events keep their original `index` values rather than being
    /// renumbered, so a gap in `event_index` is a visible, honest record that
    /// something was retracted.
    func remove(eventID: UUID) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        events.remove(at: index)
        flush()
    }

    func finish(at date: Date = Date()) {
        metadata.endedAt = date
        append(type: .sessionEnd, timestamp: date)
    }

    // MARK: - CSV generation

    var csvText: String {
        var lines = [Self.columns.joined(separator: ",")]
        lines.append(contentsOf: events.map(row(for:)))
        return lines.joined(separator: "\n") + "\n"
    }

    private func row(for event: SessionEvent) -> String {
        let elapsed = event.timestamp.timeIntervalSince(metadata.startedAt)

        let fields: [String] = [
            metadata.sessionID,
            metadata.participantID,
            metadata.walkID.rawValue,
            metadata.informationLevel.rawValue,
            metadata.mode.rawValue,
            String(event.index),
            event.type.rawValue,
            isoFormatter.string(from: event.timestamp),
            localTimeFormatter.string(from: event.timestamp),
            String(format: "%.1f", elapsed),
            event.regionEntryTime.map { localTimeFormatter.string(from: $0) } ?? "",
            event.waypointOrder.map(String.init) ?? "",
            event.waypointID ?? "",
            event.waypointName ?? "",
            event.triggerSource?.rawValue ?? "",
            event.closestApproachMetres.map { String(format: "%.1f", $0) } ?? "",
            event.latitude.map { String(format: "%.6f", $0) } ?? "",
            event.longitude.map { String(format: "%.6f", $0) } ?? "",
            event.horizontalAccuracy.map { String(format: "%.1f", $0) } ?? "",
            event.note ?? ""
        ]
        return fields.map(Self.escape).joined(separator: ",")
    }

    /// Quotes a CSV field only when it needs it, doubling any embedded quote.
    /// Flag notes are free text, so commas, quotes and newlines all have to
    /// survive the round trip.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Persistence

    private func flush() {
        do {
            try Data(csvText.utf8).write(to: fileURL, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = error
        }
    }

    /// Strips anything that would break a filename or make the ID ambiguous
    /// when it is parsed back out of one.
    static func sanitise(_ participantID: String) -> String {
        let trimmed = participantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let cleaned = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}
