import AVFoundation

/// Default audio backend: on-device speech synthesis via AVSpeechSynthesizer.
/// Works immediately with no recording required. Selects the highest-quality
/// UK English voice available and automatically resumes speech after audio
/// interruptions (calls, notifications, Siri).
final class SpeechPromptPlayer: NSObject, AudioPromptPlaying {
    private let synthesizer = AVSpeechSynthesizer()
    private var completionHandler: (() -> Void)?
    private let voice: AVSpeechSynthesisVoice?

    override init() {
        self.voice = SpeechPromptPlayer.bestAvailableUKVoice()
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

    /// Picks the best UK English voice iOS exposes: an explicit Siri voice if
    /// the system surfaces one via AVSpeechSynthesisVoice, otherwise the
    /// highest quality tier available (premium, then enhanced), otherwise any
    /// en-GB voice, otherwise the system default for the current locale.
    private static func bestAvailableUKVoice() -> AVSpeechSynthesisVoice? {
        let ukVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }

        if let siriVoice = ukVoices.first(where: { $0.identifier.lowercased().contains("siri") }) {
            return siriVoice
        }
        if let premium = ukVoices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = ukVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        if let anyUK = ukVoices.first {
            return anyUK
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    func play(key: String, script: String, completion: (() -> Void)? = nil) {
        completionHandler = completion
        let utterance = AVSpeechUtterance(string: script)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        completionHandler = nil
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
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        completionHandler = nil
    }
}
