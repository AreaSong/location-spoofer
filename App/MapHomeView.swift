import SwiftUI
import MapKit
import UIKit
import CoreLocation

enum HomeSheet: String, Identifiable {
    case settings, logs, favorites, savedRoutes
    var id: String { rawValue }
}

enum SpoofState: Equatable {
    case idle, verifying, active
}

struct RealtimeLocationRequestContext {
    let intent: RealtimeLocationIntent
    let source: String
    let showFailureAlert: Bool
}

enum RealtimeCoordinateSource: Equatable {
    case mapKitBluePoint
    case coreLocation

    @MainActor
    var coordinateSystem: CoordinateConverter.MapCoordinateSystem {
        switch self {
        case .mapKitBluePoint: return CoordinateConverter.currentMapCoordinateSystem
        case .coreLocation: return .wgs84
        }
    }

    var diagnosticName: String {
        switch self {
        case .mapKitBluePoint: return "MapKit地图蓝点"
        case .coreLocation: return "CLLocationManager"
        }
    }
}

struct MapHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var setup: SetupCoordinator
    @StateObject var favorites: FavoriteLocationStore
    @StateObject var favoriteImport = FavoriteImportCoordinator()
    @StateObject var routeImport = RouteImportCoordinator()
    @StateObject var savedRoutes = SavedRouteStore()
    @StateObject var recentRoutes = RecentRouteStore()
    @StateObject var actions: LocationActionCoordinator
    @StateObject var route: RoutePlaybackController
    @StateObject var session: SpoofSession
    @ObservedObject var proxy = ProxyManager.shared
    @ObservedObject var keepAlive = BackgroundKeepAlive.shared
    @StateObject var physicalWalk = PhysicalWalkController()
    @ObservedObject var physicalWalkStore = PhysicalWalkStore.shared
    @ObservedObject var mapStyle = MapStyleStore.shared
    @ObservedObject var recentSelections = RecentSelectionStore.shared
    @ObservedObject var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject var thirdPartyProxy = ThirdPartyProxyManager.shared
    // 只在效果处理和社区提示里读取，不参与 body，不必观察。
    let thirdPartyClient = ThirdPartyProxyClientStore.shared
    let remoteConfiguration = AppRemoteConfigurationStore.shared
    @StateObject var realtime = RealtimeLocationManager.shared
    @StateObject var mapState: MapLocationState
    @ObservedObject var net = NetworkMonitor.shared
    @ObservedObject var signingExpiryBanner = SigningExpiryBannerStore.shared
    @ObservedObject var routeLocation = RouteLocationSetupStore.shared
    @ObservedObject var runtimeFailure = LocationRuntimeFailureStore.shared

    @StateObject var search = MapSearchModel.forMap()
    @FocusState var searchFocused: Bool
    @State var mapRuntimeDidStart = false
    @State var activeSheet: HomeSheet?
    @State var showEnableTip = false
    @State var showDisableTip = false
    @State var activeTip: TipKind?
    @State var manualHint = ""
    @State var spotIslandFailed = false
    @State var spotStopPending = false
    @State var spotSwitchPending = false
    @State var spotActionFailed = false
    @State var spotFailureMessage = ""
    @State var spotRetryCommand = ""
    @State var spotStoppedConfirmUntil: Date?
    @State var routeStoppedConfirmUntil: Date?
    @State var routeCommand = RouteCommandTracking.idle
    let tipPreferences = VirtualLocationTipPreferences()
    let communityPromptPreferences = ThirdPartyCommunityPromptPreferences()
    @State var pendingCommunityContributionClient: ThirdPartyProxyClient?
    @State var communityContributionClient: ThirdPartyProxyClient?
    @State var showCommunityTemplateCopied = false
    @State var githubDestination: SafariDestination?
    @State var editingFavorite: FavoriteLocation?
    @State var editName = ""
    @State var showSaveRouteAlert = false
    @State var routeRecovery: RouteSession?
    @State var saveRouteName = ""
    @State var reverseGeocodeTask: Task<Void, Never>?
    @State var geocodeDebounceTask: Task<Void, Never>?
    @State var showLocationAlert = false
    @State var showSigningResignSheet = false
    @State var showRouteLocationSetup = false
    @State var showsRoutePanel = false
    @State var homePopup: HomePopup?
    @State var previewCoordinateSystem = CoordinateConverter.currentMapCoordinateSystem
    @State var coordinateCopied = false
    @State var coordinateCopyGeneration = 0
    @State var coordinateRowFrame: CGRect = .zero
    @State var zoomControlFrame: CGRect = .zero
    @State var showExitRouteConfirm = false
    @State var developerLocationError = ""
    @State var lastDeveloperTunnelRecoveryAt: Date?
    @State var realtimeRequestTask: Task<Void, Never>?
    @State var realtimeRequestContext: RealtimeLocationRequestContext?
    @State var wifiChangeObserverToken: UUID?
    @State var wifiVerificationTask: Task<Void, Never>?
    @State var wifiVerificationID: UUID?
    @State var mapCoordinateSystemRefreshTask: Task<Void, Never>?
    @State var mapCoordinateSystemRefreshID: UInt64 = 0
    @State var bluePointRefreshPending = false
    @State var realtimeButtonTask: Task<Void, Never>?
    @State var favoriteSaveTask: Task<Void, Never>?
    @State var displayedMapCoordinateSystem = CoordinateConverter.currentMapCoordinateSystem
    @State var lastSpoofDiagnosisSystem: CoordinateConverter.MapCoordinateSystem?
    @State var hasLoggedSpoofDiagnosis = false
    @State var cachedSelectionPair: CoordinatePair

    var spoofState: SpoofState { session.state }
    var activeSpoofLat: Double? { session.writtenLatitude }
    var activeSpoofLon: Double? { session.writtenLongitude }

    init(setup: SetupCoordinator) {
        self.setup = setup
        let favoriteStore = FavoriteLocationStore()
        _favorites = StateObject(wrappedValue: favoriteStore)
        let savedCoord = LastCoordinateStore.load()
        let initialZoom = savedCoord?.zoomMeters ?? ViewportStore.loadOrDefault()
        let selectedFavorite = favoriteStore.selectedFavorite
        let initialCoord: CLLocationCoordinate2D
        let initialSource: MapSelectionSource
        let initialName: String?
        if let saved = savedCoord {
            initialCoord = saved.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            if let selectedFavorite,
               selectedFavorite.coordinatePair.matchesWGS84(
                   latitude: saved.coordinatePair.wgs84.latitude,
                   longitude: saved.coordinatePair.wgs84.longitude
               ) {
                initialSource = .favorite(selectedFavorite.id)
                initialName = selectedFavorite.name
            } else {
                initialSource = .initial
                initialName = nil
            }
        } else if let selectedFavorite {
            initialCoord = selectedFavorite.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            initialSource = .favorite(selectedFavorite.id)
            initialName = selectedFavorite.name
        } else {
            // The fallback location is defined as WGS-84 and rendered in the
            // coordinate system resolved by the startup gate.
            initialCoord = CoordinateConverter.coordinatePair(
                lat: 22.544577,
                lon: 113.94114,
                mapCoordinateSystem: .wgs84
            ).coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            initialSource = .initial
            initialName = nil
        }
        let initialPair: CoordinatePair
        if let saved = savedCoord {
            initialPair = saved.coordinatePair
        } else if let selectedFavorite {
            initialPair = selectedFavorite.coordinatePair
        } else {
            initialPair = CoordinateConverter.coordinatePair(
                lat: 22.544577,
                lon: 113.94114,
                mapCoordinateSystem: .wgs84
            )
        }
        _cachedSelectionPair = State(initialValue: initialPair)
        RuntimeLogger.info("APP", "地图", "初始化", details: [
            "zoom": String(initialZoom),
            "有缓存": String(savedCoord != nil),
            "初始来源": String(describing: initialSource),
            "地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        let mapModel = MapLocationState(
            initialCoordinate: initialCoord,
            initialViewportMeters: initialZoom,
            initialSource: initialSource,
            initialName: initialName
        )
        _mapState = StateObject(wrappedValue: mapModel)
        let actionCoordinator = LocationActionCoordinator()
        _actions = StateObject(wrappedValue: actionCoordinator)
        let routeController = RoutePlaybackController()
        _route = StateObject(wrappedValue: routeController)
        _session = StateObject(wrappedValue: MapHomeView.makeSpoofSession(
            setup: setup,
            actions: actionCoordinator,
            route: routeController,
            mapState: mapModel
        ))
    }

    var body: some View {
        ZStack {
            MapViewRepresentable(
                selection: mapState.selection,
                initialViewportMeters: mapState.viewportMeters,
                cameraCommand: mapState.cameraCommand,
                onRealtimeLocationChanged: { location in
                    handleNativeRealtimeLocation(location)
                },
                onUserCenterChanged: { coordinate, distance in
                    mapState.updateViewport(distanceMeters: distance)
                    let previousRevision = mapState.selection.revision
                    let revision = mapState.selectUserMapCenter(coordinate)
                    guard revision != previousRevision else { return }
                    let pair = CoordinatePair(
                        mapCoordinate: coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    LastCoordinateStore.save(
                        coordinatePair: pair,
                        zoomMeters: mapState.viewportMeters
                    )
                    cachedSelectionPair = pair
                    favorites.select(nil)
                    scheduleGeocode(pair: pair, revision: revision)
                },
                onViewportChanged: { distance in
                    mapState.updateViewport(distanceMeters: distance)
                },
                onMapTap: { coordinate in
                    Haptics.selection()
                    favorites.select(nil)
                    let revision = mapState.selectMapTap(coordinate)
                    let pair = CoordinatePair(
                        mapCoordinate: coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    LastCoordinateStore.save(
                        coordinatePair: pair,
                        zoomMeters: mapState.viewportMeters
                    )
                    cachedSelectionPair = pair
                    rememberDiscreteSelection(name: formattedSelectionName(for: pair), coordinatePair: pair)
                    scheduleGeocode(pair: pair, revision: revision)
                },
                onRoutePinTap: { pin in
                    Haptics.selection()
                    handleRoutePinTap(pin)
                },
                onFavoritePinTap: { pin in
                    Haptics.selection()
                    handleFavoritePinTap(pin)
                },
                onUserZoomChanged: { distance in
                    ViewportStore.save(distance)
                    LastCoordinateStore.updateZoom(distance)
                },
                routeCoordinates: route.overlayCoordinates,
                routePins: route.overlayPins,
                favoritePins: FavoriteMapPin.pins(
                    from: favorites.displayedFavorites,
                    selectedID: favorites.selectedFavoriteID,
                    mapSystem: displayedMapCoordinateSystem
                ),
                playbackClock: route.clock,
                walkHeadingDegrees: physicalWalk.activeHeadingDegrees,
                walkPuckCoordinate: walkPuckMapCoordinate,
                showsWalkHeading: walkPuckMapCoordinate != nil,
                mapDisplayStyle: mapStyle.style
            )
            .ignoresSafeArea(.container)

            if homePopup != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { homePopup = nil }
                    .accessibilityLabel("关闭面板")
                    .accessibilityAddTraits(.isButton)
            }
            MapHomeOverlayLayout(
                top: { height in homeTopArea(availableHeight: height) },
                bottom: { height in
                    if !searchFocused {
                        bottomControls(availableHeight: height)
                    }
                }
            )
        }
        .coordinateSpace(name: "homeOverlay")
        .overlay(alignment: .topLeading) {
            homeChromePopoverOverlay
        }
        .onPreferenceChange(HomeCoordinateRowFrameKey.self) { coordinateRowFrame = $0 }
        .onPreferenceChange(HomeZoomControlFrameKey.self) { zoomControlFrame = $0 }
        .ignoresSafeArea(.keyboard)
        .navigationBarHidden(true)
        .onChange(of: showsRoutePanelActive) { _ in homePopup = nil }
        .onChange(of: searchFocused) { focused in if focused { homePopup = nil } }
        .onChange(of: activeSheet) { sheet in if sheet != nil { homePopup = nil } }
        .onChange(of: displayedMapCoordinateSystem) { previewCoordinateSystem = $0 }
        .onChange(of: cachedSelectionPair) { _ in previewCoordinateSystem = displayedMapCoordinateSystem }
        .sheet(item: $activeSheet) { sheet in
            NavigationView {
                switch sheet {
                case .settings: SettingsView(
                    setup: setup, actions: actions, favoriteImport: favoriteImport,
                    isSettingsPresented: { activeSheet == .settings }, favorites: favorites, session: session
                )
                case .logs: RuntimeLogsView(setup: setup, actions: actions, testFavorite: testFavorite)
                case .favorites:
                    FavoriteListView(
                        favorites: favorites,
                        onSelect: { favorite in
                            select(favorite)
                        },
                        onRename: { favorite, name in
                            favorites.rename(favorite.id, to: name)
                            mapState.updateExplicitName(name, forFavoriteID: favorite.id)
                        }
                    )
                case .savedRoutes:
                    SavedRouteListView(
                        store: savedRoutes,
                        recentRoutes: recentRoutes,
                        routeImport: routeImport,
                        isListPresented: { activeSheet == .savedRoutes },
                        onSelect: { saved in
                            let previous = route.phase
                            settleRouteSimulation(after: route.load(saved), from: previous)
                        }
                    )
                }
            }
        }
        .sheet(item: $activeTip) { kind in
            TipSheetView(kind: kind, runtimeMode: runtimeMode.mode)
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
        .alert("社区分享成功配置？", isPresented: Binding(
            get: { communityContributionClient != nil },
            set: { if !$0 { communityContributionClient = nil } }
        )) {
            Button("去提交") {
                guard let client = communityContributionClient else { return }
                UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                    for: client,
                    systemVersion: UIDevice.current.systemVersion
                )
                openCommunityContributionPage()
            }
            Button("复制模板") {
                guard let client = communityContributionClient else { return }
                UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                    for: client,
                    systemVersion: UIDevice.current.systemVersion
                )
                showCommunityTemplateCopied = true
            }
            if communityPromptPreferences.canSuppress() {
                Button("不再提示", role: .cancel) {
                    communityPromptPreferences.suppress()
                }
            } else {
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text(
                "你正在使用 \(communityContributionClient?.name ?? "第三方客户端")。点击“去提交”会先复制投稿模板，并在 App 内打开社区页面。采纳后将收录到 README，可选择是否匿名署名。"
            )
        }
        .alert("已复制投稿模板", isPresented: $showCommunityTemplateCopied) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("如果 GitHub 登录或浏览器跳转后模板没有自动填充，可以直接粘贴。")
        }
        .alert("无法直接跳转", isPresented: Binding(
            get: { !manualHint.isEmpty },
            set: { if !$0 { manualHint = "" } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: { Text(manualHint) }
        .sheet(isPresented: $showSigningResignSheet) {
            SigningResignGuideView()
        }
        .sheet(isPresented: $showRouteLocationSetup) {
            NavigationView {
                List { RouteLocationSettingsSection(session: session) }
                    .navigationTitle("路线定位")
                    .toolbar {
                        Button("关闭") { showRouteLocationSetup = false }
                    }
            }
        }
        .onChange(of: route.phase) { phase in
            if phase == .playing, let start = route.start, let end = route.end {
                recentRoutes.record(
                    name: route.editingSavedRoute?.name ?? route.travelMode.displayName,
                    start: start,
                    end: end,
                    viaPoints: route.vias,
                    travelMode: route.travelMode,
                    speedKilometersPerHour: route.speedKilometersPerHour,
                    offsetMeters: route.offsetMeters,
                    repeatMode: route.repeatMode
                )
            }
            syncRouteActivity()
            syncDeveloperLocationKeepAlive()
        }
        .onChange(of: route.speedKilometersPerHour) { _ in
            syncRouteActivity()
        }
        .onChange(of: favorites.favorites) { _ in
            syncRouteActivity()
        }
        .onChange(of: favorites.selectedFavoriteID) { _ in
            syncRouteActivity()
        }
        .onReceive(route.clock.$progress) { _ in
            syncRouteActivity()
        }
        .onReceive(route.clock.$statusMessage) { _ in
            syncRouteActivity()
        }
        .onChange(of: session.state) { state in
            switch state {
            case .active:
                if spotStopPending {
                    noteSpotActionFailure(message: "停止虚拟定位失败，定位仍保持。", command: "stopSpoof")
                }
            case .idle:
                if spotStopPending {
                    spotStopPending = false
                    spotSwitchPending = false
                    spotStoppedConfirmUntil = Date().addingTimeInterval(3)
                }
            case .verifying:
                spotIslandFailed = false
                spotActionFailed = false
            }
            syncRouteActivity()
            syncDeveloperLocationKeepAlive()
        }
        .onChange(of: routeLocation.isSimulating) { _ in
            syncDeveloperLocationKeepAlive()
        }
        .onAppear {
            displayedMapCoordinateSystem = CoordinateConverter.currentMapCoordinateSystem
            startMapRuntimeOnce()
            bindRoutePlayback()
            bindPhysicalWalk()
            registerRouteActivityToggle()
            if let session = route.sessionStore.load(), route.phase == .inactive {
                routeRecovery = session
            }
            if runtimeMode.mode == .localWiFi {
                registerWiFiChangeObserver()
            } else if runtimeMode.mode == .thirdParty {
                refreshThirdPartyState()
            }
            syncDeveloperTunnelMonitor()
            syncDeveloperLocationKeepAlive()
            syncPhysicalWalk()
        }
        .onDisappear {
            search.dismissResults()
            routeLocation.stopTunnelMonitor()
            if let token = wifiChangeObserverToken {
                net.removeWiFiChangeObserver(token)
                wifiChangeObserverToken = nil
            }
            wifiVerificationTask?.cancel()
            wifiVerificationTask = nil
            wifiVerificationID = nil
            mapCoordinateSystemRefreshTask?.cancel()
            mapCoordinateSystemRefreshTask = nil
            bluePointRefreshPending = false
            realtimeButtonTask?.cancel()
            realtimeButtonTask = nil
            favoriteSaveTask?.cancel()
            favoriteSaveTask = nil
        }
        .onChange(of: activeSheet) { sheet in
            if sheet != .settings { favoriteImport.leavePage() }
            if sheet != .savedRoutes { routeImport.leavePage() }
            if sheet != nil { search.dismissResults() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { search.dismissResults() }
            guard phase == .active else {
                if route.phase == .playing {
                    BackgroundKeepAlive.shared.retain(.routePlayback)
                }
                if physicalWalk.isTracking {
                    BackgroundKeepAlive.shared.retain(.physicalWalk)
                }
                // 切走时留着模拟连接。丢掉后回来重连，会和设备上还没回收的旧会话抢坐标。
                syncDeveloperLocationKeepAlive()
                return
            }
            routeLocation.refresh()
            if runtimeMode.mode == .developerTunnel {
                recoverDeveloperTunnelIfNeeded()
            }
            if runtimeMode.mode == .localWiFi, proxy.isRunning {
                BackgroundKeepAlive.shared.retain(.proxy)
            }
            if route.phase == .playing {
                BackgroundKeepAlive.shared.retain(.routePlayback)
            }
            if physicalWalk.isTracking {
                BackgroundKeepAlive.shared.retain(.physicalWalk)
            }
            RouteActivityBridge.drainPending()
            syncRouteActivity(retryCreation: true)
            if runtimeMode.mode == .thirdParty {
                refreshThirdPartyState()
            }
            Task { @MainActor in
                await awaitCoordinatedMapCoordinateSystemRefresh(reason: "App回到前台")
            }
        }
        .onChange(of: routeLocation.status.tunnelConnected) { connected in
            guard connected else { return }
            recoverDeveloperTunnelIfNeeded()
        }
        .onChange(of: mapState.selection.revision) { _ in
            refreshCachedSelectionPair()
        }
        .onChange(of: spoofState) { state in
            handleRouteSpoofStateChange(state)
            syncPhysicalWalk()
        }
        .onChange(of: physicalWalkStore.isEnabled) { _ in
            syncPhysicalWalk()
            syncRouteActivity()
        }
        .onChange(of: physicalWalkIslandSignature) { _ in
            syncRouteActivity()
        }
        .onChange(of: route.phase) { phase in
            handlePhysicalWalkRoutePhase(phase)
        }
        .onChange(of: route.waitingForActivation) { waiting in
            if waiting {
                physicalWalkStore.setEnabled(false)
            }
            syncPhysicalWalk()
        }
        .onChange(of: session.effectRevision) { _ in
            handleSpoofEffects(session.consumeEffects())
        }
        .onChange(of: route.pathRevision) { _ in
            let coordinates = route.overlayCoordinates
            guard coordinates.count >= 2 else { return }
            mapState.fitRoute(coordinates)
        }
        .onChange(of: net.isSatisfied) { _ in
            pauseRouteIfLocationBlocked()
        }
        .onChange(of: net.isWiFiEnabled) { _ in
            pauseRouteIfLocationBlocked()
        }
        .onChange(of: net.usesCellular) { _ in
            pauseRouteIfLocationBlocked()
        }
        .onChange(of: runtimeFailure.failure) { _ in
            pauseRouteIfLocationBlocked()
        }
        .onChange(of: proxy.isRunning) { running in
            if !running {
                session.noteLocalProxyStopped()
            }
        }
        .onChange(of: showEnableTip) { isPresented in
            guard !isPresented, let client = pendingCommunityContributionClient else { return }
            pendingCommunityContributionClient = nil
            DispatchQueue.main.async {
                communityContributionClient = client
            }
        }
        .onChange(of: session.writesSuspended) { suspended in
            if suspended { physicalWalk.stop() }
        }
        .onChange(of: runtimeMode.mode) { mode in
            session.cancelForModeChange()
            if let token = wifiChangeObserverToken {
                net.removeWiFiChangeObserver(token)
                wifiChangeObserverToken = nil
            }
            wifiVerificationTask?.cancel()
            wifiVerificationTask = nil
            if mode == .localWiFi {
                registerWiFiChangeObserver()
            } else if mode == .thirdParty {
                refreshThirdPartyState()
            }
            route.pause()
            if route.waitingForActivation {
                settleRouteSimulation(after: route.cancelWaiting(), from: .preparing)
            }
            syncDeveloperTunnelMonitor()
            syncDeveloperLocationKeepAlive()
            syncPhysicalWalk()
        }
        .sheet(isPresented: $showEnableTip) { enableTipSheet }
        .sheet(isPresented: $showDisableTip) { disableTipSheet }
        .alert("定位推送失败", isPresented: Binding(
            get: { !developerLocationError.isEmpty },
            set: { if !$0 { developerLocationError = "" } }
        )) {
            Button("再试一次") {
                retryDeveloperLocation(command: spotRetryCommand)
            }
            Button("打开路线定位") { showRouteLocationSetup = true }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(developerLocationError)
        }
        .alert("定位失败", isPresented: $showLocationAlert) {
            Button("打开设置") {
                openSettings(.locationServices)
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text("无法获取当前定位，请检查定位服务是否已开启")
        }
        .alert("无法开启真实走动", isPresented: Binding(
            get: { !physicalWalkStore.lastFailureMessage.isEmpty },
            set: { if !$0 { physicalWalkStore.clearFailure() } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(physicalWalkStore.lastFailureMessage)
        }
        .alert("编辑收藏名称", isPresented: Binding(
            get: { editingFavorite != nil },
            set: { if !$0 { editingFavorite = nil } }
        )) {
            TextField("名称", text: $editName)
            Button("保存") {
                if let f = editingFavorite {
                    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = name.isEmpty ? f.name : name
                    favorites.rename(f.id, to: finalName)
                    mapState.updateExplicitName(finalName, forFavoriteID: f.id)
                }
                editingFavorite = nil
            }
            Button("取消", role: .cancel) { editingFavorite = nil }
        } message: { Text("修改收藏地点名称") }
        .alert("保存路线", isPresented: $showSaveRouteAlert) {
            TextField("名称", text: $saveRouteName)
            if route.canOverwriteSavedRoute {
                Button("覆盖") { commitSaveRoute(overwrite: true) }
                Button("另存为") { commitSaveRoute(overwrite: false) }
            } else {
                Button("保存") { commitSaveRoute(overwrite: false) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let name = route.editingSavedRoute?.name {
                Text("覆盖会更新「\(name)」，另存为会再占一条。最多保存 \(SavedRouteStore.limit) 条。")
            } else {
                Text("保存起点、终点和途经点。沿路折线会压缩后单独存放，下次可以直接走。")
            }
        }
        .alert("继续上次路线", isPresented: Binding(
            get: { routeRecovery != nil },
            set: { if !$0 { routeRecovery = nil } }
        )) {
            Button("继续") {
                if let session = routeRecovery {
                    route.applyRecovery(session)
                    showsRoutePanel = true
                }
                routeRecovery = nil
            }
            Button("放弃", role: .cancel) {
                route.sessionStore.clear()
                routeRecovery = nil
                if #available(iOS 16.2, *) {
                    Task { await RouteLiveActivityCenter.shared.endNowIfIdle() }
                }
            }
        } message: {
            Text(routeRecovery.map { "从「\($0.name)」大约 \(Int(($0.progress * 100).rounded()))% 接着走。不会自动开始定位。" } ?? "")
        }
        .confirmationDialog(
            "退出会停止播放，虚拟定位留在当前点",
            isPresented: $showExitRouteConfirm,
            titleVisibility: .visible
        ) {
            Button("退出路线", role: .destructive) { exitRoute() }
            Button("取消", role: .cancel) {}
        }
    }

    var topControls: some View {
        HStack(spacing: 8) {
            MapSearchField(search: search, focus: $searchFocused, onSubmit: doSearch)
            if searchFocused {
                Button("完成") { searchFocused = false }
                    .frame(minWidth: 44, minHeight: 48)
                    .accessibilityLabel("结束搜索输入")
            } else {
                MapChromeIconButton(systemImage: "list.bullet.rectangle", accessibilityLabel: "日志") {
                    activeSheet = .logs
                }
                homeSettingsButton
            }
        }
    }

    func bottomControls(availableHeight: CGFloat) -> some View {
        let clusterHeight = min(availableHeight, AppLayout.homeFunctionClusterHeight)
        let cardHeight = max(140, clusterHeight - AppLayout.homeModeBarHeight - AppLayout.homeFunctionStackSpacing)
        return VStack(alignment: .trailing, spacing: 0) {
            homeMapTools
            VStack(spacing: AppLayout.homeFunctionStackSpacing) {
                homeModeAndEntries
                    .frame(height: AppLayout.homeModeBarHeight)
                    .clipped()
                homeStableActionCard(availableHeight: cardHeight)
            }
            .frame(maxWidth: .infinity)
            .frame(height: clusterHeight, alignment: .top)
            .accessibilityIdentifier("home.functionCluster")
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    func homeStableActionCard(availableHeight: CGFloat) -> some View {
        homeActionCard(availableHeight: availableHeight)
            .frame(height: availableHeight, alignment: .top)
    }

    func homeActionCard(availableHeight: CGFloat) -> some View {
        MapHomeBottomCard(
            displayName: homeDisplayName,
            selectionStatus: homeSelectionStatus,
            spoofState: spoofState,
            isFavoriteSelected: favorites.selectedFavoriteID != nil,
            favoriteSaveDisabled: favoriteSaveTask != nil,
            runtimeStatusText: homeRuntimeStatusText,
            runtimeStatusTone: homeRuntimeStatusTone,
            showsRoute: showsRoutePanelActive,
            showsRouteProgress: showsRoutePanelActive && showsRouteProgress,
            primaryTitle: homePeekTitle,
            primaryAccessibilityLabel: homePeekAccessibilityLabel,
            primarySystemImage: showsRoutePanelActive ? nil : buttonSystemImage,
            primaryColor: homePeekColor,
            primaryDisabled: homePeekDisabled,
            secondaryTitle: homeSecondaryAction?.title,
            secondaryDisabled: homeSecondaryAction == .stopLocation && (spotStopPending || spotSwitchPending || spoofState == .verifying),
            showsSpotHelp: spoofState != .idle && !routeKeepsRunningWhileSpotShown && !showsRoutePanelActive,
            availableHeight: availableHeight,
            playbackClock: route.clock,
            spotContent: { homeSpotControls },
            routePanel: { homeRouteControls },
            caption: {
                if !showsRoutePanelActive {
                    HomePeekCaption(route: route, clock: route.clock, showsRoute: false,
                                    physicalWalkText: physicalWalkPeekText)
                }
            },
            onHelp: {
                homePopup = nil
                if spoofState == .active {
                    activeTip = .activation
                } else {
                    activeTip = .deactivation
                }
            },
            onToggleFavorite: {
                homePopup = nil
                if favorites.selectedFavoriteID != nil {
                    favorites.select(nil)
                } else {
                    saveCurrentSelectionAsFavorite()
                }
            },
            onOpenSettings: { activeSheet = .settings },
            onPrimaryTap: { homePopup = nil; handlePeekTap() },
            onSecondaryTap: { homePopup = nil; handleHomeSecondaryTap() },
            viaTitle: homeViaActionTitle,
            viaDisabled: homeViaActionDisabled,
            onViaTap: { homePopup = nil; handleHomeViaTap() }
        )
    }

    func openSettings(_ destination: SystemSettingsDestination) {
        SystemSettingsNavigator.open(destination) { fallbackHint in
            if let fallbackHint { manualHint = fallbackHint }
        }
    }

    var currentSelectionFavorite: FavoriteLocation {
        FavoriteLocation(
            name: mapState.displayName ?? String(
                format: "%.4f, %.4f",
                mapState.selection.coordinate.latitude,
                mapState.selection.coordinate.longitude
            ),
            coordinatePair: .init(
                mapCoordinate: mapState.selection.coordinate,
                mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
            ),
            accuracy: LocationAccuracyStore.shared.meters
        )
    }

    var currentSelectionPair: CoordinatePair { cachedSelectionPair }

    /// 走动跟踪时显示蓝点当前坐标；否则仍是地图中心选点。
    var displayedCoordinatePair: CoordinatePair {
        if physicalWalk.isTracking,
           let latitude = physicalWalk.currentLatitude,
           let longitude = physicalWalk.currentLongitude {
            return CoordinateConverter.coordinatePair(
                lat: latitude,
                lon: longitude,
                mapCoordinateSystem: .wgs84
            )
        }
        return currentSelectionPair
    }

    func refreshCachedSelectionPair() {
        if let stored = LastCoordinateStore.load(),
           stored.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            .isApproximatelyEqual(to: mapState.selection.coordinate) {
            cachedSelectionPair = stored.coordinatePair
            return
        }
        cachedSelectionPair = CoordinatePair(
            mapCoordinate: mapState.selection.coordinate,
            mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
        )
    }

    var testFavorite: FavoriteLocation { currentSelectionFavorite }

}


