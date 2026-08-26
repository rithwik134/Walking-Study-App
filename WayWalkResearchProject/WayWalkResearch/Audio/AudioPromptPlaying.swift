import Foundation

/// Abstraction over "how a prompt is delivered as audio". WalkSession only
/// ever talks to this protocol, so swapping speech synthesis for recorded
/// audio files later means adding one new class — nothing else in the app
/// needs to change.
protocol AudioPromptPlaying: AnyObject {
    /// - Parameters:
    ///   - key: A stable identifier for this audio segment (e.g. "a2_nav").
    ///          Ignored by the speech synthesiser; a recorded-audio player
    ///          would use it to look up "a2_nav.mp3" in the bundle.
    ///   - script: The text to speak. Ignored by a recorded-audio player.
    ///   - completion: Called when playback finishes. Each waypoint plays
    ///          exactly one script (see InformationLevel), so this currently
    ///          only signals "done" — it's kept as a parameter because it's
    ///          the natural place to hang any future multi-step playback on
    ///          (e.g. a chime before the recorded-audio version speaks).
    func play(key: String, script: String, completion: (() -> Void)?)
    func stop()

    /// Human-readable description of the voice actually in use, for the
    /// researcher debug panel.
    ///
    /// Worth surfacing because the quality tier is invisible from inside the
    /// app otherwise: Enhanced and Premium voices are user downloads, so
    /// whether a walk sounds natural or robotic depends on device settings
    /// rather than on anything in this codebase. Without a readout, "did the
    /// voice download actually take effect?" is unanswerable on the phone.
    var voiceDescription: String { get }
}

extension AudioPromptPlaying {
    /// Backends that do not synthesise speech have no voice to report.
    var voiceDescription: String { "Recorded audio" }
}
