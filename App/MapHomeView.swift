import SwiftUI
import MapKit
import UIKit
import CoreLocation

struct SearchLocationResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem
    var remembersPreference = false
}

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
    @StateObject var savedRoutes = SavedRouteStore()
    @StateObject var actions: LocationActionCoordinator
    @StateObject var route: RoutePlaybackController
    @StateObject var session: SpoofSession
    @ObservedObject var proxy = ProxyManager.shared
    @ObservedObject var keepAlive = BackgroundKeepAlive.shared
    @ObservedObject var recentSelections = RecentSelectionStore.shared
    @ObservedObject var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject var remoteConfiguration = AppRemoteConfigurationStore.shared
    @StateObject var realtime = RealtimeLocationManager.shared
    @StateObject var mapState: MapLocationState
    @ObservedObject var net = NetworkMonitor.shared
    @ObservedObject var signingExpiryBanner = SigningExpiryBannerStore.shared
    @ObservedObject var runtimeFailure = LocationRuntimeFailureStore.shared

    @State var searchText = ""
    @State var searchResults: [SearchLocationResult] = []
    @State var isSearching = false
    @State var searchRequestID: UInt64 = 0
    @State var searchError = ""
    @State var mapRuntimeDidStart = false
    @State var activeSheet: HomeSheet?
    @State var showEnableTip = false
    @State var showDisableTip = false
    @State var activeTip: TipKind?
    @State var manualHint = ""
    let tipPreferences = VirtualLocationTipPreferences()
    let communityPromptPreferences = ThirdPartyCommunityPromptPreferences()
    @State var pendingCommunityContributionClient: ThirdPartyProxyClient?
    @State var communityContributionClient: ThirdPartyProxyClient?
    @State var showCommunityTemplateCopied = false
    @State var githubDestination: SafariDestination?
    @State var editingFavorite: FavoriteLocation?
    @State var editName = ""
    @State var showSaveRouteAlert = false
    @State var saveRouteName = ""
    @State var reverseGeocodeTask: Task<Void, Never>?
    @State var geocodeDebounceTask: Task<Void, Never>?
    @State var showLocationAlert = false
    @State var showSigningResignSheet = false
    @State var realtimeRequestTask: Task<Void, Never>?
    @State var realtimeRequestContext: RealtimeLocationRequestContext?
    @State var wifiChangeObserverToken: UUID?
    @State var wifiVerificationTask: Task<Void, Never>?
    @State var wifiVerificationID: UUID?
    @State var copiedCoordinateSystem: CoordinateConverter.MapCoordinateSystem?
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
                onRoutePinTap: handleRoutePinTap,
                onUserZoomChanged: { distance in
                    ViewportStore.save(distance)
                    LastCoordinateStore.updateZoom(distance)
                },
                onZoomIn: { mapState.zoom(by: 0.5) },
                onZoomOut: { mapState.zoom(by: 2) },
                routeCoordinates: route.overlayCoordinates,
                routePins: route.overlayPins,
                playbackClock: route.clock
            )
            .ignoresSafeArea(.container)

            VStack(spacing: 10) {
                topControls
                if let block = locationUseBlock {
                    locationUnavailableOverlay(block)
                        .onAppear { pauseRouteIfLocationBlocked() }
                }
                if locationUseBlock == nil, let message = signingExpiryMapMessage {
                    signingExpiryBannerView(message)
                }
                if !searchResults.isEmpty || !searchError.isEmpty { searchResultList }
                Spacer()
                // 右下角按钮
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Button {
                            if let url = URL(string: "maps://app") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        }
                        Button {
                            requestRealtimeLocation()
                        } label: {
                            if realtime.isRequesting {
                                ProgressView()
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            } else {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            }
                        }
                        .disabled(realtimeButtonTask != nil || realtimeRequestTask != nil || realtime.isRequesting)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                if route.phase != .inactive {
                    RoutePlaybackPanel(
                        route: route,
                        clock: route.clock,
                        currentPair: currentSelectionPair,
                        onPlay: playRoute,
                        onExit: exitRoute,
                        onSave: promptSaveRoute,
                        onOpenSaved: openSavedRoutes
                    )
                    routePlaybackSpoofControls
                } else {
                    bottomControls
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .navigationBarHidden(true)
        .sheet(item: $activeSheet) { sheet in
            NavigationView {
                switch sheet {
                case .settings: SettingsView(setup: setup, actions: actions, favorites: favorites)
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
                        onSelect: { saved in
                            route.load(saved)
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
        .onAppear {
            displayedMapCoordinateSystem = CoordinateConverter.currentMapCoordinateSystem
            startMapRuntimeOnce()
            bindRoutePlayback()
            if runtimeMode.mode == .localWiFi {
                registerWiFiChangeObserver()
            } else {
                refreshThirdPartyState()
            }
        }
        .onDisappear {
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
        .onChange(of: scenePhase) { phase in
            guard phase == .active else {
                if route.phase == .playing {
                    BackgroundKeepAlive.shared.start()
                }
                return
            }
            if runtimeMode.mode == .localWiFi, proxy.isRunning {
                BackgroundKeepAlive.shared.start()
            }
            if route.phase == .playing {
                BackgroundKeepAlive.shared.start()
            }
            if runtimeMode.mode == .thirdParty {
                refreshThirdPartyState()
            }
            Task { @MainActor in
                await awaitCoordinatedMapCoordinateSystemRefresh(reason: "App回到前台")
            }
        }
        .onChange(of: mapState.selection.revision) { _ in
            refreshCachedSelectionPair()
        }
        .onChange(of: spoofState) { state in
            handleRouteSpoofStateChange(state)
        }
        .onChange(of: session.effectRevision) { _ in
            handleSpoofEffects(session.consumeEffects())
        }
        .onChange(of: route.pathRevision) { _ in
            let coordinates = route.overlayCoordinates
            guard coordinates.count >= 2 else { return }
            mapState.fitRoute(coordinates)
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
            } else {
                refreshThirdPartyState()
            }
            route.pause()
            if route.waitingForActivation {
                route.cancelWaiting()
            }
        }
        .sheet(isPresented: $showEnableTip) { enableTipSheet }
        .sheet(isPresented: $showDisableTip) { disableTipSheet }
        .alert("定位失败", isPresented: $showLocationAlert) {
            Button("打开设置") {
                openSettings(.locationServices)
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text("无法获取当前定位，请检查定位服务是否已开启")
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
                Text("覆盖会更新「\(name)」，另存为会再占一条。最多保存 20 条。")
            } else {
                Text("保存起点、终点、途经点和沿路折线，下次可以直接走。")
            }
        }
    }

    var topControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地点、坐标或地图链接", text: $searchText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit(doSearch)
                if isSearching { ProgressView().controlSize(.small) }
                else if !searchText.isEmpty {
                    Button {
                        searchRequestID &+= 1
                        isSearching = false
                        searchText = ""
                        searchResults = []
                        searchError = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Button(action: doSearch) { Image(systemName: "arrow.right.circle.fill").font(.title3) }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
            Menu {
                Button {
                    enterRoute()
                } label: {
                    Label("走路", systemImage: "figure.walk")
                }
                Button {
                    openSavedRoutes()
                } label: {
                    Label("已存路线", systemImage: "folder")
                }
                Button { activeSheet = .logs } label: { Label("日志", systemImage: "list.bullet.rectangle") }
                Button { activeSheet = .settings } label: { Label("设置", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
                    .contentShape(Circle())
            }.accessibilityLabel("更多")
        }
    }

    // 底部：当前选点 + 收藏 + 主控按钮
    var bottomControls: some View {
        MapHomeBottomCard(
            displayName: mapState.displayName ?? "当前选点",
            mapSystemName: displayedMapCoordinateSystem.diagnosticName,
            spoofState: spoofState,
            isFavoriteSelected: favorites.selectedFavoriteID != nil,
            favoriteSaveDisabled: favoriteSaveTask != nil,
            hasRecents: !recentSelections.items.isEmpty,
            favoritesEmpty: favorites.favorites.isEmpty,
            runtimeStatusText: homeRuntimeStatusText,
            needsSwitchButton: needsSwitchButton,
            buttonTitle: buttonTitle,
            buttonColor: buttonColor,
            coordinateRows: {
                coordinateRow(label: "GCJ-02(国内)", system: .gcj02)
                coordinateRow(label: "WGS-84(国际)", system: .wgs84)
            },
            recentChips: {
                ForEach(recentSelections.items) { item in
                    recentChip(item)
                }
            },
            favoriteChips: {
                ForEach(favorites.displayedFavorites) { favorite in
                    favoriteChip(favorite)
                }
            },
            allFavoritesButton: { allFavoritesButton },
            onHelp: {
                if spoofState == .active {
                    activeTip = .activation
                } else {
                    activeTip = .deactivation
                }
            },
            onToggleFavorite: {
                if favorites.selectedFavoriteID != nil {
                    favorites.select(nil)
                    return
                }
                saveCurrentSelectionAsFavorite()
            },
            onOpenSettings: { activeSheet = .settings },
            onMainTap: handleMainButtonTap,
            onSwitchHere: { beginLocationOperation() }
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

    func coordinateRow(
        label: String,
        system: CoordinateConverter.MapCoordinateSystem
    ) -> some View {
        let coordinate = currentSelectionPair.coordinate(for: system)
        let text = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        let isCurrent = displayedMapCoordinateSystem == system
        let valueColor: Color = copiedCoordinateSystem == system ? .green : (isCurrent ? .primary : .secondary)
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .layoutPriority(1)
            if isCurrent {
                Text("当前")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = text
            copiedCoordinateSystem = system
            RuntimeLogger.info("APP", "地图", "已复制坐标", details: [
                "坐标标准": system.diagnosticName
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedCoordinateSystem == system { copiedCoordinateSystem = nil }
            }
        }
        .overlay(alignment: .topTrailing) {
            if copiedCoordinateSystem == system {
                Text("已复制")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.green, in: Capsule())
                    .offset(y: -24)
            }
        }
    }

    var testFavorite: FavoriteLocation { currentSelectionFavorite }

}
