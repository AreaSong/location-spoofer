import Foundation

enum SpoofSelectionSwitch {
    /// 切换按钮比较的是已经写入的坐标，不是路线播放里每秒插值的位置。
    static func needsSwitch(
        isActive: Bool,
        writtenLatitude: Double?,
        writtenLongitude: Double?,
        selection: CoordinatePair
    ) -> Bool {
        guard isActive, let writtenLatitude, let writtenLongitude else { return false }
        return !selection.matchesWGS84(latitude: writtenLatitude, longitude: writtenLongitude)
    }
}
