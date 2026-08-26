import AVFoundation

/// Default audio backend: on-device speech synthesis via AVSpeechSynthesizer.
/// Works immediately with no recording required. Selects the highest-quality
/// UK English voice available and automatically resumes speech after audio
/// interruptions (calls, notifications, Siri).
///
/// **Siri's voice is not obtainable here.** Apple does not expose Siri voices
/// to third-party apps: enumerating `AVSpeechSynthesisVoice.speechVoices()` on
/// device returns none whose identifier contains "siri", and building one by
/// identifier returns nil. The best available is a Premium voice, which sounds
/// natural but is audibly a different voice from Siri.
///
/// **Quality depends on device settings, not on this code.** Premium and
/// Enhanced voices are user downloads; a phone with neither installed offers
/// only `.default` (compact) voices, which are the robotic ones. Install a
/// better voice under Settings › Accessibility › Spoken Content › Voices, then
/// check `voiceDescription` in the walk screen's debug panel to confirm the
/// app picked it up.
final class SpeechPromptPlayer: NSObject, AudioPromptPlaying {
    private let synthesizer = AVSpeechSynthesizer()

    /// Completion handlers keyed by the utterance they belong to.
    ///
    /// `AVSpeechSynthesizer.speak` **enqueues** — it does not interrupt — so
    /// several utterances can be in flight at once, and `didFinish` reports
    /// which one ended. A single stored handler could not represent that: each
    /// `play` overwrote the previous one, so with N queued prompts N-1
    /// completions were dropped and the last was invoked when the *first*
    /// utterance ended. Silently, with no crash or log to notice it by.
    ///
    /// `AVSpeechUtterance` is an `NSObject` and hashes by identity, so it can
    /// key the dictionary directly. Keying on `ObjectIdentifier` instead would
    /// risk an address being reused by a later allocation; holding the
    /// utterance strongly here cannot. Entries are removed on finish, on
    /// cancel and in `stop`, so nothing accumulates.
    private var completionHandlers: [AVSpeechUtterance: () -> Void] = [:]

    /// Last resolved voice. Re-resolved on every utterance rather than fixed
    /// at init, because voices can be downloaded while the app is installed —
    /// caching once meant a freshly downloaded Premium voice did nothing until
    /// the app was force-quit and relaunched, which reads exactly like the
    /// download having failed.
    private var cachedVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback keeps audio playing with the screen locked and the
            // silent switch on. allowBluetooth / allowBluetoothA2DP route
            // audio to bone-conduction headphones the same way as any other
            // connected Bluetooth output.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }

    /// Picks the best UK English voice installed, highest quality tier first.
    ///
    /// There is deliberately no check for a Siri voice: Apple filters those
    /// out of `speechVoices()` for third-party apps, so a previous
    /// `identifier.contains("siri")` branch here could never match and only
    /// suggested the app could sound like Siri when it cannot.
    private static func bestAvailableUKVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let ukVoices = all.filter { $0.language == "en-GB" }

        // Premium > Enhanced > Default. The first two are user downloads; with
        // neither installed only compact voices remain, which are the robotic
        // ones people complain about.
        if let best = ukVoices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return best
        }
        // No en-GB at all — any English is a better fallback than a voice that
        // reads British street names in another accent.
        if let anyEnglish = all.filter({ $0.language.hasPrefix("en") })
            .max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return anyEnglish
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Re-resolves the voice, so one downloaded mid-session takes effect
    /// without relaunching. Cheap next to speaking a sentence, and this runs
    /// at most once per waypoint.
    @discardableResult
    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        let resolved = Self.bestAvailableUKVoice()
        if resolved?.identifier != cachedVoice?.identifier {
            cachedVoice = resolved
            print("Speech voice now: \(Self.describe(resolved))")
        }
        return resolved
    }

    var voiceDescription: String {
        if cachedVoice == nil { resolveVoice() }
        return Self.describe(cachedVoice)
    }

    private static func describe(_ voice: AVSpeechSynthesisVoice?) -> String {
        guard let voice else { return "System default" }
        let quality: String
        switch voice.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "enhanced"
        case .default: quality = "compact"
        @unknown default: quality = "unknown"
        }
        return "\(voice.name) (\(quality))"
    }

    func play(key: String, script: String, completion: (() -> Void)? = nil) {
        let utterance = AVSpeechUtterance(string: script)
        utterance.voice = resolveVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let completion {
            completionHandlers[utterance] = completion
        }
        synthesizer.speak(utterance)
    }

    /// Stops immediately and abandons anything queued behind it.
    ///
    /// Pending completions are dropped rather than called: they signal
    /// "this prompt finished", and a prompt cut off part-way did not.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        completionHandlers.removeAll()
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Something else has taken audio focus (a call, Siri, a
            // notification sound). Pause explicitly so we know exactly
            // where to resume from, rather than relying on the utterance
            // simply being cut off.
            if synthesizer.isSpeaking {
                synthesizer.pauseSpeaking(at: .word)
            }

        case .ended:
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Could not reactivate audio session after interruption: \(error)")
            }
            var shouldResume = true
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            }
            if shouldResume, synthesizer.isPaused {
                synthesizer.continueSpeaking()
            }

        @unknown default:
            break
        }
    }
}

extension SpeechPromptPlayer: AVSpeechSynthesizerDelegate {
    // Both callbacks resolve the handler from the `utterance` they are handed.
    // Using it is the whole fix: the delegate is one-to-many, and reading a
    // single shared slot attributed a completion to whichever prompt happened
    // to finish first.

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        completionHandlers.removeValue(forKey: utterance)?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        completionHandlers.removeValue(forKey: utterance)
    }
}
