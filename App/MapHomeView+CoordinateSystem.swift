import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    func startMapRuntimeOnce() {
        guard !mapRuntimeDidStart else { return }
        mapRuntimeDidStart = true
        let pair = LastCoordinateStore.load()?.coordinatePair
            ?? CoordinatePair(
                mapCoordinate: mapState.selection.coordinate,
                mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
            )
        scheduleGeocode(pair: pair, revision: mapState.selection.revision)
    }

    @discardableResult
    func reprojectMapSelection(for change: CoordinateConverter.MapCoordinateSystemChange) -> Bool {
        // Every current selection is persisted as a complete coordinate pair at
        // its input boundary. Replaying the matching stored representation
        // avoids a second GCJ/WGS conversion and its accumulated offset.
        guard let stored = LastCoordinateStore.load() else {
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准切换时未找到当前选点缓存")
            return false
        }
        mapState.reprojectSelectionForMapCoordinateSystemChange(stored.coordinate(for: change.current))
        RuntimeLogger.info("APP", "坐标转换", "地图坐标标准切换后已使用缓存坐标对回显当前选点", details: [
            "from": change.previous.rawValue,
            "to": change.current.rawValue
        ])
        return true
    }

    func applyRuntimeMapCoordinateSystemChange(
        _ change: CoordinateConverter.MapCoordinateSystemChange,
        reason: String
    ) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        search.dismissResults()
        realtimeRequestTask?.cancel()
        realtimeRequestTask = nil
        realtimeRequestContext = nil
        mapState.clearRealtimeLocationForMapCoordinateSystemChange()
        displayedMapCoordinateSystem = change.current
        route.refreshProgressMarker()
        let pinWasReprojected = reprojectMapSelection(for: change)
        if let stored = LastCoordinateStore.load() {
            scheduleGeocode(pair: stored.coordinatePair, revision: mapState.selection.revision)
        }
        RuntimeLogger.warning("APP", "坐标转换", "地图坐标类型已变化", details: [
            "触发原因": reason,
            "旧类型": change.previous.diagnosticName,
            "新类型": change.current.diagnosticName,
            "图钉已按新类型重设": String(pinWasReprojected),
            "蓝点缓存": "已清理",
            "搜索结果": "已清理",
            "异步地理编码": "已重置"
        ])
    }

    @discardableResult
    func refreshRuntimeMapCoordinateSystem(reason: String) async -> Bool {
        let result = await CoordinateConverter.refreshRuntimeMapCoordinateSystem(reason: reason)
        guard !Task.isCancelled else { return false }
        switch result {
        case .changed(let change):
            applyRuntimeMapCoordinateSystemChange(change, reason: reason)
            return true
        case .unchanged:
            return true
        case .unavailable, .cancelled:
            return false
        }
    }

    func scheduleBluePointMapCoordinateSystemRefresh() {
        // 已有任务时先记 pending，再由任务结束后的重排按最新确认位置判断；
        // 若在这里先比距离，探测途中跳回原位的样本会被当成"没动"丢掉。
        guard mapCoordinateSystemRefreshTask == nil else {
            if !bluePointRefreshPending { bluePointRefreshPending = true }
            return
        }
        guard let sample = mapState.realtimeCoordinate,
              bluePointProbeGate.needsProbe(latitude: sample.latitude, longitude: sample.longitude) else { return }
        mapCoordinateSystemRefreshID &+= 1
        let refreshID = mapCoordinateSystemRefreshID
        let delay = bluePointProbeGate.delayBeforeProbe(now: Date())
        mapCoordinateSystemRefreshTask = Task { @MainActor in
            defer {
                if refreshID == mapCoordinateSystemRefreshID {
                    let needsAnotherRefresh = bluePointRefreshPending && !Task.isCancelled
                    mapCoordinateSystemRefreshTask = nil
                    bluePointRefreshPending = false
                    if needsAnotherRefresh {
                        scheduleBluePointMapCoordinateSystemRefresh()
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, refreshID == mapCoordinateSystemRefreshID else { return }
            bluePointRefreshPending = false
            // 冷却期内蓝点可能又动了：按探测时的最新样本判断并记录。
            guard let probed = mapState.realtimeCoordinate,
                  bluePointProbeGate.needsProbe(latitude: probed.latitude, longitude: probed.longitude) else { return }
            await runMapCoordinateSystemProbe(reason: "MapKit蓝点新样本", sample: probed)
        }
    }

    func awaitCoordinatedMapCoordinateSystemRefresh(reason: String) async {
        if let pendingRefresh = mapCoordinateSystemRefreshTask {
            if mapCoordinateSystemProbeRunning {
                await pendingRefresh.value
                return
            }
            // 蓝点任务还在冷却里睡：按钮不陪它等，取消后立即自己探测，结束再按门控补排。
            pendingRefresh.cancel()
            bluePointRefreshPending = true
        }
        mapCoordinateSystemRefreshID &+= 1
        let refreshID = mapCoordinateSystemRefreshID
        // 任务体开始前就标记进行中，并发的第二次调用会等它，而不是把它当成睡眠中的蓝点任务取消。
        mapCoordinateSystemProbeRunning = true
        let task = Task { @MainActor in
            await runMapCoordinateSystemProbe(reason: reason, sample: mapState.realtimeCoordinate)
        }
        mapCoordinateSystemRefreshTask = task
        await task.value
        guard refreshID == mapCoordinateSystemRefreshID else { return }
        mapCoordinateSystemRefreshTask = nil
        if bluePointRefreshPending {
            bluePointRefreshPending = false
            scheduleBluePointMapCoordinateSystemRefresh()
        }
    }

    /// 所有路径共用的单次探测：标记进行中，成功后让蓝点门控记住这次确认的位置。
    private func runMapCoordinateSystemProbe(reason: String, sample: CLLocationCoordinate2D?) async {
        mapCoordinateSystemProbeRunning = true
        defer { mapCoordinateSystemProbeRunning = false }
        bluePointProbeGate.noteAttempt(at: Date())
        guard await refreshRuntimeMapCoordinateSystem(reason: reason), let sample else { return }
        bluePointProbeGate.noteConfirmed(latitude: sample.latitude, longitude: sample.longitude)
    }
}
