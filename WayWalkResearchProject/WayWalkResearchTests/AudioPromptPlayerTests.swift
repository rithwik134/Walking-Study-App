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

    /// No recordings are bundled yet, so every key falls through the
    /// "missing file" path. That path still has to complete each prompt and
    /// keep draining the queue — one absent recording must not strand
    /// everything queued behind it.
    func testMissingRecordingsStillCompleteInOrder() {
        let player = RecordedAudioPromptPlayer()
        var order: [String] = []

        for key in ["a1_nav", "a2_nav", "a3_nav"] {
            player.play(key: key, script: "") { order.append(key) }
        }

        XCTAssertEqual(order, ["a1_nav", "a2_nav", "a3_nav"])
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
        // Nothing queued, nothing playing — stop must be safe to call anyway,
        // since `WalkSession.end()` calls it whether or not a prompt is live.
        var completed = 0
        player.play(key: "missing", script: "") { completed += 1 }
        XCTAssertEqual(completed, 1)
    }

    /// The default on the protocol, so a recorded-audio backend needs no
    /// voice-reporting code of its own.
    func testRecordedPlayerReportsNoSynthesisedVoice() {
        XCTAssertEqual(RecordedAudioPromptPlayer().voiceDescription, "Recorded audio")
    }
}
