import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    var searchResultList: some View {
        MapSearchResults(search: search, onSelect: selectSearchResult,
                         onCopy: copySearchCoordinate, onSave: saveSearchResult)
    }

    func favoriteChip(_ f: FavoriteLocation) -> some View {
        let selected = favorites.selectedFavoriteID == f.id
        let smartIcon = FavoriteLocationStore.smartBadgeIcon(for: f.name)
        return Button { select(f) } label: {
            HStack(spacing: 6) {
                if let smartIcon {
                    Image(systemName: smartIcon)
                        .foregroundStyle(selected ? Color.accentColor : Color.orange)
                } else {
                    Image(systemName: selected ? "star.fill" : "star")
                }
                Text(compactChipTitle(f.name)).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(minWidth: 120, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            (selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: AppRadius.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.inset)
                .stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear)
        )
        .accessibilityLabel(selected ? "\(f.name)，已选中" : f.name)
    }

    func recentChip(_ item: RecentSelection) -> some View {
        HStack(spacing: 0) {
            Button { selectRecent(item) } label: {
                Text(compactChipTitle(item.name))
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(minWidth: 88, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                recentSelections.remove(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary.opacity(0.55))
            .accessibilityLabel("从最近选点中删除")
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.inset))
    }

    /// 芯片只展示缩写，完整名称留给无障碍和标题。
    func compactChipTitle(_ name: String) -> String {
        let parts = name.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else {
            return name
        }
        return String(format: "%.3f,%.3f", latitude, longitude)
    }

    func rememberDiscreteSelection(name: String, coordinatePair: CoordinatePair) {
        recentSelections.record(name: name, coordinatePair: coordinatePair)
    }

    func formattedSelectionName(for pair: CoordinatePair) -> String {
        String(format: "%.4f, %.4f", pair.wgs84.latitude, pair.wgs84.longitude)
    }

    func selectRecent(_ item: RecentSelection) {
        Haptics.selection()
        search.dismissResults()
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
        Button("全部") {
            activeSheet = .favorites
        }
        .buttonStyle(CapsuleChipStyle(tint: .primary))
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
            Haptics.success()
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
        // 优先命中本地空间网格缓存
        if let cachedDescriptor = SpatialGeocodeCache.shared.get(
            latitude: wgsCoordinate.latitude,
            longitude: wgsCoordinate.longitude
        ) {
            _ = mapState.acceptPlaceDescriptor(cachedDescriptor, selectionRevision: revision)
            if let name = mapState.displayName {
                recentSelections.updateNameIfPresent(for: pair, name: name)
            }
            return
        }

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
                    SpatialGeocodeCache.shared.set(
                        descriptor,
                        latitude: wgsCoordinate.latitude,
                        longitude: wgsCoordinate.longitude
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
        search.submit(
            system: CoordinateConverter.currentMapCoordinateSystem,
            preferred: CoordinateInputPreferenceStore.shared.lastSystem
        )
    }

    func selectSearchResult(_ result: SearchLocationResult) {
        search.select(result)
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
    }

    func copySearchCoordinate(_ result: SearchLocationResult) {
        let pair = CoordinatePair(
            mapCoordinate: result.coordinate,
            mapCoordinateSystem: result.mapCoordinateSystem
        )
        let gcj = pair.gcj02
        let wgs = pair.wgs84
        UIPasteboard.general.string = String(
            format: "GCJ-02 %.6f, %.6f\nWGS-84 %.6f, %.6f",
            gcj.latitude, gcj.longitude, wgs.latitude, wgs.longitude
        )
    }

    func saveSearchResult(_ result: SearchLocationResult) {
        search.dismissResults()
        let pair = CoordinatePair(
            mapCoordinate: result.coordinate,
            mapCoordinateSystem: result.mapCoordinateSystem
        )
        let favorite = favorites.save(
            name: result.name,
            coordinatePair: pair,
            accuracy: LocationAccuracyStore.shared.meters
        )
        mapState.selectFavorite(
            pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            id: favorite.id,
            name: favorite.name
        )
    }

    func handleFavoritePinTap(_ pin: FavoriteMapPin) {
        guard let favorite = favorites.favorites.first(where: { $0.id == pin.id }) else { return }
        select(favorite)
    }

    func select(_ favorite: FavoriteLocation) {
        search.dismissResults()
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

/// 空间地理编码 LRU 缓存。将经纬度离散为约 100 米的空间网格，避免短时间内频繁请求 Apple 地理编码接口。
@MainActor
final class SpatialGeocodeCache {
    static let shared = SpatialGeocodeCache()

    private let maxCount: Int
    private var cache: [String: MapPlaceDescriptor] = [:]
    private var keys: [String] = []

    init(maxCount: Int = 120) {
        self.maxCount = maxCount
    }

    private func gridKey(latitude: Double, longitude: Double) -> String {
        let latGrid = Int((latitude * 1000).rounded())
        let lonGrid = Int((longitude * 1000).rounded())
        return "\(latGrid)_\(lonGrid)"
    }

    func get(latitude: Double, longitude: Double) -> MapPlaceDescriptor? {
        let key = gridKey(latitude: latitude, longitude: longitude)
        guard let value = cache[key] else { return nil }
        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
            keys.append(key)
        }
        return value
    }

    func set(_ descriptor: MapPlaceDescriptor, latitude: Double, longitude: Double) {
        let key = gridKey(latitude: latitude, longitude: longitude)
        if cache[key] != nil {
            cache[key] = descriptor
            if let index = keys.firstIndex(of: key) {
                keys.remove(at: index)
                keys.append(key)
            }
            return
        }

        if keys.count >= maxCount {
            let oldest = keys.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        keys.append(key)
        cache[key] = descriptor
    }

    func clear() {
        cache.removeAll()
        keys.removeAll()
    }
}
