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
    private let motion = CMMotionManager()
    private(set) var latestYawDegrees: Double?
    private(set) var latestMapHeadingDegrees: Double?
    var onChange: (() -> Void)?
    private var isRunning = false

    var headingAvailable: Bool {
        motion.isDeviceMotionAvailable
    }

    func start() {
        guard !isRunning else { return }
        guard motion.isDeviceMotionAvailable else { return }
        isRunning = true
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(using: Self.attitudeReferenceFrame(), to: .main) { [weak self] data, _ in
            Task { @MainActor in
                self?.latestYawDegrees = Self.yawDegrees(from: data?.attitude)
                self?.latestMapHeadingDegrees = Self.mapHeadingDegrees(from: data)
                self?.onChange?()
            }
        }
    }

    func stop() {
        isRunning = false
        motion.stopDeviceMotionUpdates()
        latestYawDegrees = nil
        latestMapHeadingDegrees = nil
    }

    static func yawDegrees(from attitude: CMAttitude?) -> Double? {
        guard let attitude else { return nil }
        return PhysicalWalkHeadingLock.normalized(-attitude.yaw * 180 / .pi)
    }

    static func mapHeadingDegrees(from data: CMDeviceMotion?) -> Double? {
        guard let heading = data?.heading, heading >= 0 else { return nil }
        return PhysicalWalkHeadingLock.normalized(heading)
    }

    /// 有磁力计时对齐系统地图北向；没有则退回任意参考系，自定义朝向仍用相对 yaw。
    static func attitudeReferenceFrame() -> CMAttitudeReferenceFrame {
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        if frames.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        if frames.contains(.xTrueNorthZVertical) {
            return .xTrueNorthZVertical
        }
        return .xArbitraryZVertical
    }
}
