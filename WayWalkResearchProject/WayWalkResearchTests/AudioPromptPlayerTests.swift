import XCTest
import AVFoundation
@testable import WayWalkResearch

/// Covers completion delivery when prompts overlap.
///
/// This is the case the app now hits routinely: waypoints can fire ~2s apart
/// where trigger radii overlap, and Manual Mode's cue button lets a researcher
/// queue prompts deliberately. Both players previously kept a single
/// completion handler, so queued prompts dropped all but the last completion
/// and fired that one against the wrong prompt.
final class AudioPromptPlayerTests: XCTestCase {

    // MARK: - SpeechPromptPlayer

    /// The regression test for the original bug: with two prompts queued, each
    /// completion must fire exactly once, for its own utterance, and in order.
    func testQueuedSpeechPromptsEachGetTheirOwnCompletion() {
        let player = SpeechPromptPlayer()
        let first = expectation(description: "first prompt completes")
        let second = expectation(description: "second prompt completes")

        var order: [String] = []
        player.play(key: "one", script: "One.") {
            order.append("one")
            first.fulfill()
        }
        player.play(key: "two", script: "Two.") {
            order.append("two")
            second.fulfill()
        }

        wait(for: [first, second], timeout: 30)
        // Before the fix, "one" never arrived at all and "two" fired when the
        // first utterance ended.
        XCTAssertEqual(order, ["one", "two"])
    }

    /// Three deep is what Manual Mode makes easy — press the cue button
    /// repeatedly. Previously two of the three completions vanished.
    func testThreeQueuedSpeechPromptsAllComplete() {
        let player = SpeechPromptPlayer()
        let expectations = (1...3).map { expectation(description: "prompt \($0)") }

        for (index, expectation) in expectations.enumerated() {
            player.play(key: "k\(index)", script: "Test.") { expectation.fulfill() }
        }

        wait(for: expectations, timeout: 45, enforceOrder: true)
    }

    /// A prompt that is cut off did not finish, so its completion must not be
    /// called — but it must also not linger and fire against a later prompt.
    func testStoppingDropsPendingSpeechCompletions() {
        let player = SpeechPromptPlayer()
        var fired = 0

        player.play(key: "one", script: "A rather longer sentence that will be interrupted.") {
            fired += 1
        }
        player.play(key: "two", script: "And another one behind it.") { fired += 1 }
        player.stop()

        // Give the synthesiser a moment to deliver any cancellation callbacks.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 10)

        XCTAssertEqual(fired, 0, "a cut-off prompt has not finished, so nothing should be signalled")
    }

    func testSpeechPlayerReportsAVoice() {
        XCTAssertFalse(SpeechPromptPlayer().voiceDescription.isEmpty)
    }

    // MARK: - RecordedAudioPromptPlayer

    /// Empty scripts with no recording complete synchronously — a context-only
    /// waypoint in Navigation Only mode must not stall the queue.
    func testMissingRecordingsWithEmptyScriptsStillCompleteInOrder() {
        let player = RecordedAudioPromptPlayer()
        var order: [String] = []

        for key in ["missing_1", "missing_2", "missing_3"] {
            player.play(key: key, script: "") { order.append(key) }
        }

        XCTAssertEqual(order, ["missing_1", "missing_2", "missing_3"])
    }

    func testRecordedPlayerCompletesEvenWithNoCompletionOnSomePrompts() {
        let player = RecordedAudioPromptPlayer()
        var completed = 0

        player.play(key: "missing_one", script: "", completion: nil)
        player.play(key: "missing_two", script: "") { completed += 1 }

        XCTAssertEqual(completed, 1, "a nil completion must not stall the queue behind it")
    }

    func testStoppingClearsTheRecordedQueue() {
        let player = RecordedAudioPromptPlayer()
        player.stop()
        var completed = 0
        player.play(key: "missing", script: "") { completed += 1 }
        XCTAssertEqual(completed, 1)
    }

    func testRecordedPlayerReportsVoiceWithFallbackInfo() {
        let desc = RecordedAudioPromptPlayer().voiceDescription
        XCTAssertTrue(desc.hasPrefix("Recorded audio (TTS fallback:"),
                      "expected fallback voice info, got \(desc)")
    }

    /// A missing recording with a non-empty script falls back to TTS rather
    /// than skipping silently — the participant must always hear the
    /// instruction, even if the mp3 was accidentally left out.
    func testMissingRecordingFallsBackToTTS() {
        let player = RecordedAudioPromptPlayer()
        let completed = expectation(description: "TTS fallback completes")

        player.play(key: "nonexistent_key", script: "Test.") {
            completed.fulfill()
        }

        wait(for: [completed], timeout: 30)
    }

    /// Two missing recordings in sequence must both complete via TTS, in order.
    func testFallbackTTSMaintainsQueueOrder() {
        let player = RecordedAudioPromptPlayer()
        let first = expectation(description: "first fallback")
        let second = expectation(description: "second fallback")

        var order: [String] = []
        player.play(key: "missing_a", script: "One.") {
            order.append("a")
            first.fulfill()
        }
        player.play(key: "missing_b", script: "Two.") {
            order.append("b")
            second.fulfill()
        }

        wait(for: [first, second], timeout: 30)
        XCTAssertEqual(order, ["a", "b"])
    }

    /// Whitespace-only scripts are treated as empty — no TTS fallback, no
    /// stalled queue. This is the path a context-only waypoint takes when
    /// played in Navigation Only mode with no recording present.
    func testWhitespaceOnlyScriptWithNoRecordingCompletesImmediately() {
        let player = RecordedAudioPromptPlayer()
        var completed = false

        player.play(key: "missing", script: "   \n  ") { completed = true }

        XCTAssertTrue(completed, "whitespace-only script must not start TTS")
    }
}


/// A stand-in audio backend whose "speech" finishes only when the test says
/// so, making the banner's lifetime deterministic instead of dependent on how
/// long a real sentence takes to speak.
final class FakePromptPlayer: AudioPromptPlaying {
    private(set) var scripts: [String] = []
    private var pending: [() -> Void] = []

    func play(key: String, script: String, completion: (() -> Void)?) {
        scripts.append(script)
        if let completion { pending.append(completion) }
    }

    func stop() { pending.removeAll() }

    /// Completes the oldest outstanding utterance.
    func finishOldest() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()()
    }
}

/// The banner is the only status the walk screens show, so its lifetime has to
/// be exact: present while a prompt speaks, gone afterwards, and persistent
/// once the walk is over.
@MainActor
final class WalkSessionBannerTests: XCTestCase {

    private func makeSession(
        level: InformationLevel = .navigationOnly
    ) throws -> (WalkSession, Walk, FakePromptPlayer) {
        let player = FakePromptPlayer()
        let session = WalkSession(audioPlayer: player)
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        // .test so these runs are marked and never mistaken for study data.
        session.start(walk: walk, informationLevel: level,
                      participantID: "BANNERTEST", mode: .test)
        return (session, walk, player)
    }

    func testNoBannerWhileSimplyWalking() throws {
        let (session, _, _) = try makeSession()
        XCTAssertNil(session.banner, "an armed waypoint is not worth a banner")
    }

    func testBannerShowsWhileAPromptSpeaksAndClearsWhenItEnds() async throws {
        let (session, walk, player) = try makeSession()

        session.playCurrentWaypoint()
        XCTAssertEqual(session.banner, .playing(waypointName: walk.waypoints[0].name))

        player.finishOldest()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.banner, "the banner must not outlive the speech")
    }

    /// The banner must name what the participant can *hear*, not what fired
    /// most recently. Overlapping trigger radii on these routes mean waypoint
    /// n+1 can fire ~2s into waypoint n's prompt, and the synthesiser queues
    /// it — so announcing n+1 immediately would label audio that is still
    /// several seconds away.
    func testBannerNamesTheAudiblePromptNotTheLatestTrigger() async throws {
        // Navigation + Context, because a2 is context-only and so speaks
        // nothing at all in Navigation Only — there would be no queue.
        let (session, walk, player) = try makeSession(level: .navigationPlusContext)

        session.playCurrentWaypoint()
        session.playCurrentWaypoint()
        XCTAssertEqual(
            session.banner, .playing(waypointName: walk.waypoints[0].name),
            "waypoint 2 is queued behind waypoint 1, so waypoint 1 is what is playing"
        )

        player.finishOldest() // waypoint 1 ends; waypoint 2 becomes audible
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.banner, .playing(waypointName: walk.waypoints[1].name))

        player.finishOldest()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.banner)
    }

    /// `currentWaypointNumber` deliberately stays on the last waypoint when a
    /// route ends, so completion has to come from its own flag — otherwise the
    /// cue button offers to play waypoint 28 forever.
    func testRouteCompletionIsReportedOnceEveryWaypointHasPlayed() async throws {
        let (session, walk, player) = try makeSession(level: .navigationPlusContext)
        XCTAssertFalse(session.routeIsComplete)

        for _ in walk.waypoints {
            session.playCurrentWaypoint()
            player.finishOldest()
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(session.routeIsComplete)
        XCTAssertEqual(session.triggeredWaypointIDs.count, walk.waypoints.count)
        XCTAssertEqual(session.banner, .ended, "the finished banner stays on screen")
    }

    func testEndingTheWalkLeavesTheEndedBannerOnScreen() throws {
        let (session, _, _) = try makeSession()
        session.end()
        XCTAssertEqual(session.banner, .ended)
    }

    /// A context-only waypoint speaks nothing in Navigation Only, so claiming
    /// "Playing" would be false — and an empty utterance may never report
    /// completion, which would strand the banner.
    func testSilentWaypointRaisesNoBanner() throws {
        let player = FakePromptPlayer()
        let session = WalkSession(audioPlayer: player)
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        session.start(walk: walk, informationLevel: .navigationOnly,
                      participantID: "BANNERTEST", mode: .test)

        // a2 is context-only; advance onto it, then play.
        session.playCurrentWaypoint()
        XCTAssertEqual(session.currentWaypointNumber, 2)
        XCTAssertTrue(walk.waypoints[1].navigationPrompt.isEmpty, "a2 should be context-only")

        session.playCurrentWaypoint()
        XCTAssertEqual(
            session.banner, .playing(waypointName: walk.waypoints[0].name),
            "the silent waypoint must not raise a banner of its own"
        )
    }
}
