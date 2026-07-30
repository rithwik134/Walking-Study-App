import AVFoundation

/// FUTURE: once you have recorded audio, add files named to match each key
/// (e.g. "a2_nav.mp3", "a2_context.mp3") to the app bundle, then switch
/// WalkSession to use this instead of SpeechPromptPlayer:
///
///     WalkSession(audioPlayer: RecordedAudioPromptPlayer())
///
/// Nothing else in the app changes — HomeView, ActiveWalkView, and
/// WalkSession's triggering logic all depend only on AudioPromptPlaying.
final class RecordedAudioPromptPlayer: NSObject, AudioPromptPlaying {
    private var player: AVAudioPlayer?
    private var completionHandler: (() -> Void)?

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
        completionHandler = completion
        guard let url = Bundle.main.url(forResource: key, withExtension: "mp3") else {
            print("No recorded audio file named \(key).mp3 in the bundle — falling back to silence.")
            completion?()
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
        } catch {
            print("Playback error for \(key): \(error)")
            completion?()
        }
    }

    func stop() {
        player?.stop()
        completionHandler = nil
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
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }
}
