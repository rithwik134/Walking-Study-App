import AVFoundation

/// Plays pre-recorded MP3 prompts from the bundle, falling back to on-device
/// speech synthesis when a recording is missing. The fallback means a single
/// absent file never silences a navigation instruction — the participant hears
/// the TTS version instead, and the walk continues without intervention.
///
/// To use, add MP3 files named to match each waypoint's audio key (e.g.
/// "a2_nav.mp3", "a2_context.mp3") to the RecordedWaypointAudio folder in the
/// bundle, then switch WalkSession to use this player:
///
///     WalkSession(audioPlayer: RecordedAudioPromptPlayer())
///
/// Unlike `AVSpeechSynthesizer`, `AVAudioPlayer` has no queue of its own —
/// starting a second file simply replaces the first, cutting it off mid-word.
/// This class therefore keeps its own queue, so back-to-back waypoints behave
/// the same way they do under speech synthesis: the second prompt waits rather
/// than destroying the first. Without it, closely spaced waypoints would cost
/// the participant an entire navigation instruction.
final class RecordedAudioPromptPlayer: NSObject, AudioPromptPlaying {
    private struct PendingPrompt {
        let key: String
        let script: String
        let completion: (() -> Void)?
    }

    private var player: AVAudioPlayer?
    private let fallbackSynthesizer = AVSpeechSynthesizer()
    private var isSpeakingFallback = false
    private var queue: [PendingPrompt] = []
    private var currentCompletion: (() -> Void)?
    private var isPlaying: Bool { player != nil || isSpeakingFallback }

    /// Silence before a prompt that was queued behind another, matching
    /// `SpeechPromptPlayer`. Close-together waypoints otherwise run their
    /// instructions together with no audible break.
    private let gapBetweenQueuedPrompts: TimeInterval = 1.2

    private var cachedFallbackVoice: AVSpeechSynthesisVoice?

    /// The subdirectory inside the app bundle where recorded MP3 files live.
    /// A folder reference in Xcode preserves this directory structure at build
    /// time, so `Bundle.main.url(forResource:withExtension:subdirectory:)` finds
    /// them here rather than at the bundle root.
    static let bundleSubdirectory = "RecordedWaypointAudio"

    override init() {
        super.init()
        fallbackSynthesizer.delegate = self
        do {
            // allowBluetoothHFP is `allowBluetooth` renamed — same option bit,
            // available on every supported iOS — so it needs no availability
            // check and changes no routing. Matches `SpeechPromptPlayer`.
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
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

    // MARK: - AudioPromptPlaying

    var voiceDescription: String {
        if cachedFallbackVoice == nil { resolveFallbackVoice() }
        let voiceName = cachedFallbackVoice.map { voice -> String in
            let quality: String
            switch voice.quality {
            case .premium: quality = "premium"
            case .enhanced: quality = "enhanced"
            case .default: quality = "compact"
            @unknown default: quality = "unknown"
            }
            return "\(voice.name) (\(quality))"
        } ?? "system default"
        return "Recorded audio (TTS fallback: \(voiceName))"
    }

    func play(key: String, script: String, completion: (() -> Void)? = nil) {
        queue.append(PendingPrompt(key: key, script: script, completion: completion))
        if !isPlaying { startNextPrompt(afterAnotherPrompt: false) }
    }

    /// Stops immediately and abandons everything queued behind it.
    ///
    /// Pending completions are dropped rather than called: they mean "this
    /// prompt finished", and a prompt that was cut off did not.
    func stop() {
        player?.stop()
        player = nil
        fallbackSynthesizer.stopSpeaking(at: .immediate)
        isSpeakingFallback = false
        currentCompletion = nil
        queue.removeAll()
    }

    // MARK: - Queue

    /// Starts the next queued prompt, trying the recorded file first and
    /// falling back to TTS when no recording exists.
    ///
    /// A missing file with an empty script still calls its completion and moves
    /// on, so a context-only waypoint played in Navigation Only mode neither
    /// stalls the queue nor speaks silence.
    private func startNextPrompt(afterAnotherPrompt: Bool) {
        player = nil
        isSpeakingFallback = false
        currentCompletion = nil

        while !queue.isEmpty {
            let next = queue.removeFirst()

            if let url = Bundle.main.url(
                forResource: next.key, withExtension: "mp3",
                subdirectory: Self.bundleSubdirectory
            ) {
                do {
                    let newPlayer = try AVAudioPlayer(contentsOf: url)
                    newPlayer.delegate = self
                    player = newPlayer
                    currentCompletion = next.completion
                    if afterAnotherPrompt {
                        newPlayer.play(atTime: newPlayer.deviceCurrentTime + gapBetweenQueuedPrompts)
                    } else {
                        newPlayer.play()
                    }
                    return
                } catch {
                    print("Playback error for \(next.key): \(error)")
                }
            }

            let trimmed = next.script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                next.completion?()
                continue
            }

            print("No recording for \(next.key) — falling back to TTS")
            let utterance = AVSpeechUtterance(string: next.script)
            utterance.voice = resolveFallbackVoice()
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.preUtteranceDelay = afterAnotherPrompt ? gapBetweenQueuedPrompts : 0
            currentCompletion = next.completion
            isSpeakingFallback = true
            fallbackSynthesizer.speak(utterance)
            return
        }
    }

    // MARK: - TTS voice

    @discardableResult
    private func resolveFallbackVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let ukVoices = all.filter { $0.language == "en-GB" }
        let resolved = ukVoices.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? all.filter({ $0.language.hasPrefix("en") })
                .max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        if resolved?.identifier != cachedFallbackVoice?.identifier {
            cachedFallbackVoice = resolved
        }
        return resolved
    }

    // MARK: - Interruption handling

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            player?.pause()
            if fallbackSynthesizer.isSpeaking {
                fallbackSynthesizer.pauseSpeaking(at: .word)
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
            if shouldResume {
                if let player {
                    player.play()
                } else if fallbackSynthesizer.isPaused {
                    fallbackSynthesizer.continueSpeaking()
                }
            }

        @unknown default:
            break
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension RecordedAudioPromptPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }

        let completion = currentCompletion
        currentCompletion = nil
        completion?()
        startNextPrompt(afterAnotherPrompt: true)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension RecordedAudioPromptPlayer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard isSpeakingFallback else { return }
        let completion = currentCompletion
        currentCompletion = nil
        isSpeakingFallback = false
        completion?()
        startNextPrompt(afterAnotherPrompt: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard isSpeakingFallback else { return }
        isSpeakingFallback = false
        currentCompletion = nil
    }
}
