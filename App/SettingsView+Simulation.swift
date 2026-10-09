import SwiftUI

/// 定位拟真与防风控设置组件
/// 独立管理拟真参数 Store，阻断参数拖动滑块时向外层设置页的无谓重绘扩散
struct LocationSimulationSection: View {
    let mode: ProxyRuntimeMode
    let controlsDisabled: Bool
    var onError: ((String, String) -> Void)? = nil

    @ObservedObject private var smoothCruise = SmoothCruiseStore.shared
    @ObservedObject private var physicalWalk = PhysicalWalkStore.shared
    @ObservedObject private var motionSimulation = MotionSimulationStore.shared
    @ObservedObject private var randomRadius = RandomRadiusStore.shared
    @ObservedObject private var locationAccuracy = LocationAccuracyStore.shared
    @ObservedObject private var proxy = ProxyManager.shared

    var body: some View {
        Section("定位模拟与防风控") {
            cruiseAndMovementGroup
            noiseAndFeaturesGroup
        }
    }

    // MARK: - 1. 轨迹与行进拟真

    @ViewBuilder
    private var cruiseAndMovementGroup: some View {
        Toggle("平滑巡航切换（防风控）", isOn: smoothCruiseBinding)
            .disabled(controlsDisabled)
        Text("开启后，在已定点状态下切换至新地点时，将在 1.5 秒内平滑过渡推进，防止瞬间位移触发第三方应用风控。")
            .font(.footnote)
            .foregroundStyle(.secondary)

        Toggle("弯道自适应减速与拟真微扰", isOn: corneringDecelerationBinding)
            .disabled(controlsDisabled)
        Text("开启后，路线回放遇到拐弯时模拟向心力平滑降速，并附加拟真行进微扰动，杜绝恒速机器人轨迹检测。")
            .font(.footnote)
            .foregroundStyle(.secondary)

        Toggle("真实走动", isOn: physicalWalkBinding)
            .disabled(controlsDisabled)
        Text("默认扇形跟系统地图朝向一致。打开「初始指向」后，滑条和 ±15° 才设定自定义初始朝向；转动手机带动扇形并迈步。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if !physicalWalk.lastFailureMessage.isEmpty {
            Text(physicalWalk.lastFailureMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: - 2. 坐标加噪与上报特征

    @ViewBuilder
    private var noiseAndFeaturesGroup: some View {
        randomPerturbationControls

        if mode == .developerTunnel {
            Text("开发者隧道模式：定点推送前会添加偏移，路线仍用路线面板偏移。底层注入由系统定位驱动托管，精度参数无需修改。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(randomRadiusHint)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if mode == .localWiFi {
                Toggle("运动状态模拟", isOn: motionSimulationBinding)
                    .disabled(controlsDisabled)
                Text("实验性功能，默认关闭。开启后会同时模拟定位响应中的运动状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("定位精度 \(locationAccuracy.meters) 米")
                Slider(
                    value: accuracyMetersBinding,
                    in: Double(LocationAccuracyStore.minimumMeters)...Double(LocationAccuracyStore.maximumMeters),
                    step: 5
                )
                .disabled(controlsDisabled)
            }
            Text("写入定位响应的精度字段。数值越小，系统越倾向认为位置可靠。下次同步或开启时生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var randomPerturbationControls: some View {
        Toggle("随机扰动", isOn: randomRadiusBinding)
            .disabled(controlsDisabled)
        if randomRadius.isEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("扰动半径 \(Int(randomRadius.radius.rounded())) 米")
                Slider(
                    value: randomRadiusMetersBinding,
                    in: RandomRadiusStore.minimumMeters...RandomRadiusStore.maximumMeters,
                    step: 10
                )
                .disabled(controlsDisabled)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var randomRadiusHint: String {
        mode == .thirdParty
            ? "开启后，下次同步坐标时会给目标点添加随机偏移，避免位置固定在同一点。"
            : "开启后，下次开启虚拟定位时会给目标点添加随机偏移，避免位置固定在同一点。"
    }

    // MARK: - Bindings

    private var physicalWalkBinding: Binding<Bool> {
        Binding(
            get: { physicalWalk.isEnabled },
            set: { physicalWalk.setEnabled($0) }
        )
    }

    private var motionSimulationBinding: Binding<Bool> {
        Binding(
            get: { motionSimulation.isEnabled },
            set: { enabled in
                do {
                    try proxy.applyMotionSimulation(enabled)
                } catch {
                    onError?("运动状态更新失败", error.localizedDescription)
                }
            }
        )
    }

    private var smoothCruiseBinding: Binding<Bool> {
        Binding(
            get: { smoothCruise.isEnabled },
            set: { smoothCruise.setEnabled($0) }
        )
    }

    private var corneringDecelerationBinding: Binding<Bool> {
        Binding(
            get: { smoothCruise.isCorneringDecelerationEnabled },
            set: { smoothCruise.setCorneringDecelerationEnabled($0) }
        )
    }

    private var randomRadiusBinding: Binding<Bool> {
        Binding(
            get: { randomRadius.isEnabled },
            set: { newValue in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    randomRadius.setEnabled(newValue)
                }
            }
        )
    }

    private var randomRadiusMetersBinding: Binding<Double> {
        Binding(
            get: { randomRadius.radius },
            set: { randomRadius.setRadius($0) }
        )
    }

    private var accuracyMetersBinding: Binding<Double> {
        Binding(
            get: { Double(locationAccuracy.meters) },
            set: { locationAccuracy.setMeters(Int($0.rounded())) }
        )
    }
}

// MARK: - SettingsView Extension Wrapper

extension SettingsView {
    var simulationControlsDisabled: Bool {
        modeOperationRunning || actions.state.isBusy || thirdPartyProxy.isRequesting
    }

    @ViewBuilder
    var locationSimulationSection: some View {
        LocationSimulationSection(
            mode: runtimeMode.mode,
            controlsDisabled: simulationControlsDisabled
        ) { title, message in
            setProxyOperationAlert(title: title, message: message)
        }
    }
}
