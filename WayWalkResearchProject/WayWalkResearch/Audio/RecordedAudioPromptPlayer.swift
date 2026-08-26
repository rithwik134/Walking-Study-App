import AVFoundation

/// FUTURE: once you have recorded audio, add files named to match each key
/// (e.g. "a2_nav.mp3", "a2_context.mp3") to the app bundle, then switch
/// WalkSession to use this instead of SpeechPromptPlayer:
///
///     WalkSession(audioPlayer: RecordedAudioPromptPlayer())
///
/// Nothing else in the app changes — HomeView, ActiveWalkView, and
/// WalkSession's triggering logic all depend only on AudioPromptPlaying.
/// Unlike `AVSpeechSynthesizer`, `AVAudioPlayer` has no queue of its own —
/// starting a second file simply replaces the first, cutting it off mid-word.
/// This class therefore keeps its own queue, so back-to-back waypoints behave
/// the same way they do under speech synthesis: the second prompt waits rather
/// than destroying the first. Without it, closely spaced waypoints would cost
/// the participant an entire navigation instruction.
final class RecordedAudioPromptPlayer: NSObject, AudioPromptPlaying {
    /// One queued prompt: what to play, and who to tell when it has played.
    private struct PendingPrompt {
        let key: String
        let completion: (() -> Void)?
    }

    private var player: AVAudioPlayer?
    /// Prompts waiting behind the one currently playing.
    private var queue: [PendingPrompt] = []
    /// The completion for the prompt currently playing, if any.
    private var currentCompletion: (() -> Void)?
    private var isPlaying: Bool { player != nil }

    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetooth, .allowBluetoothA2DP]
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

    func play(key: String, script: String, completion: (() -> Void)? = nil) {
        queue.append(PendingPrompt(key: key, completion: completion))
        if !isPlaying { startNextPrompt() }
    }

    /// Starts the next queued prompt, skipping any that cannot be played.
    ///
    /// A missing or unreadable file still calls its completion and moves on,
    /// so one absent recording cannot strand everything queued behind it.
    /// Iterative rather than recursive: a route with no recordings at all
    /// would otherwise recurse once per waypoint.
    private func startNextPrompt() {
        player = nil
        currentCompletion = nil

        while !queue.isEmpty {
            let next = queue.removeFirst()

            guard let url = Bundle.main.url(forResource: next.key, withExtension: "mp3") else {
                print("No recorded audio file named \(next.key).mp3 in the bundle — skipping.")
                next.completion?()
                continue
            }
            do {
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.delegate = self
                player = newPlayer
                currentCompletion = next.completion
                newPlayer.play()
                return
            } catch {
                print("Playback error for \(next.key): \(error)")
                next.completion?()
                continue
            }
        }
    }

    /// Stops immediately and abandons everything queued behind it.
    ///
    /// Pending completions are dropped rather than called: they mean "this
    /// prompt finished", and a prompt that was cut off did not.
    func stop() {
        player?.stop()
        player = nil
        currentCompletion = nil
        queue.removeAll()
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            player?.pause()

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
                player?.play() // AVAudioPlayer resumes from currentTime, not from the start
            }

        @unknown default:
            break
        }
    }
}

extension RecordedAudioPromptPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Ignore a callback from a player we have already moved past — e.g.
        // one stopped by `stop()` — so it cannot fire the wrong completion or
        // start the queue running again after it was cleared.
        guard player === self.player else { return }

        let completion = currentCompletion
        currentCompletion = nil
        completion?()
        startNextPrompt()
    }
}
