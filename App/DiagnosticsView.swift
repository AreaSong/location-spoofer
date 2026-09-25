import SwiftUI
import UIKit

/// 日志级别筛选，和文本过滤叠加。
enum RuntimeLogLevelFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case warning = "警告"
    case error = "错误"

    var id: String { rawValue }

    func includes(_ level: RuntimeLogEntry.Level) -> Bool {
        switch self {
        case .all: return true
        case .warning: return level == .warning || level == .error
        case .error: return level == .error
        }
    }
}

struct RuntimeLogsView: View {
    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var actions: LocationActionCoordinator
    let testFavorite: FavoriteLocation
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @State private var entries: [RuntimeLogEntry] = []
    @State private var isTesting = false
    @State private var testResult = ""
    @State private var testMessage = ""
    @State private var showClearConfirm = false
    @State private var copyLogsConfirmed = false
    @State private var logFilter = ""
    @State private var levelFilter = RuntimeLogLevelFilter.all

    private var filteredEntries: [RuntimeLogEntry] {
        let q = logFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard levelFilter.includes(entry.level) else { return false }
            return q.isEmpty || entry.message.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            testPanel
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("过滤日志", text: $logFilter)
                    .textFieldStyle(.plain).font(.caption)
                if !logFilter.isEmpty {
                    Button { logFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }
                }
                levelFilterChips
            }.padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text(entries.isEmpty ? "暂无运行日志" : "无匹配日志").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredEntries.reversed()) { entry in logRow(entry) }
                    }.padding(12)
                }
            }
        }
        .navigationTitle("运行日志").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("日志自动清理，仅保留近 3 天")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = entries.map(\.renderedText).joined(separator: "\n")
                    copyLogsConfirmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyLogsConfirmed = false }
                } label: {
                    Image(systemName: copyLogsConfirmed ? "checkmark" : "doc.on.doc")
                }
                .disabled(entries.isEmpty)
                .accessibilityLabel("复制全部日志")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(entries.isEmpty)
                .accessibilityLabel("清空全部日志")
            }
        }
        .confirmationDialog("清空所有运行日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                RuntimeLogStore.clearAll()
                entries = []
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            while !Task.isCancelled { refresh(); try? await Task.sleep(nanoseconds: 750_000_000) }
        }
    }

    private var levelFilterChips: some View {
        HStack(spacing: 4) {
            ForEach(RuntimeLogLevelFilter.allCases) { filter in
                Button(filter.rawValue) {
                    levelFilter = filter
                }
                .buttonStyle(CapsuleChipStyle(tint: levelFilter == filter ? Color.accentColor : nil))
                .accessibilityAddTraits(levelFilter == filter ? .isSelected : [])
            }
        }
    }

    private var testDescription: String {
        switch runtimeMode.mode {
        case .thirdParty:
            return "检查第三方模块能否拦截并响应 query 请求；不会写入测试坐标。"
        case .developerTunnel:
            return "检查 LocalDevVPN、本机隧道和配对文件是否就绪。"
        case .localWiFi:
            return "依次检查：本地代理 → CA 证书信任 → Wi-Fi 代理链路。"
        }
    }

    private var testPassed: Bool {
        testResult.contains("通过") || testResult.contains("已就绪")
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isTesting = true; testResult = ""
                Task {
                    switch runtimeMode.mode {
                    case .thirdParty:
                        await runThirdPartyConnectionTest()
                    case .developerTunnel:
                        await runDeveloperTunnelCheck()
                    case .localWiFi:
                        let result = await setup.runVerificationTest()
                        testResult = result.isSuccess ? "环境检测通过" : "环境检测失败: \(result.id)"
                        if !result.isSuccess { testResult += "，查看下方日志" }
                        testMessage = setup.testLog
                    }
                    isTesting = false; refresh()
                }
            } label: {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                    }
                    Text(isTesting ? "正在检测…" : "环境检测").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).opacity(0.5)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
            }
            .buttonStyle(PrimaryActionStyle(tint: isTesting ? .gray : .blue))
            .disabled(isTesting || actions.state.isBusy)
            Text(testDescription)
                .font(.caption).foregroundStyle(.secondary)
            if !testMessage.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("测试日志").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        CopyButton("复制", value: { testMessage })
                            .buttonStyle(CapsuleChipStyle())
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { testMessage = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭测试日志")
                    }
                    ScrollView {
                        Text(testMessage)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: AppRadius.image))
                    }.frame(maxHeight: 180)
                }
            }
            if runtimeMode.mode == .localWiFi {
                HStack(spacing: 14) {
                    Label(proxy.isRunning ? "代理运行中" : "代理未运行", systemImage: proxy.isRunning ? "play.circle" : "stop.circle")
                    Label(setup.canModify ? "可修改" : "不可修改", systemImage: setup.canModify ? "checkmark.shield.fill" : "xmark.shield")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !testResult.isEmpty {
                Text(testResult).font(.footnote.weight(.medium))
                    .foregroundStyle(testPassed ? .green : .red)
            }
        }.padding(14).background(Color(.secondarySystemBackground))
    }

    private func logRow(_ entry: RuntimeLogEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry.level == .error ? "xmark.octagon.fill" : entry.level == .warning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .blue).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(entry.source) \(entry.category)").font(.caption.weight(.semibold))
                    Spacer()
                    CopyButton("复制", value: { entry.renderedText })
                        .buttonStyle(CapsuleChipStyle())
                }
                Text(entry.message).font(.caption.monospaced()).textSelection(.enabled)
                if !entry.details.isEmpty {
                    Text(entry.details.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: AppRadius.inset))
    }

    private func refresh() { entries = RuntimeLogStore.loadAll() }

    /// 开发者隧道只看三项环境是否就绪，不做真实推送。
    @MainActor
    private func runDeveloperTunnelCheck() async {
        let store = RouteLocationSetupStore.shared
        store.refresh()
        let status = store.status
        let readiness = status.readiness
        testResult = readiness == .ready ? "隧道已就绪" : (readiness.blockingMessage ?? "隧道未就绪")
        testMessage = """
        ======== 开发者隧道环境检测 ========
        LocalDevVPN: \(status.vpnInstalled ? "已安装" : "未安装")
        本机隧道: \(status.tunnelConnected ? "已连接" : "未连接")
        配对文件: \(status.hasPairing ? "已导入" : "未导入")
        结果: \(readiness == .ready ? "就绪，可以开始虚拟定位" : (readiness.blockingMessage ?? "未就绪"))
        \(store.activity.diagnosticText)
        """
        RuntimeLogger.info("APP", "诊断", "开发者隧道环境检测", details: [
            "LocalDevVPN": String(status.vpnInstalled),
            "隧道": String(status.tunnelConnected),
            "配对文件": String(status.hasPairing)
        ])
    }

    @MainActor
    private func runThirdPartyConnectionTest() async {
        do {
            let response = try await thirdPartyProxy.query()
            let active = response.success && response.latitude != nil && response.longitude != nil
            testResult = active ? "第三方模块连接通过，已有坐标" : "第三方模块连接通过，暂无坐标"
            testMessage = """
            ======== 第三方代理连接检测 ========
            模式: 测试模式
            请求: wloc-settings/save?action=query
            拦截响应: 有效 JSON
            已保存坐标: \(active ? "是" : "否")
            模块版本: \(response.reportedVersion)
            回读坐标: \(response.readbackCoordinateText)
            设定半径: \(response.configuredRadiusText)
            实际偏移: \(response.appliedOffsetText)
            """
        } catch {
            let diagnosis = ThirdPartyProxyError.diagnosis(for: error)
            testResult = diagnosis.title
            testMessage = """
            ======== 第三方代理连接检测 ========
            模式: 测试模式
            请求: wloc-settings/save?action=query
            原因: \(diagnosis.title)
            处理建议: \(ThirdPartyProxyError.recoverySuggestion(for: error))
            """
        }
    }
}
