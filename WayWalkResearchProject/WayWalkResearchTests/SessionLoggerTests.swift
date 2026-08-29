import XCTest
import CoreLocation
@testable import WayWalkResearch

/// Covers the exported CSV, which is the actual deliverable of a walk — if
/// this is wrong, a study session is unusable and there is no second chance
/// to record it.
final class SessionLoggerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLoggerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeLogger(
        participant: String = "P03",
        walk: WalkID = .walkA,
        level: InformationLevel = .navigationOnly,
        mode: SessionMode = .study,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SessionLogger {
        SessionLogger(
            participantID: participant,
            walkID: walk,
            informationLevel: level,
            mode: mode,
            startedAt: startedAt,
            directory: directory
        )
    }

    private func makeWaypoint(
        id: String = "a1",
        order: Int = 1,
        name: String = "1",
        radius: Double = 5
    ) -> Waypoint {
        Waypoint(
            id: id,
            order: order,
            name: name,
            latitude: 51.524315,
            longitude: -0.134529,
            triggerRadius: radius,
            navigationPrompt: "Head south on Gower Street.",
            contextualPrompt: "Head south on Gower Street. You are on a moderately busy street."
        )
    }

    /// Splits CSV text into rows of fields, honouring quoted fields that
    /// contain commas, escaped quotes and newlines.
    private func parse(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = csv.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private func column(_ name: String, in row: [String]) -> String {
        guard let index = SessionLogger.columns.firstIndex(of: name), row.indices.contains(index) else {
            return ""
        }
        return row[index]
    }

    // MARK: - Header and shape

    func testHeaderMatchesDocumentedColumns() {
        let logger = makeLogger()
        let rows = parse(logger.csvText)
        XCTAssertEqual(rows.first, SessionLogger.columns)
    }

    func testSessionStartRowIsWrittenOnCreation() {
        let logger = makeLogger()
        XCTAssertEqual(logger.events.count, 1)
        XCTAssertEqual(logger.events.first?.type, .sessionStart)

        let rows = parse(logger.csvText)
        XCTAssertEqual(rows.count, 2) // header + session_start
        XCTAssertEqual(column("event_type", in: rows[1]), "session_start")
        XCTAssertEqual(column("elapsed_s", in: rows[1]), "0.0")
    }

    func testFileIsWrittenToDiskImmediately() throws {
        let logger = makeLogger()
        XCTAssertNil(logger.lastWriteError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logger.fileURL.path))

        let onDisk = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertEqual(onDisk, logger.csvText)
    }

    /// The whole point of rewriting on every mutation: whatever has happened
    /// so far is already on disk, not buffered awaiting a clean shutdown.
    func testEveryAppendIsFlushedToDisk() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)

        logger.append(type: .flag, timestamp: start.addingTimeInterval(30))
        var onDisk = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertEqual(parse(onDisk).count, 3)

        logger.append(type: .flag, timestamp: start.addingTimeInterval(60))
        onDisk = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertEqual(parse(onDisk).count, 4)
    }

    // MARK: - Ordering and elapsed time

    func testEventIndexIsSequentialAndElapsedIsMonotonic() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)

        for offset in [12.0, 45.5, 90.0] {
            logger.append(type: .flag, timestamp: start.addingTimeInterval(offset))
        }

        let rows = Array(parse(logger.csvText).dropFirst())
        XCTAssertEqual(rows.map { column("event_index", in: $0) }, ["0", "1", "2", "3"])
        XCTAssertEqual(
            rows.map { column("elapsed_s", in: $0) },
            ["0.0", "12.0", "45.5", "90.0"]
        )
    }

    func testMetadataIsRepeatedOnEveryRow() {
        let logger = makeLogger(participant: "P07", walk: .walkB, level: .navigationPlusContext)
        logger.append(type: .flag)

        for row in parse(logger.csvText).dropFirst() {
            XCTAssertEqual(column("participant_id", in: row), "P07")
            XCTAssertEqual(column("walk", in: row), "walkB")
            XCTAssertEqual(column("information_level", in: row), "Navigation + Context")
            XCTAssertEqual(column("session_mode", in: row), "study")
            XCTAssertFalse(column("session_id", in: row).isEmpty)
        }
    }

    // MARK: - Test-mode marking

    /// A test run must be distinguishable from a participant's data by the
    /// file itself, not by anyone's memory of which ID they typed.
    func testTestModeIsMarkedInTheFileNameAndEveryRow() {
        let logger = makeLogger(participant: "P03", walk: .walkA, mode: .test)
        logger.append(type: .flag)
        logger.finish()

        let name = logger.fileURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("WayWalk_TEST_P03_walkA_"), "unexpected filename \(name)")

        let rows = parse(logger.csvText).dropFirst()
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertEqual(column("session_mode", in: row), "test")
            XCTAssertEqual(column("participant_id", in: row), "P03")
        }
    }

    /// The marking has to survive a rename, which is why it is in the rows and
    /// not only the file name.
    func testStudyModeIsTheDefaultAndCarriesNoMarker() {
        let logger = makeLogger()
        XCTAssertEqual(logger.metadata.mode, .study)
        XCTAssertFalse(logger.fileURL.lastPathComponent.contains("TEST"))
        XCTAssertEqual(column("session_mode", in: parse(logger.csvText)[1]), "study")
    }

    func testStoreParsesATestFileNameBackToTheRightParticipant() {
        let logger = makeLogger(participant: "P09", walk: .walkB, mode: .test)
        logger.finish()

        let listed = SessionStore(directory: directory).sessions()
        XCTAssertEqual(listed.count, 1)
        let session = listed[0]
        XCTAssertEqual(session.mode, .test)
        XCTAssertEqual(session.participantID, "P09", "the TEST marker must not be read as the participant")
        XCTAssertEqual(session.walkID, .walkB)
        XCTAssertNotNil(session.recordedAt)
    }

    func testStoreMarksOrdinaryFilesAsNotTest() {
        makeLogger(participant: "P09", walk: .walkB).finish()
        let session = try! XCTUnwrap(SessionStore(directory: directory).sessions().first)
        XCTAssertEqual(session.mode, .study)
        XCTAssertEqual(session.participantID, "P09")
    }

    // MARK: - Waypoint rows

    func testWaypointRowCarriesWaypointAndLocationDetail() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)
        let waypoint = makeWaypoint(id: "a5", order: 5, name: "5")
        let fired = start.addingTimeInterval(300)

        logger.append(
            type: .waypointTrigger,
            timestamp: fired,
            regionEntryTime: fired.addingTimeInterval(-2),
            waypoint: waypoint,
            latitude: 51.523566,
            longitude: -0.130377,
            horizontalAccuracy: 8.5
        )

        let row = parse(logger.csvText).last!
        XCTAssertEqual(column("event_type", in: row), "waypoint_trigger")
        XCTAssertEqual(column("waypoint_id", in: row), "a5")
        XCTAssertEqual(column("waypoint_order", in: row), "5")
        XCTAssertEqual(column("waypoint_name", in: row), "5")
        XCTAssertEqual(column("latitude", in: row), "51.523566")
        XCTAssertEqual(column("longitude", in: row), "-0.130377")
        XCTAssertEqual(column("gps_accuracy_m", in: row), "8.5")
    }

    /// A waypoint time is ambiguous unless the record says whether it means
    /// "arrived" or "prompt started". Both are written; the gap is the dwell.
    func testRegionEntryIsTwoSecondsBeforeTriggerAndOnlyOnWaypointRows() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)
        let fired = start.addingTimeInterval(300)

        logger.append(
            type: .waypointTrigger,
            timestamp: fired,
            regionEntryTime: fired.addingTimeInterval(-2),
            waypoint: makeWaypoint()
        )
        logger.append(type: .flag, timestamp: start.addingTimeInterval(310))

        let rows = parse(logger.csvText)
        let waypointRow = rows[2]
        let flagRow = rows[3]

        let entry = column("region_entry_local", in: waypointRow)
        let local = column("time_local", in: waypointRow)
        XCTAssertFalse(entry.isEmpty)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let entryDate = try! XCTUnwrap(formatter.date(from: entry))
        let localDate = try! XCTUnwrap(formatter.date(from: local))
        XCTAssertEqual(localDate.timeIntervalSince(entryDate), 2, accuracy: 0.001)

        XCTAssertEqual(column("region_entry_local", in: flagRow), "")
    }

    func testLocalTimeIsWallClockFormat() {
        let logger = makeLogger()
        let row = parse(logger.csvText)[1]
        let local = column("time_local", in: row)

        XCTAssertEqual(local.count, 8)
        XCTAssertNotNil(local.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
    }

    func testISOTimeCarriesAnOffset() {
        let logger = makeLogger()
        let iso = column("time_iso", in: parse(logger.csvText)[1])
        let hasOffset = iso.hasSuffix("Z")
            || iso.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        XCTAssertTrue(hasOffset, "time_iso should be unambiguous about timezone, got \(iso)")
    }

    // MARK: - Escaping

    func testEscapeLeavesPlainFieldsAlone() {
        XCTAssertEqual(SessionLogger.escape("waypoint_trigger"), "waypoint_trigger")
        XCTAssertEqual(SessionLogger.escape(""), "")
    }

    func testEscapeQuotesCommasQuotesAndNewlines() {
        XCTAssertEqual(SessionLogger.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(SessionLogger.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(SessionLogger.escape("line1\nline2"), "\"line1\nline2\"")
    }

    func testAwkwardNoteSurvivesTheRoundTrip() {
        let logger = makeLogger()
        let awkward = "Hesitated, then said \"which way?\"\nCrossed anyway"
        logger.append(type: .flag, note: awkward)

        let rows = parse(logger.csvText)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(column("note", in: rows[2]), awkward)
    }

    // MARK: - Notes

    func testAttachNotePatchesOnlyTheTargetRow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)

        let first = logger.append(type: .flag, timestamp: start.addingTimeInterval(10))
        let second = logger.append(type: .flag, timestamp: start.addingTimeInterval(20))

        let before = parse(logger.csvText)
        logger.attachNote("participant paused at kerb", to: second)
        let after = parse(logger.csvText)

        XCTAssertEqual(before[0], after[0], "header must not change")
        XCTAssertEqual(before[1], after[1], "session_start row must not change")
        XCTAssertEqual(before[2], after[2], "the untargeted flag must not change")
        XCTAssertEqual(column("note", in: after[3]), "participant paused at kerb")
        XCTAssertEqual(column("note", in: after[2]), "")
        XCTAssertNotEqual(first, second)
    }

    /// The timestamp is the thing a flag exists to record; adding a note must
    /// not move it.
    func testAttachNoteDoesNotChangeTheTimestamp() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)
        let id = logger.append(type: .flag, timestamp: start.addingTimeInterval(42))

        let timeBefore = column("time_iso", in: parse(logger.csvText)[2])
        logger.attachNote("late note", to: id)
        let timeAfter = column("time_iso", in: parse(logger.csvText)[2])

        XCTAssertEqual(timeBefore, timeAfter)
        XCTAssertEqual(column("elapsed_s", in: parse(logger.csvText)[2]), "42.0")
    }

    func testBlankNoteIsStoredAsNoNote() {
        let logger = makeLogger()
        let id = logger.append(type: .flag)

        logger.attachNote("   \n ", to: id)
        XCTAssertNil(logger.events.last?.note)
        XCTAssertEqual(column("note", in: parse(logger.csvText)[2]), "")
    }

    func testAttachNoteToUnknownEventIsIgnored() {
        let logger = makeLogger()
        let before = logger.csvText
        logger.attachNote("nowhere", to: UUID())
        XCTAssertEqual(before, logger.csvText)
    }

    // MARK: - Undo

    /// A retracted flag leaves a gap in event_index rather than renumbering,
    /// so the record shows that something was withdrawn.
    func testRemoveLeavesAGapInEventIndex() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)

        logger.append(type: .flag, timestamp: start.addingTimeInterval(10))
        let mistake = logger.append(type: .flag, timestamp: start.addingTimeInterval(20))
        logger.append(type: .flag, timestamp: start.addingTimeInterval(30))

        logger.remove(eventID: mistake)

        let indices = parse(logger.csvText).dropFirst().map { column("event_index", in: $0) }
        XCTAssertEqual(indices, ["0", "1", "3"])
    }

    // MARK: - Finishing

    func testFinishWritesSessionEndAndRecordsEndTime() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)
        let finished = start.addingTimeInterval(1_800)

        logger.finish(at: finished)

        XCTAssertEqual(logger.metadata.endedAt, finished)
        let last = parse(logger.csvText).last!
        XCTAssertEqual(column("event_type", in: last), "session_end")
        XCTAssertEqual(column("elapsed_s", in: last), "1800.0")
    }

    // MARK: - Filenames

    func testFileNameCarriesParticipantAndWalk() {
        let logger = makeLogger(participant: "P03", walk: .walkB)
        let name = logger.fileURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("WayWalk_P03_walkB_"), "unexpected filename \(name)")
        XCTAssertTrue(name.hasSuffix(".csv"))
    }

    func testSanitiseKeepsFilenamesAndTheIDSeparatorUnambiguous() {
        XCTAssertEqual(SessionLogger.sanitise("P03"), "P03")
        XCTAssertEqual(SessionLogger.sanitise("  P03  "), "P03")
        XCTAssertEqual(SessionLogger.sanitise("P 03"), "P-03")
        XCTAssertEqual(SessionLogger.sanitise("P/03"), "P-03")
        // Underscores separate the fields of a session ID, so they cannot
        // survive inside a participant ID.
        XCTAssertEqual(SessionLogger.sanitise("P_03"), "P-03")
        XCTAssertEqual(SessionLogger.sanitise(""), "unknown")
    }

    /// The raw, unsanitised ID still reaches the CSV — the sanitising exists
    /// for the filename, not to quietly rewrite study data.
    func testUnsanitisedParticipantIDIsPreservedInTheRows() {
        let logger = makeLogger(participant: "P 03")
        XCTAssertEqual(column("participant_id", in: parse(logger.csvText)[1]), "P 03")
        XCTAssertTrue(logger.fileURL.lastPathComponent.contains("P-03"))
    }

    // MARK: - SessionStore

    func testStoreListsSessionsNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = makeLogger(participant: "P01", walk: .walkA, startedAt: base)
        let newer = makeLogger(participant: "P02", walk: .walkB, startedAt: base.addingTimeInterval(3_600))
        older.finish(at: base.addingTimeInterval(60))
        newer.finish(at: base.addingTimeInterval(3_660))

        let listed = SessionStore(directory: directory).sessions()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first?.participantID, "P02")
        XCTAssertEqual(listed.first?.walkID, .walkB)
        XCTAssertEqual(listed.last?.participantID, "P01")
        XCTAssertEqual(listed.last?.walkID, .walkA)
        XCTAssertGreaterThan(listed.first?.byteCount ?? 0, 0)
    }

    func testStoreDeletesASession() {
        let logger = makeLogger()
        let store = SessionStore(directory: directory)
        let session = try! XCTUnwrap(store.sessions().first)

        store.delete(session)

        XCTAssertTrue(store.sessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logger.fileURL.path))
    }

    func testStoreOnMissingDirectoryIsEmptyRatherThanACrash() {
        let missing = directory.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(SessionStore(directory: missing).sessions().isEmpty)
    }

    func testManualModeIsMarkedInTheFileNameAndEveryRow() {
        let logger = makeLogger(participant: "P05", walk: .walkA, mode: .manual)
        logger.append(type: .waypointTrigger, waypoint: makeWaypoint())
        logger.finish()

        let name = logger.fileURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("WayWalk_MANUAL_P05_walkA_"), "unexpected filename \(name)")

        let rows = parse(logger.csvText).dropFirst()
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertEqual(column("session_mode", in: row), "manual")
            XCTAssertEqual(column("participant_id", in: row), "P05")
        }
    }

    func testStoreParsesAManualFileNameBackToTheRightParticipant() {
        let logger = makeLogger(participant: "P08", walk: .walkA, mode: .manual)
        logger.finish()

        let listed = SessionStore(directory: directory).sessions()
        XCTAssertEqual(listed.count, 1)
        let session = listed[0]
        XCTAssertEqual(session.mode, .manual)
        XCTAssertEqual(session.participantID, "P08", "the MANUAL marker must not be read as the participant")
        XCTAssertEqual(session.walkID, .walkA)
        XCTAssertNotNil(session.recordedAt)
    }

    /// In manual mode the two timestamps mean different things: arrival is when
    /// CoreLocation reported the radius, and the event time is when the
    /// researcher actually cued the prompt. The gap between them is the thing
    /// the mode exists to measure, so both must survive into the CSV.
    func testManualRowKeepsArrivalAndPlayTimesSeparate() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(mode: .manual, startedAt: start)
        let arrived = start.addingTimeInterval(60)
        let played = start.addingTimeInterval(75)

        logger.append(
            type: .waypointTrigger,
            timestamp: played,
            regionEntryTime: arrived,
            waypoint: makeWaypoint()
        )

        let row = parse(logger.csvText).last!
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let entry = try! XCTUnwrap(formatter.date(from: column("region_entry_local", in: row)))
        let local = try! XCTUnwrap(formatter.date(from: column("time_local", in: row)))
        XCTAssertEqual(local.timeIntervalSince(entry), 15, accuracy: 0.001)
        XCTAssertEqual(column("elapsed_s", in: row), "75.0")
    }

    func testEveryModeMarkerIsDistinctAndStudyHasNone() {
        XCTAssertNil(SessionMode.study.fileNameMarker)
        XCTAssertEqual(SessionMode.test.fileNameMarker, "TEST")
        XCTAssertEqual(SessionMode.manual.fileNameMarker, "MANUAL")
        let markers = SessionMode.allCases.compactMap(\.fileNameMarker)
        XCTAssertEqual(Set(markers).count, markers.count, "markers must be unambiguous in a filename")
    }

    // MARK: - Trigger source

    /// A prompt the researcher forced is not the same observation as one the
    /// participant's arrival produced. If both logged identically, a rescued
    /// walk would be silently indistinguishable from a clean one.
    func testTriggerSourceDistinguishesForcedPromptsFromArrivals() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = makeLogger(startedAt: start)

        logger.append(
            type: .waypointTrigger, timestamp: start.addingTimeInterval(60),
            waypoint: makeWaypoint(id: "a1"), triggerSource: .geofence
        )
        logger.append(
            type: .waypointTrigger, timestamp: start.addingTimeInterval(120),
            waypoint: makeWaypoint(id: "a2", order: 2), triggerSource: .manual
        )

        let rows = parse(logger.csvText)
        XCTAssertEqual(column("trigger_source", in: rows[2]), "geofence")
        XCTAssertEqual(column("trigger_source", in: rows[3]), "manual")
    }

    /// Only waypoint rows carry a source — a flag or a session boundary was
    /// not "triggered" by anything.
    func testNonWaypointRowsHaveNoTriggerSource() {
        let logger = makeLogger()
        logger.append(type: .flag)
        logger.finish()

        for row in parse(logger.csvText).dropFirst() where
            column("event_type", in: row) != "waypoint_trigger" {
            XCTAssertEqual(column("trigger_source", in: row), "")
        }
    }

    // MARK: - Closest approach

    /// The diagnostic for a missed geofence: how near the participant actually
    /// got. Compared with the waypoint's radius it separates "never got close
    /// enough" from "was well inside and CoreLocation missed it".
    func testClosestApproachIsRecordedOnManualRows() {
        let logger = makeLogger()
        logger.append(
            type: .waypointTrigger,
            waypoint: makeWaypoint(),
            triggerSource: .manual,
            closestApproachMetres: 23.7
        )

        let row = parse(logger.csvText).last!
        XCTAssertEqual(column("closest_approach_m", in: row), "23.7")
        XCTAssertEqual(column("trigger_source", in: row), "manual")
    }

    /// A geofence row's closest approach is inside the radius by definition,
    /// so the column stays empty rather than restating the obvious.
    func testGeofenceRowsCarryNoClosestApproach() {
        let logger = makeLogger()
        logger.append(type: .waypointTrigger, waypoint: makeWaypoint(), triggerSource: .geofence)
        XCTAssertEqual(column("closest_approach_m", in: parse(logger.csvText).last!), "")
    }

    /// Never leaves a stale distance from a previous waypoint behind — an
    /// unknown approach must read as unknown, not as someone else's number.
    func testUnknownClosestApproachIsBlankNotZero() {
        let logger = makeLogger()
        logger.append(
            type: .waypointTrigger, waypoint: makeWaypoint(),
            triggerSource: .manual, closestApproachMetres: nil
        )
        let value = column("closest_approach_m", in: parse(logger.csvText).last!)
        XCTAssertEqual(value, "", "blank, not \"0.0\" — zero would read as standing on the waypoint")
    }

    func testFlagRowsCarryNoClosestApproach() {
        let logger = makeLogger()
        logger.append(type: .flag)
        XCTAssertEqual(column("closest_approach_m", in: parse(logger.csvText).last!), "")
    }
}
