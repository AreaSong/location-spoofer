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
        // 任意参考系即可：我们只跟相对转动，模拟器没有磁力计也能用。
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            Task { @MainActor in
                guard let yaw = Self.yawDegrees(from: data?.attitude) else { return }
                self?.latestYawDegrees = yaw
                self?.onChange?()
            }
        }
    }

    func stop() {
        isRunning = false
        motion.stopDeviceMotionUpdates()
        latestYawDegrees = nil
    }

    static func yawDegrees(from attitude: CMAttitude?) -> Double? {
        guard let attitude else { return nil }
        return PhysicalWalkHeadingLock.normalized(-attitude.yaw * 180 / .pi)
    }
}
