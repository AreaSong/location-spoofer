import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    func requestRealtimeLocation() {
        guard realtimeButtonTask == nil else { return }
        realtimeButtonTask = Task { @MainActor in
            defer { realtimeButtonTask = nil }
            await awaitCoordinatedMapCoordinateSystemRefresh(reason: "点击实时定位")
            guard !Task.isCancelled else {
                return
            }
            performRealtimeLocationRequest()
        }
    }

    func performRealtimeLocationRequest() {
        let intent = mapState.beginRealtimeIntent()
        RuntimeLogger.info("APP", "实时定位", "用户点击实时定位", details: [
            "intentID": String(intent.id),
            "选点revision": String(intent.selectionRevision),
            "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "蓝点缓存存在": String(mapState.realtimeLocation != nil),
            "蓝点缓存新鲜": String(mapState.realtimeLocation.map { realtime.isFreshEnoughForRealtimeRequest($0) } ?? false),
            "CLLocationManager请求中": String(realtime.isRequesting)
        ])
        // MKMapView 只在位置变化时刷新蓝点，静止时 timestamp 会变旧。与 CLLocationManager 共用 20 秒上限，避免选中过期点。
        if let loc = mapState.realtimeLocation, realtime.isFreshEnoughForRealtimeRequest(loc) {
            RealtimeLocationTrace.log("实时定位按钮直接使用 MapKit 蓝点缓存", location: loc, details: [
                "intentID": String(intent.id),
                "来源": "MapLocationState.realtimeLocation",
                "缓存上限秒": String(Int(RealtimeLocationManager.cacheMaxAge))
            ])
            acceptRealtimeLocation(
                loc.coordinate,
                intent: intent,
                source: .mapKitBluePoint,
                sourceDescription: "MapKit蓝点缓存"
            )
            return
        }
        if let loc = mapState.realtimeLocation {
            RealtimeLocationTrace.log("跳过过期 MapKit 蓝点缓存，改走 CLLocationManager", location: loc, details: [
                "intentID": String(intent.id),
                "缓存上限秒": String(Int(RealtimeLocationManager.cacheMaxAge))
            ], level: .warning)
        }
        RuntimeLogger.info("APP", "实时定位", "MapKit 蓝点不可用或已过期，启动 CLLocationManager 兜底", details: [
            "intentID": String(intent.id),
            "蓝点缓存存在": String(mapState.realtimeLocation != nil)
        ])
        startRealtimeLocationRequest(
            source: "CLLocationManager",
            showFailureAlert: true,
            intent: intent
        )
    }

    func handleNativeRealtimeLocation(_ location: CLLocation) {
        mapState.updateRealtimeLocation(location)
        logSpoofCoordinateDiagnosisIfNeeded(location)
        scheduleBluePointMapCoordinateSystemRefresh()
        guard let context = realtimeRequestContext else {
            return
        }
        guard realtime.isFreshEnoughForRealtimeRequest(location) else {
            RealtimeLocationTrace.log("待处理请求忽略过期 MapKit 蓝点，继续等待 CLLocationManager", location: location, details: [
                "intentID": String(context.intent.id),
                "缓存上限秒": String(Int(RealtimeLocationManager.cacheMaxAge))
            ], level: .warning)
            return
        }

        RealtimeLocationTrace.log("主页收到待处理请求所需的 MapKit 蓝点回调", location: location, details: [
            "当前选点revision": String(mapState.selection.revision)
        ])

        // MKMapView's MKUserLocation is the visible blue point. When it arrives,
        // fulfill the pending intent from that exact sample and cancel the slower
        // CLLocationManager fallback so the camera and dot cannot disagree.
        realtimeRequestContext = nil
        realtimeRequestTask?.cancel()
        RuntimeLogger.info("APP", "实时定位", "MapKit 蓝点抢先完成请求，取消 CLLocationManager 兜底", details: [
            "intentID": String(context.intent.id),
            "原兜底来源": context.source
        ])
        acceptRealtimeLocation(
            location.coordinate,
            intent: context.intent,
            source: .mapKitBluePoint,
            sourceDescription: "蓝点(途中)→\(context.source)"
        )
    }

    func logSpoofCoordinateDiagnosisIfNeeded(_ location: CLLocation) {
        guard spoofState == .active,
              let latitude = activeSpoofLat,
              let longitude = activeSpoofLon else { return }
        let targetPair = CoordinateConverter.coordinatePair(
            lat: latitude,
            lon: longitude,
            mapCoordinateSystem: .wgs84
        )
        let diagnosis = CoordinateConverter.diagnoseRepresentation(
            sample: location.coordinate,
            pair: targetPair,
            maximumDistance: max(1_000, location.horizontalAccuracy * 4),
            minimumSeparation: max(30, location.horizontalAccuracy)
        )
        let shouldLog = !hasLoggedSpoofDiagnosis
            || diagnosis.inferredSystem != lastSpoofDiagnosisSystem
        guard shouldLog else { return }
        hasLoggedSpoofDiagnosis = true
        lastSpoofDiagnosisSystem = diagnosis.inferredSystem
        RuntimeLogger.info("APP", "坐标转换", "虚拟定位开启后的 MapKit 蓝点标准判定", details: [
            "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "WLOC目标标准": CoordinateConverter.MapCoordinateSystem.wgs84.diagnosticName,
            "蓝点回调更接近": diagnosis.inferredName,
            "蓝点距WGS目标米": String(format: "%.1f", diagnosis.distanceToWGS84),
            "蓝点距GCJ目标米": String(format: "%.1f", diagnosis.distanceToGCJ02),
            "日志策略": "每次开启首次或判定变化"
        ])
    }

    func startRealtimeLocationRequest(
        source: String,
        showFailureAlert: Bool,
        intent suppliedIntent: RealtimeLocationIntent? = nil
    ) {
        let intent = suppliedIntent ?? mapState.beginRealtimeIntent()
        realtimeRequestContext = RealtimeLocationRequestContext(
            intent: intent,
            source: source,
            showFailureAlert: showFailureAlert
        )
        RuntimeLogger.info("APP", "实时定位", "登记实时定位请求上下文", details: [
            "intentID": String(intent.id),
            "选点revision": String(intent.selectionRevision),
            "来源": source,
            "失败时提示": String(showFailureAlert),
            "任务已存在": String(realtimeRequestTask != nil),
            "manager请求中": String(realtime.isRequesting)
        ])

        // A button tap during the startup request retargets that same in-flight
        // Core Location request to the newer intent instead of being ignored.
        guard realtimeRequestTask == nil, !realtime.isRequesting else {
            RuntimeLogger.info("APP", "实时定位", "复用进行中的 CLLocationManager 请求并更新意图上下文", details: [
                "intentID": String(intent.id)
            ])
            return
        }
        realtimeRequestTask = Task { @MainActor in
            defer {
                realtimeRequestTask = nil
                realtimeRequestContext = nil
            }
            guard let coordinate = await realtime.requestLocation() else {
                RuntimeLogger.warning("APP", "实时定位", "CLLocationManager 兜底未返回坐标", details: [
                    "授权状态rawValue": String(realtime.authorizationStatus.rawValue),
                    "任务已取消": String(Task.isCancelled),
                    "上下文存在": String(realtimeRequestContext != nil)
                ])
                guard let context = realtimeRequestContext,
                      context.showFailureAlert,
                      !Task.isCancelled,
                      mapState.selection.revision == context.intent.selectionRevision else { return }
                RuntimeLogger.info("APP", "地图", "定位失败 status=\(realtime.authorizationStatus.rawValue)")
                showLocationAlert = true
                return
            }
            RealtimeLocationTrace.coordinate("主页收到 CLLocationManager 兜底坐标", coordinate: coordinate, details: [
                "任务已取消": String(Task.isCancelled)
            ])
            guard !Task.isCancelled, let context = realtimeRequestContext else {
                RuntimeLogger.info("APP", "实时定位", "丢弃 CLLocationManager 结果：任务已取消或蓝点已抢先完成", details: [
                    "任务已取消": String(Task.isCancelled),
                    "上下文存在": String(realtimeRequestContext != nil)
                ])
                return
            }
            acceptRealtimeLocation(
                coordinate,
                intent: context.intent,
                source: .coreLocation,
                sourceDescription: context.source
            )
        }
    }

    func acceptRealtimeLocation(
        _ coordinate: CLLocationCoordinate2D,
        intent: RealtimeLocationIntent,
        source: RealtimeCoordinateSource,
        sourceDescription: String
    ) {
        let currentViewport = mapState.viewportMeters
        let sourceCoordinateSystem = source.coordinateSystem
        let pair = CoordinateConverter.coordinatePair(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            mapCoordinateSystem: sourceCoordinateSystem
        )
        let accepted = mapState.acceptRealtimeLocation(
            pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            intent: intent
        )
        RuntimeLogger.info("APP", "实时定位", "实时定位坐标完成标准判断并提交到地图", details: [
            "来源": sourceDescription,
            "来源类型": source.diagnosticName,
            "输入坐标标准": sourceCoordinateSystem.diagnosticName,
            "intentID": String(intent.id),
            "intent选点revision": String(intent.selectionRevision),
            "当前选点revision": String(mapState.selection.revision),
            "App已确认地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "accepted": String(accepted),
            "显示坐标字段": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "持久化字段": "WGS-84+GCJ-02"
        ])
        RealtimeLocationTrace.coordinate("原始实时定位坐标", coordinate: coordinate, details: [
            "来源": sourceDescription,
            "输入坐标标准": sourceCoordinateSystem.diagnosticName
        ])
        RealtimeLocationTrace.coordinate("地图实际显示坐标", coordinate: pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem), details: [
            "地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        guard accepted else { return }
        // 用点击时的缩放级别居中，不改变缩放
        mapState.focusSelection(distanceMeters: currentViewport)
        // Persist both forms once from the explicitly typed input boundary.
        LastCoordinateStore.save(coordinatePair: pair, zoomMeters: currentViewport)
        cachedSelectionPair = pair
        favorites.selectMatching(coordinatePair: pair)
        rememberDiscreteSelection(
            name: mapState.displayName ?? "实时定位",
            coordinatePair: pair
        )
        scheduleGeocode(pair: pair, revision: mapState.selection.revision)
    }
}
