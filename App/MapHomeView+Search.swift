import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    // 搜索列表：动态高度，不写死
    var searchResultList: some View {
        VStack(spacing: 0) {
            if !searchError.isEmpty {
                Text(searchError).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ForEach(searchResults) { r in
                HStack(spacing: 8) {
                    Button { selectSearchResult(r) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button(role: .destructive) { deleteSearchResult(r) } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                if r.id != searchResults.last?.id { Divider().padding(.leading, 46) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func favoriteChip(_ f: FavoriteLocation) -> some View {
        HStack(spacing: 0) {
            Button { select(f) } label: {
                Label(f.name, systemImage: favorites.selectedFavoriteID == f.id ? "checkmark.circle.fill" : "mappin")
                    .lineLimit(1).padding(.leading, 10).padding(.vertical, 8).padding(.trailing, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().frame(height: 22)
            Button {
                editingFavorite = f
                editName = f.name
            } label: {
                Image(systemName: "pencil").font(.caption2).frame(width: 32, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.55))
            Divider().frame(height: 22)
            Button(role: .destructive) { favorites.delete(f) } label: {
                Image(systemName: "trash").font(.caption.weight(.semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .background((favorites.selectedFavoriteID == f.id ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12)), in: Capsule())
        .overlay(Capsule().stroke(favorites.selectedFavoriteID == f.id ? Color.red.opacity(0.7) : Color.clear))
    }

    func recentChip(_ item: RecentSelection) -> some View {
        HStack(spacing: 0) {
            Button { selectRecent(item) } label: {
                Label(item.name, systemImage: "clock")
                    .lineLimit(1).padding(.leading, 10).padding(.vertical, 8).padding(.trailing, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().frame(height: 22)
            Button {
                recentSelections.remove(item)
            } label: {
                Image(systemName: "xmark").font(.caption2).frame(width: 32, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.55))
        }
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    func rememberDiscreteSelection(name: String, coordinatePair: CoordinatePair) {
        recentSelections.record(name: name, coordinatePair: coordinatePair)
    }

    func formattedSelectionName(for pair: CoordinatePair) -> String {
        String(format: "%.4f, %.4f", pair.wgs84.latitude, pair.wgs84.longitude)
    }

    func selectRecent(_ item: RecentSelection) {
        if let favorite = favorites.favorites.first(where: {
            $0.coordinatePair.matchesWGS84(
                latitude: item.coordinatePair.wgs84.latitude,
                longitude: item.coordinatePair.wgs84.longitude
            )
        }) {
            select(favorite)
            return
        }
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(nil)
        mapState.selectSearchResult(
            item.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            name: item.name
        )
        LastCoordinateStore.save(
            coordinatePair: item.coordinatePair,
            zoomMeters: mapState.viewportMeters
        )
        cachedSelectionPair = item.coordinatePair
        rememberDiscreteSelection(name: item.name, coordinatePair: item.coordinatePair)
    }

    var allFavoritesButton: some View {
        Button {
            activeSheet = .favorites
        } label: {
            Text("全部")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .accessibilityLabel("打开收藏列表")
    }

    func saveCurrentSelectionAsFavorite() {
        guard favoriteSaveTask == nil else { return }
        let snapshot = currentSelectionFavorite
        // Preserve the pair created when this selection entered the map. If
        // the runtime probe changes type, replay its other stored field instead
        // of reinterpreting the old visible coordinate as the new type.
        let pair = currentSelectionPair
        let selectionRevision = mapState.selection.revision
        favoriteSaveTask = Task { @MainActor in
            defer { favoriteSaveTask = nil }
            await awaitCoordinatedMapCoordinateSystemRefresh(reason: "保存收藏")
            guard !Task.isCancelled else {
                return
            }
            guard mapState.selection.revision == selectionRevision else {
                RuntimeLogger.info("APP", "坐标转换", "取消保存收藏：检测期间当前选点已变化")
                return
            }
            RuntimeLogger.info("APP", "坐标转换", "保存当前选点为收藏", details: [
                "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
                "持久化字段": "国际标准(WGS-84)+国内标准(GCJ-02)"
            ])
            let favorite = favorites.save(
                name: snapshot.name,
                coordinatePair: pair,
                accuracy: snapshot.accuracy
            )
            mapState.selectFavorite(
                pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
                id: favorite.id,
                name: favorite.name
            )
            LastCoordinateStore.save(coordinatePair: pair, zoomMeters: mapState.viewportMeters)
            cachedSelectionPair = pair
        }
    }

    func scheduleGeocode(pair: CoordinatePair, revision: UInt64) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        geocodeDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, mapState.selection.revision == revision else { return }
            reverseGeocode(pair, revision: revision)
        }
    }

    func reverseGeocode(_ pair: CoordinatePair, revision: UInt64) {
        reverseGeocodeTask?.cancel()
        let wgsCoordinate = pair.wgs84.coordinate
        let mapCoordinate = pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
        let location = CLLocation(latitude: wgsCoordinate.latitude, longitude: wgsCoordinate.longitude)
        reverseGeocodeTask = Task { @MainActor in
            let retryDelays: [UInt64] = [0, 800_000_000, 1_600_000_000]
            var lastError: Error?

            for (attempt, delay) in retryDelays.enumerated() {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                }
                guard !Task.isCancelled, mapState.selection.revision == revision else { return }

                do {
                    // 并⾏获取：CLGeocoder（地址结构化） + MKLocalSearch（地图显⽰名称）
                    // MKLocalSearch 在无结果时抛错，不可与 CLGeocoder 共用 try await 导致互相影响
                    async let clPlacemarks = CLGeocoder().reverseGeocodeLocation(location)
                    let mkRequest = MKLocalSearch.Request()
                    mkRequest.region = MKCoordinateRegion(center: mapCoordinate, latitudinalMeters: 400, longitudinalMeters: 400)
                    let mkResponse = try? await MKLocalSearch(request: mkRequest).start()

                    let placemarks = try await clPlacemarks
                    guard !Task.isCancelled,
                          mapState.selection.revision == revision,
                          let placemark = placemarks.first else { return }

                    if mkResponse?.mapItems.first != nil {
                        RuntimeLogger.info("APP", "Geocode", "MKLocalSearch 返回地点结果")
                    }
                    let mapItemName = mkResponse?.mapItems.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mapItemPOI = mkResponse?.mapItems.first?.placemark.areasOfInterest?.first
                    // 优先使⽤ MKLocalSearch 结果（与地图显⽰一致），CLGeocoder 作为 fallback
                    let poi = { () -> String? in
                        if let v = mapItemPOI?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                        if let v = mapItemName?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                        return placemark.areasOfInterest?.first ?? placemark.name
                    }()
                    let streetAddress = [placemark.thoroughfare, placemark.subThoroughfare]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let descriptor = MapPlaceDescriptor(
                        pointOfInterest: poi,
                        streetAddress: streetAddress,
                        road: placemark.thoroughfare,
                        neighborhood: placemark.subLocality,
                        district: placemark.subLocality ?? placemark.subAdministrativeArea,
                        city: placemark.locality ?? placemark.subAdministrativeArea,
                        province: placemark.administrativeArea,
                        country: placemark.country
                    )
                    _ = mapState.acceptPlaceDescriptor(descriptor, selectionRevision: revision)
                    if let name = mapState.displayName {
                        recentSelections.updateNameIfPresent(for: pair, name: name)
                    }
                    return
                } catch {
                    guard !Task.isCancelled, mapState.selection.revision == revision else { return }
                    lastError = error
                    let nsError = error as NSError
                    let isNetworkError = nsError.domain == kCLErrorDomain
                        && nsError.code == CLError.network.rawValue
                    guard isNetworkError, attempt < retryDelays.count - 1 else { break }
                    RuntimeLogger.info("APP", "Geocode", "反向地理编码网络失败，准备重试", details: [
                        "attempt": String(attempt + 1),
                        "revision": String(revision)
                    ])
                }
            }

            guard !Task.isCancelled,
                  mapState.selection.revision == revision,
                  let lastError else { return }
            RuntimeLogger.warning("APP", "Geocode", "反向地理编码失败", details: [
                "error": lastError.localizedDescription,
                "revision": String(revision)
            ])
        }
    }

    func doSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        searchRequestID &+= 1
        let requestID = searchRequestID
        if presentMapLinkSearchResults(query) || presentCoordinateSearchResults(query) {
            return
        }
        isSearching = true
        searchError = ""
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                guard requestID == searchRequestID else { return }
                isSearching = false
                if let error {
                    searchResults = []
                    searchError = error.localizedDescription
                    return
                }
                searchResults = (response?.mapItems ?? []).prefix(6).map { item in
                    let r = SearchLocationResult(
                        name: item.name ?? "未命名",
                        subtitle: [item.placemark.locality, item.placemark.subLocality, item.placemark.thoroughfare]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        coordinate: item.placemark.coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    RuntimeLogger.info("APP", "搜索", "获得搜索结果", details: [
                        "名称": r.name
                    ])
                    return r
                }
                if searchResults.isEmpty { searchError = "没有找到相关地点" }
            }
        }
    }

    func presentCoordinateSearchResults(_ query: String) -> Bool {
        guard let parsed = CoordinateTextParser.parse(query) else { return false }
        let coordinate = CLLocationCoordinate2D(latitude: parsed.latitude, longitude: parsed.longitude)
        let name = String(format: "%.6f, %.6f", parsed.latitude, parsed.longitude)
        presentCoordinateChoices(
            name: name,
            coordinate: coordinate,
            preferred: CoordinateInputPreferenceStore.shared.lastSystem,
            sourceLabel: nil,
            remembersPreference: true
        )
        RuntimeLogger.info("APP", "搜索", "识别为坐标输入", details: [
            "latitude": String(parsed.latitude),
            "longitude": String(parsed.longitude)
        ])
        return true
    }

    func presentMapLinkSearchResults(_ query: String) -> Bool {
        guard let parsed = MapLinkParser.parse(query) else { return false }
        let coordinate = CLLocationCoordinate2D(latitude: parsed.latitude, longitude: parsed.longitude)
        let name = parsed.name ?? String(format: "%.6f, %.6f", parsed.latitude, parsed.longitude)
        presentCoordinateChoices(
            name: name,
            coordinate: coordinate,
            preferred: parsed.inferredSystem,
            sourceLabel: "\(parsed.sourceName)链接",
            remembersPreference: false
        )
        RuntimeLogger.info("APP", "搜索", "识别为地图链接", details: [
            "来源": parsed.sourceName,
            "推断标准": parsed.inferredSystem.diagnosticName,
            "latitude": String(parsed.latitude),
            "longitude": String(parsed.longitude)
        ])
        return true
    }

    func presentCoordinateChoices(
        name: String,
        coordinate: CLLocationCoordinate2D,
        preferred: CoordinateConverter.MapCoordinateSystem,
        sourceLabel: String?,
        remembersPreference: Bool
    ) {
        isSearching = false
        searchError = ""
        func result(_ system: CoordinateConverter.MapCoordinateSystem) -> SearchLocationResult {
            let choice = system == .gcj02 ? "按国内标准(GCJ-02)选点" : "按国际标准(WGS-84)选点"
            let subtitle = sourceLabel.map { "\($0) · \(choice)" } ?? choice
            return SearchLocationResult(
                name: name,
                subtitle: subtitle,
                coordinate: coordinate,
                mapCoordinateSystem: system,
                remembersPreference: remembersPreference
            )
        }
        let gcj = result(.gcj02)
        let wgs = result(.wgs84)
        searchResults = preferred == .wgs84 ? [wgs, gcj] : [gcj, wgs]
    }

    func selectSearchResult(_ result: SearchLocationResult) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(nil)
        if result.remembersPreference {
            CoordinateInputPreferenceStore.shared.setLastSystem(result.mapCoordinateSystem)
        }
        let pair = CoordinatePair(
            mapCoordinate: result.coordinate,
            mapCoordinateSystem: result.mapCoordinateSystem
        )
        mapState.selectSearchResult(
            pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            name: result.name
        )
        LastCoordinateStore.save(
            coordinatePair: pair,
            zoomMeters: mapState.viewportMeters
        )
        cachedSelectionPair = pair
        rememberDiscreteSelection(name: result.name, coordinatePair: pair)
        searchText = result.name
        searchResults = []
        searchError = ""
    }

    func deleteSearchResult(_ result: SearchLocationResult) {
        searchResults.removeAll { $0.id == result.id }
    }

    func select(_ favorite: FavoriteLocation) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(favorite.id)
        RuntimeLogger.info("APP", "坐标转换", "点击收藏点并回显到地图", details: [
            "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "地图取值字段": CoordinateConverter.currentMapCoordinateSystem == .gcj02 ? "coordinatePair.gcj02" : "coordinatePair.wgs84",
            "保存数据包含": "国际标准(WGS-84)+国内标准(GCJ-02)"
        ])
        mapState.selectFavorite(
            favorite.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            id: favorite.id,
            name: favorite.name
        )
        LastCoordinateStore.save(
            coordinatePair: favorite.coordinatePair,
            zoomMeters: mapState.viewportMeters
        )
        cachedSelectionPair = favorite.coordinatePair
        rememberDiscreteSelection(name: favorite.name, coordinatePair: favorite.coordinatePair)
    }
}
