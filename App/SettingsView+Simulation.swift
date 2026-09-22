import SwiftUI

extension SettingsView {
    var motionSimulationBinding: Binding<Bool> {
        Binding(
            get: { motionSimulation.isEnabled },
            set: { enabled in
                proxy.applyMotionSimulation(enabled)
            }
        )
    }

    var simulationControlsDisabled: Bool {
        modeOperationRunning || actions.state.isBusy || thirdPartyProxy.isRequesting
    }

    @ViewBuilder
    var locationSimulationSection: some View {
        Section("定位模拟") {
            if runtimeMode.mode == .localWiFi {
                Toggle("运动状态模拟", isOn: motionSimulationBinding)
                    .disabled(simulationControlsDisabled)
                Text("实验性功能，默认关闭。开启后会同时模拟定位响应中的运动状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

    var randomRadiusHint: String {
        runtimeMode.mode == .thirdParty
            ? "开启后，下次同步坐标时会给目标点添加随机偏移，避免位置固定在同一点。"
            : "开启后，下次开启虚拟定位时会给目标点添加随机偏移，避免位置固定在同一点。"
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
