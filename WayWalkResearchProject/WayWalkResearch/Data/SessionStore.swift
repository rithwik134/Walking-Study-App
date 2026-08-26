import Foundation

/// One previously-recorded session, as summarised from its file on disk.
///
/// The summary is parsed from the filename rather than by reading the CSV,
/// so listing a hundred sessions costs a single directory scan. The filename
/// format is fixed by `SessionLogger`:
/// `WayWalk_[TEST_|MANUAL_]<participant>_<walkID>_<yyyyMMdd-HHmmss>.csv`
struct SessionFile: Identifiable {
    let url: URL
    let participantID: String
    let walkID: WalkID?
    let recordedAt: Date?
    let byteCount: Int
    /// Taken from the file name marker. The CSV rows carry the authoritative
    /// value in `session_mode`; this is the cheap version for listing.
    let mode: SessionMode

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
}

/// Lists, and deletes, the session CSVs in `Documents/Sessions/`.
///
/// This is the safety net for the export flow: if a share sheet is dismissed
/// by accident or a phone-to-Mac transfer is delayed, nothing is lost — the
/// files stay here until they are explicitly removed.
final class SessionStore {
    static let shared = SessionStore()

    private let directory: URL
    private let stampFormatter: DateFormatter

    init(directory: URL = SessionLogger.defaultDirectory) {
        self.directory = directory
        self.stampFormatter = DateFormatter()
        self.stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        self.stampFormatter.locale = Locale(identifier: "en_US_POSIX")
    }

    /// Newest first.
    func sessions() -> [SessionFile] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "csv" }
            .map(summarise(url:))
            .sorted { lhs, rhs in
                switch (lhs.recordedAt, rhs.recordedAt) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.fileName > rhs.fileName
                }
            }
    }

    func delete(_ session: SessionFile) {
        try? FileManager.default.removeItem(at: session.url)
    }

    private func summarise(url: URL) -> SessionFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let stem = url.deletingPathExtension().lastPathComponent

        // WayWalk_[MARKER_]<participant>_<walkID>_<stamp> — participant IDs are
        // sanitised to alphanumerics and hyphens by SessionLogger, so the
        // underscores are unambiguous separators.
        var parts = stem.split(separator: "_").map(String.init)
        guard parts.count >= 4, parts[0] == "WayWalk" else {
            return SessionFile(
                url: url, participantID: stem, walkID: nil,
                recordedAt: nil, byteCount: size, mode: .study
            )
        }
        parts.removeFirst()

        // An optional TEST/MANUAL marker shifts everything after it along by
        // one. Without handling it, a marked file would list its participant
        // as "TEST" and its walk as the participant ID.
        var mode = SessionMode.study
        if let first = parts.first, SessionLogger.fileNameMarkers.contains(first) {
            mode = SessionMode.allCases.first { $0.fileNameMarker == first } ?? .study
            parts.removeFirst()
        }

        guard parts.count >= 3 else {
            return SessionFile(
                url: url, participantID: stem, walkID: nil,
                recordedAt: nil, byteCount: size, mode: mode
            )
        }

        return SessionFile(
            url: url,
            participantID: parts[0],
            walkID: WalkID(rawValue: parts[1]),
            recordedAt: stampFormatter.date(from: parts[2]),
            byteCount: size,
            mode: mode
        )
    }
}
