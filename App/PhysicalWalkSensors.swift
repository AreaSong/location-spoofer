import CoreMotion
import Foundation

@MainActor
protocol PhysicalWalkSensing: AnyObject {
    var isStepCountingAvailable: Bool { get }
    func authorizationStatus() -> PhysicalWalkAuthorization
    func requestAuthorization(_ completion: @escaping (PhysicalWalkAuthorization) -> Void)
    func start(from date: Date, handler: @escaping (PhysicalWalkSample?, Error?) -> Void)
    func stop()
}

@MainActor
protocol PhysicalWalkHeadingSensing: AnyObject {
    var headingAvailable: Bool { get }
    var latestYawDegrees: Double? { get }
    /// 已校准且新鲜的真北航向（度，顺时针）；不能返回磁北或任意参考系 yaw。
    var latestMapHeadingDegrees: Double? { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class CoreMotionPedometerDriver: PhysicalWalkSensing {
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()

    var isStepCountingAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }

    func authorizationStatus() -> PhysicalWalkAuthorization {
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted:
            return .denied
        case .authorized:
            return .allowed
        default:
            return .notDetermined
        }
    }

    func requestAuthorization(_ completion: @escaping (PhysicalWalkAuthorization) -> Void) {
        let current = authorizationStatus()
        guard current == .notDetermined else {
            completion(current)
            return
        }
        guard CMMotionActivityManager.isActivityAvailable() else {
            completion(.notDetermined)
            return
        }
        let now = Date()
        activityManager.queryActivityStarting(from: now.addingTimeInterval(-15), to: now, to: .main) { [weak self] _, _ in
            Task { @MainActor in
                completion(self?.authorizationStatus() ?? .denied)
            }
        }
    }

    func start(from date: Date, handler: @escaping (PhysicalWalkSample?, Error?) -> Void) {
        pedometer.startUpdates(from: date) { data, error in
            let sample = data.map {
                PhysicalWalkSample(
                    distanceMeters: $0.distance?.doubleValue,
                    steps: $0.numberOfSteps.intValue
                )
            }
            Task { @MainActor in
                handler(sample, error)
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
    }
}

@MainActor
final class PhysicalWalkHeadingDriver: PhysicalWalkHeadingSensing {
    private let motion: CMMotionManager
    private let availableFrames: () -> CMAttitudeReferenceFrame
    private let uptime: () -> TimeInterval
    private var latestMotion: CMDeviceMotion?
    private var referenceFrame: CMAttitudeReferenceFrame = .xArbitraryZVertical
    private var generation: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private var expiryTimer: Timer?
    // 正常更新为 10 Hz；停止更新后最多接受 1 秒前的样本。
    static let maximumHeadingAge: TimeInterval = 1

    init(
        motion: CMMotionManager = CMMotionManager(),
        availableFrames: @escaping () -> CMAttitudeReferenceFrame = { CMMotionManager.availableAttitudeReferenceFrames() },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.motion = motion
        self.availableFrames = availableFrames
        self.uptime = uptime
    }

    deinit {
        expiryTimer?.invalidate()
        motion.stopDeviceMotionUpdates()
    }

    var latestYawDegrees: Double? {
        guard let data = freshMotion else { return nil }
        return Self.yawDegrees(from: data.attitude)
    }

    var latestMapHeadingDegrees: Double? {
        guard referenceFrame == .xTrueNorthZVertical, let data = freshMotion,
              data.magneticField.accuracy == .medium || data.magneticField.accuracy == .high else { return nil }
        return Self.mapHeadingDegrees(from: data)
    }

    private var freshMotion: CMDeviceMotion? {
        guard let data = latestMotion else { return nil }
        let age = uptime() - data.timestamp
        return age >= 0 && age <= Self.maximumHeadingAge ? data : nil
    }
    var onChange: (() -> Void)?
    private var isRunning = false

    var headingAvailable: Bool {
        motion.isDeviceMotionAvailable
    }

    func start() {
        guard !isRunning else { return }
        guard motion.isDeviceMotionAvailable else { return }
        isRunning = true
        generation &+= 1
        let generation = generation
        referenceFrame = Self.attitudeReferenceFrame(availableFrames: availableFrames())
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] data, error in
            Task { @MainActor in
                self?.receive(error == nil ? data : nil, generation: generation)
            }
        }
    }

    private func receive(_ data: CMDeviceMotion?, generation: UInt64) {
        guard isRunning, self.generation == generation else { return }
        if let data {
            guard data.timestamp.isFinite, data.timestamp <= uptime(),
                  uptime() - data.timestamp <= Self.maximumHeadingAge,
                  lastTimestamp.map({ data.timestamp > $0 }) ?? true else { return }
            lastTimestamp = data.timestamp
        }
        latestMotion = data
        scheduleHeadingExpiry()
        onChange?()
    }

    private func scheduleHeadingExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let data = latestMotion else { return }
        let delay = max(0.001, data.timestamp + Self.maximumHeadingAge - uptime())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expireHeadingIfNeeded() }
        }
        expiryTimer = timer
        // 地图拖动时也要清除过期显示；按样本到期调度，避免固定轮询多留一秒。
        RunLoop.main.add(timer, forMode: .common)
    }

    func expireHeadingIfNeeded() {
        guard latestMotion != nil else { return }
        guard freshMotion == nil else { scheduleHeadingExpiry(); return }
        latestMotion = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        onChange?()
    }

    func stop() {
        isRunning = false
        generation &+= 1
        expiryTimer?.invalidate()
        expiryTimer = nil
        motion.stopDeviceMotionUpdates()
        latestMotion = nil
        lastTimestamp = nil
    }

    static func yawDegrees(from attitude: CMAttitude?) -> Double? {
        guard let attitude, attitude.yaw.isFinite else { return nil }
        return PhysicalWalkHeadingLock.normalized(-attitude.yaw * 180 / .pi)
    }

    static func mapHeadingDegrees(from data: CMDeviceMotion?) -> Double? {
        guard let heading = data?.heading, heading.isFinite, heading >= 0, heading < 360 else { return nil }
        return PhysicalWalkHeadingLock.normalized(heading)
    }

    /// 地理位移和地图相机均以真北为零点；其余参考系只供自定义朝向取相对 yaw。
    static func attitudeReferenceFrame(
        availableFrames frames: CMAttitudeReferenceFrame = CMMotionManager.availableAttitudeReferenceFrames()
    ) -> CMAttitudeReferenceFrame {
        if frames.contains(.xTrueNorthZVertical) {
            return .xTrueNorthZVertical
        }
        if frames.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        return .xArbitraryZVertical
    }
}
