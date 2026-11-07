import AVFoundation

/// 예약이 있을 때 앱이 백그라운드에서 멈추지 않도록 무음 오디오를 재생한다.
/// 다른 앱 소리와 섞여 재생되며(mixWithOthers) 음악을 끊지 않는다.
/// 앱을 완전히 종료(위로 스와이프)하면 동작하지 않는다 → 그 경우 알림으로 대체.
final class KeepAlive: NSObject {
    static let shared = KeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false
    private var wanted = false
    private(set) var isRunning = false

    func start() {
        wanted = true
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !configured {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                                       name: AVAudioSession.interruptionNotification, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged),
                                                       name: .AVAudioEngineConfigurationChange, object: engine)
                configured = true
            }
            let format = player.outputFormat(forBus: 0)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
            buffer.frameLength = buffer.frameCapacity
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    channels[channel].initialize(repeating: 0, count: Int(buffer.frameLength))
                }
            }
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        wanted = false
        guard isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    private func restart() {
        guard wanted else { return }
        player.stop()
        engine.stop()
        isRunning = false
        start()
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            isRunning = false
        } else {
            DispatchQueue.main.async { self.restart() }
        }
    }

    @objc private func configurationChanged() {
        DispatchQueue.main.async { self.restart() }
    }
}
