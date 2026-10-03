import CoreMotion
import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class PhysicalWalkSensorTests: XCTestCase {
    func testCalibrationErrorInvalidatesHeadingUntilFreshRecovery() async {
        let motion = StubWalkMotion()
        var now = 100.0
        let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { now })
        let walk = PhysicalWalkController(sensor: SensorTestPedometer(), heading: driver)
        walk.start(latitude: 0, longitude: 0)
        await deliver(.init(heading: 90, timestamp: now), to: motion, driver: driver)
        let error = NSError(domain: CMErrorDomain, code: Int(CMErrorDeviceRequiresMovement.rawValue))
        await deliver(.init(heading: 90, timestamp: now), error: error, to: motion, driver: driver)
        XCTAssertNil(driver.latestMapHeadingDegrees)
        XCTAssertNil(walk.activeHeadingDegrees)
        XCTAssertEqual(walk.status, .waitingForHeading)
        XCTAssertTrue(PhysicalWalkStatusCopy.detail(
            isEnabled: true, spoofActive: true, status: .waitingForHeading, movedMeters: 0, failureMessage: ""
        ).contains("缓慢转动手机"))
        now += 0.1
        await deliver(.init(heading: 180, timestamp: now), to: motion, driver: driver)
        XCTAssertEqual(driver.latestMapHeadingDegrees, 180)
        await walk.stop()?.value
        walk.stopHeading()
    }

    func testSampleExpiryNotifiesWithoutAnotherSensorCallback() async {
        let motion = StubWalkMotion()
        var now = 100.0
        let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { now })
        driver.start()
        await deliver(.init(heading: 90, timestamp: 99.1), to: motion, driver: driver)
        let expired = expectation(description: "到期任务主动移除过期显示")
        driver.onChange = { expired.fulfill() }
        now = 100.2
        await fulfillment(of: [expired], timeout: 1)
        XCTAssertNil(driver.latestMapHeadingDegrees)
        driver.stop()
    }

    func testAdapterValidityAndExpiryReachControllerAndDisplacement() async {
        let motion = StubWalkMotion()
        var now = 100.0
        let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { now })
        let walk = PhysicalWalkController(sensor: SensorTestPedometer(), heading: driver)
        var writes: [CoordinatePair] = []
        walk.ignoresWriteGate = true
        walk.applyCoordinate = { writes.append($0); return true }
        walk.start(latitude: 0, longitude: 0)
        await walk.ingest(sample: .init(steps: 0))
        await deliver(.init(heading: 90, yaw: 0, timestamp: now, accuracy: .low), to: motion, driver: driver)
        await walk.ingest(sample: .init(steps: 1))
        XCTAssertNil(walk.activeHeadingDegrees)
        XCTAssertTrue(writes.isEmpty)
        now += 0.1
        await deliver(.init(heading: 90, yaw: 0, timestamp: now), to: motion, driver: driver)
        XCTAssertEqual(walk.activeHeadingDegrees, 90)
        await walk.ingest(sample: .init(steps: 2))
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.last?.wgs84.latitude ?? -1, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(writes.last?.wgs84.longitude ?? 0, 0)
        now += 2
        driver.expireHeadingIfNeeded()
        XCTAssertNil(walk.activeHeadingDegrees)
        XCTAssertEqual(walk.status, .waitingForHeading)
        await walk.ingest(sample: .init(steps: 3))
        XCTAssertEqual(writes.count, 1)
        now += 0.1
        await deliver(.init(heading: 90, yaw: 0, timestamp: now), to: motion, driver: driver)
        walk.setCustomHeadingEnabled(true)
        walk.lockHeading(degrees: 180)
        now += 0.1
        await deliver(.init(heading: 180, yaw: -.pi / 2, timestamp: now), to: motion, driver: driver)
        XCTAssertEqual(walk.activeHeadingDegrees, 270)
        now += 2
        driver.expireHeadingIfNeeded()
        XCTAssertNil(walk.activeHeadingDegrees, "不能在姿态过期时跳回自定义初始角")
        await walk.stop()?.value
        walk.stopHeading()
    }

    func testReferenceFrameAndCalibrationGateAbsoluteHeading() async {
        for frame: CMAttitudeReferenceFrame in [.xTrueNorthZVertical, .xMagneticNorthZVertical, .xArbitraryZVertical] {
            let motion = StubWalkMotion()
            let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { frame }, uptime: { 100 })
            driver.start()
            XCTAssertEqual(motion.frame, frame)
            await deliver(.init(heading: 270, yaw: -.pi / 2, timestamp: 100), to: motion, driver: driver)
            XCTAssertEqual(driver.latestYawDegrees, 90)
            XCTAssertEqual(driver.latestMapHeadingDegrees, frame == .xTrueNorthZVertical ? 270 : nil)
            driver.stop()
        }
        for accuracy: CMMagneticFieldCalibrationAccuracy in [.uncalibrated, .low, .medium, .high] {
            let motion = StubWalkMotion()
            let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { 100 })
            driver.start()
            await deliver(.init(heading: 90, timestamp: 100, accuracy: accuracy), to: motion, driver: driver)
            XCTAssertEqual(driver.latestMapHeadingDegrees, accuracy == .medium || accuracy == .high ? 90 : nil)
            driver.stop()
        }
    }

    func testInvalidAnglesNeverBecomeGeographicNorth() async {
        for degrees in [-1, Double.nan, Double.infinity, 360] {
            let motion = StubWalkMotion()
            let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { 100 })
            driver.start()
            await deliver(.init(heading: degrees, timestamp: 100), to: motion, driver: driver)
            XCTAssertNil(driver.latestMapHeadingDegrees)
            driver.stop()
        }
        XCTAssertNil(PhysicalWalkHeadingDriver.yawDegrees(from: StubWalkAttitude(yaw: .nan)))
        XCTAssertFalse(PhysicalWalkHeading(degrees: .nan, accuracyDegrees: 0).isReliable)
        XCTAssertFalse(PhysicalWalkHeading(degrees: 90, accuracyDegrees: .infinity).isReliable)
    }

    func testOutOfOrderFutureAndExpiredReadingsCannotReplaceFreshHeading() async {
        let motion = StubWalkMotion()
        var now = 100.0
        let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { now })
        driver.start()
        await deliver(.init(heading: 90, timestamp: 100), to: motion, driver: driver)
        // 被拒绝的数据不会发 onChange，使用队列屏障等待适配器消费回调。
        await deliverRejected(.init(heading: 180, timestamp: 99), to: motion)
        await deliverRejected(.init(heading: 180, timestamp: 200), to: motion)
        XCTAssertEqual(driver.latestMapHeadingDegrees, 90)
        now = 100.5
        await deliver(.init(heading: 45, timestamp: now), to: motion, driver: driver)
        now = 102
        XCTAssertNil(driver.latestMapHeadingDegrees)
        let expired = expectation(description: "过期通知清除显示")
        driver.onChange = { expired.fulfill() }
        driver.expireHeadingIfNeeded()
        await fulfillment(of: [expired], timeout: 1)
        driver.stop()
    }

    func testCallbackFromStoppedDriverGenerationIsIgnored() async {
        let motion = StubWalkMotion()
        let driver = PhysicalWalkHeadingDriver(motion: motion, availableFrames: { .xTrueNorthZVertical }, uptime: { 100 })
        driver.start()
        let old = motion.handler
        driver.stop()
        driver.start()
        await deliver(.init(heading: 90, timestamp: 100), to: motion, driver: driver)
        old?(StubWalkMotionData(heading: 180, timestamp: 100.1), nil)
        await drainCallbacks()
        XCTAssertEqual(driver.latestMapHeadingDegrees, 90)
        driver.stop()
        XCTAssertNil(driver.latestMapHeadingDegrees)
    }

    private func deliver(_ data: StubWalkMotionData, error: Error? = nil, to motion: StubWalkMotion, driver: PhysicalWalkHeadingDriver) async {
        let received = expectation(description: "适配器消费样本")
        let onChange = driver.onChange
        driver.onChange = { onChange?(); received.fulfill() }
        motion.handler?(data, error)
        await fulfillment(of: [received], timeout: 1)
        driver.onChange = onChange
    }

    private func deliverRejected(_ data: StubWalkMotionData, to motion: StubWalkMotion) async {
        motion.handler?(data, nil)
        await drainCallbacks()
    }

    private func drainCallbacks() async {
        let drained = expectation(description: "主线程回调屏障")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }
}

@MainActor
private final class SensorTestPedometer: PhysicalWalkSensing {
    var isStepCountingAvailable = true
    func authorizationStatus() -> PhysicalWalkAuthorization { .allowed }
    func requestAuthorization(_ completion: @escaping (PhysicalWalkAuthorization) -> Void) { completion(.allowed) }
    func start(from date: Date, handler: @escaping (PhysicalWalkSample?, Error?) -> Void) {}
    func stop() {}
}

private final class StubWalkMotion: CMMotionManager {
    var handler: CMDeviceMotionHandler?
    var frame: CMAttitudeReferenceFrame?
    override var isDeviceMotionAvailable: Bool { true }
    override func startDeviceMotionUpdates(using referenceFrame: CMAttitudeReferenceFrame, to queue: OperationQueue,
                                          withHandler handler: @escaping CMDeviceMotionHandler) {
        frame = referenceFrame
        self.handler = handler
    }
    override func stopDeviceMotionUpdates() {}
}

private final class StubWalkMotionData: CMDeviceMotion {
    private let degrees: Double
    private let time: TimeInterval
    private let calibration: CMMagneticFieldCalibrationAccuracy
    private let pose: CMAttitude
    init(heading: Double, yaw: Double = 0, timestamp: TimeInterval,
         accuracy: CMMagneticFieldCalibrationAccuracy = .high) {
        degrees = heading
        time = timestamp
        calibration = accuracy
        pose = StubWalkAttitude(yaw: yaw)
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("不使用归档") }
    override var heading: Double { degrees }
    override var timestamp: TimeInterval { time }
    override var attitude: CMAttitude { pose }
    override var magneticField: CMCalibratedMagneticField {
        .init(field: .init(x: 0, y: 0, z: 0), accuracy: calibration)
    }
}

private final class StubWalkAttitude: CMAttitude {
    private let radians: Double
    init(yaw: Double) { radians = yaw; super.init() }
    required init?(coder: NSCoder) { fatalError("不使用归档") }
    override var yaw: Double { radians }
}
