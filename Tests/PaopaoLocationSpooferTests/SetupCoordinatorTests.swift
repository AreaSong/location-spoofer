import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class SetupCoordinatorTests: XCTestCase {
    func testSuccessfulVerificationDismissesSetup() {
        let coordinator = SetupCoordinator()
        coordinator.requestSetup()

        coordinator.applyVerificationResult(.success)

        XCTAssertEqual(coordinator.trustState, .trusted)
        XCTAssertFalse(coordinator.needsSetup)
    }

    func testCertificateFailureRoutesDirectlyToCertificateStep() {
        let coordinator = SetupCoordinator()

        coordinator.applyVerificationResult(.certNotTrusted)

        XCTAssertEqual(coordinator.trustState, .unavailable)
        XCTAssertTrue(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .cert)
    }

    func testProxyFailureRoutesBackToProxyStep() {
        let coordinator = SetupCoordinator()
        coordinator.applyVerificationResult(.certNotTrusted)

        coordinator.applyVerificationResult(.wifiProxyNotConfigured)

        XCTAssertTrue(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .proxy)
    }

    func testExplicitCertificateRequestRoutesToCertificateStep() {
        let coordinator = SetupCoordinator()

        coordinator.requestCertificateSetup()

        XCTAssertTrue(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .cert)
    }

    func testThirdPartyFailureRequestPreservesErrorAndRoutesToImportGuide() {
        let coordinator = SetupCoordinator()

        coordinator.requestThirdPartySetup(message: "模块未连接")

        XCTAssertTrue(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .thirdPartyImport)
        XCTAssertEqual(coordinator.message, "模块未连接")
    }

    func testThirdPartyOnboardingStartsWithClientSelection() {
        let coordinator = SetupCoordinator()

        coordinator.requestThirdPartyOnboarding()

        XCTAssertTrue(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .thirdPartyClient)
        XCTAssertTrue(coordinator.message.isEmpty)
    }

    func testProxyFailurePreservesResultForPresentedGuide() {
        let coordinator = SetupCoordinator()

        coordinator.applyVerificationResult(.proxyNotRunning)

        XCTAssertEqual(coordinator.lastVerificationResult, .proxyNotRunning)
        XCTAssertTrue(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .proxy)
    }

    func testConcurrentVerificationDoesNotOpenGuide() {
        let coordinator = SetupCoordinator()

        coordinator.applyVerificationResult(.verificationInProgress)

        XCTAssertFalse(coordinator.needsSetup)
    }

    func testRuntimeVerificationFailureDoesNotCoverTheMap() {
        let coordinator = SetupCoordinator()
        LocationRuntimeFailureStore.shared.clear()
        defer { LocationRuntimeFailureStore.shared.clear() }

        coordinator.applyVerificationResult(.certNotTrusted, presentSetup: false)

        XCTAssertFalse(coordinator.needsSetup)
        XCTAssertEqual(coordinator.setupStep, .cert)
        XCTAssertEqual(
            LocationRuntimeFailureStore.shared.failure,
            .appModeEnvironment("CA 证书未安装或未信任")
        )
    }
}
