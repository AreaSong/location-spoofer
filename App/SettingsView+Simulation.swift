import SwiftUI

extension SettingsView {
    var physicalWalkBinding: Binding<Bool> {
        Binding(
            get: { physicalWalk.isEnabled },
            set: { physicalWalk.setEnabled($0) }
        )
    }

    var motionSimulationBinding: Binding<Bool> {
        Binding(
            get: { motionSimulation.isEnabled },
            set: { enabled in
                do {
                    try proxy.applyMotionSimulation(enabled)
                } catch {
                    proxyOperationAlertTitle = "运动状态更新失败"
                    proxyOperationError = error.localizedDescription
                }
            }
        )
    }

    var smoothCruiseBinding: Binding<Bool> {
        Binding(
            get: { smoothCruise.isEnabled },
            set: { smoothCruise.setEnabled($0) }
        )
    }

    var simulationControlsDisabled: Bool {
        modeOperationRunning || actions.state.isBusy || thirdPartyProxy.isRequesting
    }

    @ViewBuilder
    var locationSimulationSection: some View {
        Section("定位模拟") {
            Toggle("平滑巡航切换（防风控）", isOn: smoothCruiseBinding)
                .disabled(simulationControlsDisabled)
            Text("开启后，在已定点状态下切换至新地点时，将在 1.5 秒内平滑过渡推进，防止瞬间位移触发第三方应用风控。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("真实走动", isOn: physicalWalkBinding)
                .disabled(simulationControlsDisabled)
            Text("默认扇形跟系统地图朝向一致。打开「初始指向」后，滑条和 ±15° 才设定自定义初始朝向；之后转动手机会带动扇形。打开真实走动后沿当前扇形迈步。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !physicalWalk.lastFailureMessage.isEmpty {
                Text(physicalWalk.lastFailureMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if runtimeMode.mode == .developerTunnel {
                randomPerturbationControls
                Text("开启后，定点推送前会偏移坐标。路线仍用走路面板的偏移。精度无法写入系统定位模拟。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if runtimeMode.mode == .localWiFi {
                    Toggle("运动状态模拟", isOn: motionSimulationBinding)
                        .disabled(simulationControlsDisabled)
                    Text("实验性功能，默认关闭。开启后会同时模拟定位响应中的运动状态。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                randomPerturbationControls
                Text(randomRadiusHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("定位精度 \(locationAccuracy.meters) 米")
                    Slider(
                        value: accuracyMetersBinding,
                        in: Double(LocationAccuracyStore.minimumMeters)...Double(LocationAccuracyStore.maximumMeters),
                        step: 5
                    )
                    .disabled(simulationControlsDisabled)
                }
                Text("写入定位响应的精度字段。数值越小，系统越倾向认为位置可靠。下次同步或开启时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var randomRadiusHint: String {
        runtimeMode.mode == .thirdParty
            ? "开启后，下次同步坐标时会给目标点添加随机偏移，避免位置固定在同一点。"
            : "开启后，下次开启虚拟定位时会给目标点添加随机偏移，避免位置固定在同一点。"
    }

    @ViewBuilder
    var randomPerturbationControls: some View {
        Toggle("随机扰动", isOn: randomRadiusBinding)
            .disabled(simulationControlsDisabled)
        if randomRadius.isEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("扰动半径 \(Int(randomRadius.radius.rounded())) 米")
                Slider(
                    value: randomRadiusMetersBinding,
                    in: RandomRadiusStore.minimumMeters...RandomRadiusStore.maximumMeters,
                    step: 10
                )
                .disabled(simulationControlsDisabled)
            }
        }
    }

    var randomRadiusBinding: Binding<Bool> {
        Binding(
            get: { randomRadius.isEnabled },
            set: { randomRadius.setEnabled($0) }
        )
    }

    var randomRadiusMetersBinding: Binding<Double> {
        Binding(
            get: { randomRadius.radius },
            set: { randomRadius.setRadius($0) }
        )
    }

    var accuracyMetersBinding: Binding<Double> {
        Binding(
            get: { Double(locationAccuracy.meters) },
            set: { locationAccuracy.setMeters(Int($0.rounded())) }
        )
    }

}
