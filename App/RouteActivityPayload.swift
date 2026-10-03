import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct RouteActivityPayload: Encodable {
    // Apple: 静态 attributes 与动态 state 合计最多 4 KB（含更新）。
    // https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
    // 包含 JSON 包装键仍控制在 3800 字节，为框架元数据保留余量。
    static let byteLimit = 3800
    static let attributeNameLimit = 256

    var attributes: RouteActivityAttributes
    var state: RouteActivityAttributes.ContentState

    enum BudgetError: Error, Equatable {
        case protectedFieldsTooLarge
        case encodingFailed
    }

    static func prepare(
        name: String,
        state: RouteActivityAttributes.ContentState,
        existingAttributes: RouteActivityAttributes? = nil,
        limit: Int = byteLimit
    ) throws -> Self {
        let attributes = try existingAttributes ?? RouteActivityAttributes(
            name: clipped(name, bytes: attributeNameLimit)
        )
        var payload = Self(attributes: attributes, state: state)
        // 不改写命令、标识、阶段或符号；异常结构字段直接失败，避免编码巨大输入。
        let protected = [attributes.name, state.kind, state.phase, state.symbolName, state.modeSymbolName,
                         state.primaryAction, state.secondaryAction, state.tertiaryAction, state.retryCommand]
        guard limit > 0, protected.allSatisfy({ $0.utf8.prefix(limit + 1).count <= limit }) else {
            throw BudgetError.protectedFieldsTooLarge
        }
        for field in displayFields {
            payload.state[keyPath: field] = try clipped(payload.state[keyPath: field], bytes: byteLimit)
        }
        if try payload.encodedSize() <= limit { return payload }
        // 固定退化顺序：名称/详情、按钮文案与度量，最后才压缩状态和错误。
        let reductions: [(WritableKeyPath<RouteActivityAttributes.ContentState, String>, Int)] = [
            (\.title, 256), (\.detailText, 256),
            (\.primaryTitle, 128), (\.secondaryTitle, 128), (\.tertiaryTitle, 128),
            (\.distanceText, 64), (\.timeText, 64), (\.speedText, 64),
            (\.statusText, 128), (\.errorText, 768)
        ]
        for (field, bytes) in reductions {
            payload.state[keyPath: field] = try clipped(payload.state[keyPath: field], bytes: bytes)
            if try payload.encodedSize() <= limit { return payload }
        }
        // 错误仍有前缀和省略号，关键状态与命令仍完整；放不下就拒绝发布。
        throw BudgetError.protectedFieldsTooLarge
    }

    func encodedSize() throws -> Int {
        do { return try JSONEncoder().encode(self).count }
        catch { throw BudgetError.encodingFailed }
    }

    func reconciled(
        with actualAttributes: RouteActivityAttributes,
        sourceState: RouteActivityAttributes.ContentState
    ) throws -> Self {
        // String == 会把 NFC/NFD 判为相等，不能据此复用字节预算。
        if attributes.name.utf8.elementsEqual(actualAttributes.name.utf8) { return self }
        return try Self.prepare(name: actualAttributes.name, state: sourceState,
                                existingAttributes: actualAttributes)
    }

    private static let displayFields: [WritableKeyPath<RouteActivityAttributes.ContentState, String>] = [
        \.title, \.statusText, \.detailText, \.distanceText, \.timeText, \.speedText,
        \.errorText, \.primaryTitle, \.secondaryTitle, \.tertiaryTitle
    ]

    /// 先取字节有界的完整字素，再按真实 JSON 编码结果二分；不切 UTF-8 或组合字符。
    private static func clipped(_ text: String, bytes: Int) throws -> String {
        let encoder = JSONEncoder()
        if text.utf8.prefix(bytes + 1).count <= bytes,
           try encoder.encode(text).count <= bytes { return text }
        var characters: [Character] = []
        var used = 0
        for character in text {
            let value = String(character)
            let count = value.utf8.prefix(bytes + 1).count
            guard used + count <= bytes else { break }
            characters.append(character)
            used += count
        }
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters.prefix(middle)) + "…"
            if try encoder.encode(candidate).count <= bytes { low = middle }
            else { high = middle - 1 }
        }
        return String(characters.prefix(low)) + "…"
    }

    static func routeDetail(_ snapshot: RouteActivitySnapshot) -> String {
        RouteActivitySync.detailText(for: snapshot)
    }

    static func showsRouteProgress(_ phase: RouteActivityPhaseKey) -> Bool {
        switch phase {
        case .playing, .userPaused, .systemFault, .retrying, .finished, .actionFailed:
            return true
        case .stopped, .planning:
            return false
        }
    }

    static func routeState(_ snapshot: RouteActivitySnapshot) -> RouteActivityAttributes.ContentState {
        RouteActivityAttributes.ContentState(
            kind: "route",
            title: snapshot.routeName,
            statusText: snapshot.statusText,
            detailText: routeDetail(snapshot),
            distanceText: snapshot.distanceText,
            timeText: snapshot.timeText,
            progress: min(max(snapshot.progress, 0), 1),
            showsProgress: showsRouteProgress(snapshot.phaseKey),
            symbolName: snapshot.symbolName,
            modeSymbolName: snapshot.modeSymbolName,
            isWarning: snapshot.isWarning,
            primaryAction: snapshot.primaryAction,
            primaryTitle: snapshot.primaryTitle,
            secondaryAction: snapshot.secondaryAction,
            secondaryTitle: snapshot.secondaryTitle,
            tertiaryAction: snapshot.tertiaryAction,
            tertiaryTitle: snapshot.tertiaryTitle,
            phase: snapshot.phaseKey.rawValue,
            errorText: snapshot.errorText,
            retryCommand: snapshot.retryCommand,
            speedText: snapshot.speedText
        )
    }

    static func spotState(_ snapshot: SpotActivitySnapshot) -> RouteActivityAttributes.ContentState {
        RouteActivityAttributes.ContentState(
            kind: "spot",
            title: snapshot.placeName,
            statusText: snapshot.statusText,
            detailText: snapshot.caption,
            distanceText: "",
            timeText: "",
            progress: 0,
            showsProgress: false,
            symbolName: snapshot.symbolName,
            isWarning: snapshot.isWarning,
            primaryAction: snapshot.primaryAction,
            primaryTitle: snapshot.primaryTitle,
            secondaryAction: snapshot.secondaryAction,
            secondaryTitle: snapshot.secondaryTitle,
            tertiaryAction: snapshot.tertiaryAction,
            tertiaryTitle: snapshot.tertiaryTitle,
            phase: snapshot.status.rawValue,
            errorText: snapshot.errorText,
            retryCommand: snapshot.retryCommand
        )
    }
}
