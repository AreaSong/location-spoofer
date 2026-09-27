import CoreLocation
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
    var latest: PhysicalWalkHeading? { get }
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
    private let location = CLLocationManager()
    private let locationRelay = LocationHeadingRelay()
    private(set) var latest: PhysicalWalkHeading?
    var onChange: (() -> Void)?

    init() {
        location.headingFilter = 5
        locationRelay.onHeading = { [weak self] heading in
            Task { @MainActor in
                self?.setLatest(heading)
            }
        }
        location.delegate = locationRelay
    }

    var headingAvailable: Bool {
        motion.isDeviceMotionAvailable || CLLocationManager.headingAvailable()
    }

    func start() {
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.2
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
                Task { @MainActor in
                    self?.setLatest(Self.heading(from: data))
                }
            }
            return
        }
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        location.startUpdatingHeading()
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingHeading()
        latest = nil
    }

    private func setLatest(_ heading: PhysicalWalkHeading?) {
        latest = heading
        onChange?()
    }

    private static func heading(from data: CMDeviceMotion?) -> PhysicalWalkHeading? {
        guard let data else { return nil }
        if data.heading >= 0 {
            return PhysicalWalkHeading(degrees: data.heading, accuracyDegrees: 0)
        }
        var degrees = -data.attitude.yaw * 180 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return PhysicalWalkHeading(degrees: degrees, accuracyDegrees: 0)
    }
}

private final class LocationHeadingRelay: NSObject, CLLocationManagerDelegate {
    var onHeading: ((PhysicalWalkHeading) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // 虚拟定位生效时系统罗盘精度常为 -1，磁力计读数仍可用来定向。
        onHeading?(PhysicalWalkHeading(degrees: degrees, accuracyDegrees: 0))
    }
}
