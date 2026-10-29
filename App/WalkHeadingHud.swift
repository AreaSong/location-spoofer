import MapKit
import UIKit

/// 画在当前定位上：圆点表示人在这里，扇形表示朝向。红钉仍是地图中心选点。
/// 未开启模拟时画在系统蓝点上（蓝色）；开启后画在虚拟位置上（橙色并标注），与「系统定位」蓝点区分。
final class WalkHeadingHud: UIView {
    static let puckDiameter: CGFloat = 16
    static let fanRadius: CGFloat = 36
    static let fanDegrees: CGFloat = 70
    static var hudSize: CGFloat { fanRadius * 2 }

    /// 显示链路每帧都会调用；小于这个差值的角度变化肉眼不可见，不重建扇形路径。
    static let minimumVisibleHeadingChange: Double = 0.1

    var headingDegrees: Double = 0 {
        didSet {
            // 和上次画出的角度比，连续的小步变化累积起来仍会重画。
            guard abs(headingDegrees - drawnHeadingDegrees) >= Self.minimumVisibleHeadingChange else { return }
            layoutFan()
        }
    }
    private var drawnHeadingDegrees: Double = 0

    func update(geographicDegrees: Double?, screenDegrees: Double?) {
        let hidesFan = geographicDegrees == nil
        if fanLayer.isHidden != hidesFan {
            withoutImplicitAnimation { fanLayer.isHidden = hidesFan }
        }
        if let screenDegrees {
            headingDegrees = screenDegrees
        }
        // VoiceOver 仍描述地理方向，不能把屏幕相对角度读成方位。
        let label = PhysicalWalkHeadingLock.labeledDegrees(geographicDegrees)
        if accessibilityValue != label {
            accessibilityValue = label
        }
    }

    var representsVirtualTarget = false {
        didSet {
            guard representsVirtualTarget != oldValue else { return }
            applyStyle()
        }
    }

    /// 系统定位与虚拟目标在屏幕上重合时只画一个点：左半蓝、右半橙。
    var mergesSystemLocation = false {
        didSet {
            guard mergesSystemLocation != oldValue else { return }
            applyStyle()
        }
    }

    private let fanLayer = CAShapeLayer()
    private let puckView = UIView()
    private let systemHalfLayer = CAShapeLayer()
    private let targetLabel = MapDotLabel(text: "虚拟目标", color: .systemOrange)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "前进方向"
        backgroundColor = .clear
        clipsToBounds = false

        fanLayer.strokeColor = nil
        layer.addSublayer(fanLayer)

        puckView.layer.borderColor = UIColor.white.cgColor
        puckView.layer.borderWidth = 2
        puckView.layer.shadowColor = UIColor.black.cgColor
        puckView.layer.shadowOpacity = 0.28
        puckView.layer.shadowRadius = 2
        puckView.layer.shadowOffset = CGSize(width: 0, height: 1)
        systemHalfLayer.fillColor = UIColor.systemBlue.cgColor
        puckView.layer.addSublayer(systemHalfLayer)
        addSubview(puckView)
        addSubview(targetLabel)
        applyStyle()
        layoutFan()
    }

    private func applyStyle() {
        let color: UIColor = representsVirtualTarget ? .systemOrange : .systemBlue
        withoutImplicitAnimation {
            fanLayer.fillColor = color.withAlphaComponent(0.32).cgColor
        }
        puckView.backgroundColor = color
        let merged = representsVirtualTarget && mergesSystemLocation
        withoutImplicitAnimation { systemHalfLayer.isHidden = !merged }
        targetLabel.isHidden = !representsVirtualTarget
        targetLabel.attributedText = merged ? Self.mergedLabelText : NSAttributedString(
            string: "虚拟目标",
            attributes: [.foregroundColor: UIColor.systemOrange, .font: targetLabel.font as Any]
        )
        targetLabel.sizeToFit()
        setNeedsLayout()
        if merged {
            accessibilityLabel = "系统定位与虚拟目标重合，前进方向"
        } else {
            accessibilityLabel = representsVirtualTarget ? "虚拟目标，前进方向" : "前进方向"
        }
    }

    private static let mergedLabelText: NSAttributedString = {
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let text = NSMutableAttributedString(
            string: "系统定位",
            attributes: [.foregroundColor: UIColor.systemBlue, .font: font]
        )
        text.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: UIColor.secondaryLabel, .font: font]))
        text.append(NSAttributedString(string: "虚拟目标", attributes: [.foregroundColor: UIColor.systemOrange, .font: font]))
        return text
    }()

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let puck = Self.puckDiameter
        puckView.bounds = CGRect(x: 0, y: 0, width: puck, height: puck)
        puckView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        puckView.layer.cornerRadius = puck / 2
        // 左半圆：圆心在中点，从 90° 顺时针画到 270°。
        systemHalfLayer.frame = puckView.bounds
        systemHalfLayer.path = UIBezierPath(
            arcCenter: CGPoint(x: puck / 2, y: puck / 2),
            radius: puck / 2,
            startAngle: .pi / 2,
            endAngle: .pi * 3 / 2,
            clockwise: true
        ).cgPath
        targetLabel.center = CGPoint(
            x: bounds.midX,
            y: bounds.midY + puck / 2 + targetLabel.bounds.height / 2 + 4
        )
        fanLayer.frame = bounds
        layoutFan()
    }

    private func layoutFan() {
        let path = Self.fanPath(
            in: bounds,
            headingDegrees: headingDegrees,
            radius: Self.fanRadius,
            spreadDegrees: Self.fanDegrees
        )
        // 独立 CAShapeLayer 改 path 默认带 0.25 秒隐式动画；每帧改就会叠动画、扇形拖尾。
        withoutImplicitAnimation { fanLayer.path = path }
        drawnHeadingDegrees = headingDegrees
    }

    private func withoutImplicitAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    static func fanPath(
        in bounds: CGRect,
        headingDegrees: Double,
        radius: CGFloat,
        spreadDegrees: CGFloat
    ) -> CGPath {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let heading = CGFloat(headingDegrees)
        // 0° 朝北（屏幕上方），顺时针增大，和罗盘一致。
        let start = (heading - spreadDegrees / 2 - 90) * .pi / 180
        let end = (heading + spreadDegrees / 2 - 90) * .pi / 180
        let path = UIBezierPath()
        path.move(to: center)
        path.addLine(to: CGPoint(
            x: center.x + cos(start) * radius,
            y: center.y + sin(start) * radius
        ))
        path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        path.close()
        return path.cgPath
    }
}

final class WalkPuckDisplayLinkProxy: NSObject {
    weak var owner: MapViewRepresentable.Coordinator?

    @objc func tick() {
        owner?.tickWalkPuckPosition()
    }
}

extension MapViewRepresentable.Coordinator {
    func installWalkHeadingHud(on map: MKMapView) {
        self.map = map
        let size = WalkHeadingHud.hudSize
        let hud = WalkHeadingHud(frame: CGRect(x: 0, y: 0, width: size, height: size))
        hud.isHidden = true
        map.addSubview(hud)
        walkHeadingHud = hud
    }

    func startWalkPuckTracking() {
        guard walkPuckDisplayLink == nil else { return }
        let proxy = WalkPuckDisplayLinkProxy()
        proxy.owner = self
        walkPuckDisplayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(WalkPuckDisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        walkPuckDisplayLink = link
        link.isPaused = isSuspended || isAppInBackground
    }

    func stopWalkPuckTracking() {
        walkPuckDisplayLink?.invalidate()
        walkPuckDisplayLink = nil
        walkPuckDisplayLinkProxy = nil
    }

    @objc func tickWalkPuckPosition() {
        guard !isSuspended, let map else {
            if map == nil { stopWalkPuckTracking() }
            return
        }
        positionWalkHeadingHud(on: map)
    }

    func updateWalkHeadingHud(degrees: Double?, visible: Bool, on map: MKMapView) {
        attachWalkHeadingHud(to: map)
        guard let hud = walkHeadingHud else { return }
        hud.isHidden = !visible
        hud.representsVirtualTarget = !parent.walkPuckFollowsUserLocation || routeMarkerCoordinate != nil
        applyNativeUserLocationVisibility(hidden: walkHudCoversUserLocation, on: map)
        puckHeadingDegrees = degrees
        if puckCoordinate == nil {
            puckCoordinate = parent.walkPuckCoordinate
        }
        if visible {
            startWalkPuckTracking()
            positionWalkHeadingHud(on: map)
        } else {
            stopWalkPuckTracking()
        }
    }

    func positionWalkHeadingHud(on map: MKMapView) {
        attachWalkHeadingHud(to: map)
        guard let hud = walkHeadingHud, !hud.isHidden else { return }
        guard let coordinate = puckCoordinate ?? parent.walkPuckCoordinate else {
            hud.update(geographicDegrees: puckHeadingDegrees, screenDegrees: nil)
            hud.isHidden = true
            applyNativeUserLocationVisibility(hidden: false, on: map)
            stopWalkPuckTracking()
            return
        }
        let center = map.convert(coordinate, toPointTo: map)
        if hud.center != center {
            hud.center = center
        }
        syncMergedSystemLocation(hudCenter: center, on: map)
        let degrees = puckHeadingDegrees
        hud.update(geographicDegrees: degrees, screenDegrees: degrees.map {
            screenHeading($0, at: coordinate, on: map)
        })
    }

    /// 屏幕上两点距离小于圆点直径时合并显示，并隐藏系统蓝点；分开后恢复两个点。
    private func syncMergedSystemLocation(hudCenter: CGPoint, on map: MKMapView) {
        guard let hud = walkHeadingHud else { return }
        var merged = false
        if hud.representsVirtualTarget, map.userLocation.location != nil {
            let user = map.convert(map.userLocation.coordinate, toPointTo: map)
            merged = hypot(user.x - hudCenter.x, user.y - hudCenter.y) < WalkHeadingHud.puckDiameter
        }
        hud.mergesSystemLocation = merged
        let hidden = walkHudCoversUserLocation || merged
        if map.view(for: map.userLocation)?.isHidden != hidden {
            applyNativeUserLocationVisibility(hidden: hidden, on: map)
        }
    }

    private func attachWalkHeadingHud(to map: MKMapView) {
        self.map = map
        guard let hud = walkHeadingHud else { return }
        if hud.superview !== map {
            map.addSubview(hud)
        }
    }

    private func screenHeading(_ degrees: Double, at coordinate: CLLocationCoordinate2D, on map: MKMapView) -> Double {
        // 地图可旋转、倾斜；把地图平面的北/东向量投影到屏幕，不能直接画地理角。
        // 平面地图等价于 heading - camera.heading。这里只做显示投影，不改 WGS-84 位移。
        let origin = MKMapPoint(coordinate)
        let radians = degrees * .pi / 180
        let length = 10 / MKMetersPerMapPointAtLatitude(coordinate.latitude)
        let target = MKMapPoint(x: origin.x + sin(radians) * length, y: origin.y - cos(radians) * length)
        let start = map.convert(coordinate, toPointTo: map)
        let end = map.convert(target.coordinate, toPointTo: map)
        return PhysicalWalkHeadingLock.normalized(atan2(end.x - start.x, start.y - end.y) * 180 / .pi)
    }

    /// 扇形画在蓝点上时替代蓝点；画在虚拟点或路线点上时，蓝点作为「系统定位」保留。
    var walkHudCoversUserLocation: Bool {
        walkHeadingHud?.isHidden == false
            && parent.walkPuckFollowsUserLocation
            && routeMarkerCoordinate == nil
    }

    func applyNativeUserLocationVisibility(hidden: Bool, on map: MKMapView) {
        map.view(for: map.userLocation)?.isHidden = hidden
    }
}
