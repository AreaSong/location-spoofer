import AVFoundation
import Combine
import UIKit

final class BackgroundKeepAlive: ObservableObject {
    static let shared = BackgroundKeepAlive()
    @Published private(set) var isEnabled = false
    @Published private(set) var isHealthy = false
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var shouldRun = false
    private var isRecovering = false
    private var interruptionActive = false
    private var watchdog: DispatchSourceTimer?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func start() {
        shouldRun = true
        if isPlaybackHealthy {
            publishStatus()
            return
        }
        recover(reason: "启动")
    }

    func stop() {
        shouldRun = false
        stopWatchdog()
        teardownEngine()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        publishStatus()
        RuntimeLogger.info("APP", "KeepAlive", "后台保活已停止")
    }

    @objc private func handleDidBecomeActive() {
        guard shouldRun else { return }
        recover(reason: "回到前台")
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard shouldRun else { return }
        recover(reason: "音频路由变化")
    }

    @objc private func handleEngineConfigurationChange() {
        guard shouldRun else { return }
        recover(reason: "音频引擎配置变化")
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard shouldRun, let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interruptionActive = true
            RuntimeLogger.warning("APP", "KeepAlive", "音频被中断")
            publishStatus()
        case .ended:
            interruptionActive = false
            recover(reason: "音频中断恢复")
        @unknown default:
            break
        }
    }

    private var isPlaybackHealthy: Bool {
        engine?.isRunning == true && playerNode?.isPlaying == true
    }

    private func recover(reason: String) {
        guard shouldRun, !isRecovering else { return }
        if isPlaybackHealthy {
            publishStatus()
            return
        }
        isRecovering = true
        defer { isRecovering = false }
        teardownEngine()
        do {
            try activateSession()
            try startPlayback()
        } catch {
            RuntimeLogger.error("APP", "KeepAlive", "保活恢复失败", error: error)
            teardownEngine()
            publishStatus()
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        startWatchdog()
        interruptionActive = false
        publishStatus()
        RuntimeLogger.info("APP", "KeepAlive", "后台保活已启动（近不可闻音频）", details: [
            "原因": reason
        ])
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try session.setActive(true)
    }

    private func startPlayback() throws {
        guard let buf = makeInaudibleLoopBuffer() else {
            throw KeepAliveError.buffer
        }
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        eng.attach(player)
        eng.connect(player, to: eng.mainMixerNode, format: buf.format)
        eng.prepare()
        try eng.start()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
        engine = eng
        playerNode = player
    }

    private func makeInaudibleLoopBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }
        let frames = AVAudioFrameCount(sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let samples = buf.floatChannelData?[0] else { return nil }
        // 全 0 静音会被系统判定为假播放并在约两分钟后挂起本机代理。
        let amplitude: Float = 0.0004
        let step = 2 * Float.pi * 18 / Float(sampleRate)
        for i in 0..<Int(frames) {
            samples[i] = sin(step * Float(i)) * amplitude
        }
        return buf
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.shouldRun, !self.isPlaybackHealthy else { return }
            self.publishStatus()
            self.recover(reason: "看门狗")
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func teardownEngine() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
    }

    private func publishStatus() {
        let enabled = shouldRun
        let healthy = shouldRun && isPlaybackHealthy && !interruptionActive
        let apply = { [weak self] in
            guard let self else { return }
            self.isEnabled = enabled
            self.isHealthy = healthy
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}

private enum KeepAliveError: LocalizedError {
    case buffer
    var errorDescription: String? { "无法创建近不可闻音频缓冲区" }
}
