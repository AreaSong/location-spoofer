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
final class CoreLocationHeadingDriver: NSObject, PhysicalWalkHeadingSensing, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private(set) var latest: PhysicalWalkHeading?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.headingFilter = 5
    }

    var headingAvailable: Bool {
        CLLocationManager.headingAvailable()
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
        latest = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        latest = PhysicalWalkHeading(degrees: degrees, accuracyDegrees: newHeading.headingAccuracy)
    }
}
