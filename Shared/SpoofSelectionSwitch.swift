import Foundation

enum SpoofSelectionSwitch {
    /// 比较用户提交时选中的目标。随机偏移后的实际写入点不参与比较，否则按钮会一直显示。
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
