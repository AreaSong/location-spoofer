import MapKit
import UIKit

/// 画在当前选点坐标上：蓝点表示位置，扇形表示朝向。
final class WalkHeadingHud: UIView {
    static let puckDiameter: CGFloat = 16
    static let fanRadius: CGFloat = 36
    static let fanDegrees: CGFloat = 70
    static var hudSize: CGFloat { fanRadius * 2 }

    var headingDegrees: Double = 0 {
        didSet { layoutFan() }
    }

    private let fanLayer = CAShapeLayer()
    private let puckView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "前进方向"
        backgroundColor = .clear
        clipsToBounds = false

        fanLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.32).cgColor
        fanLayer.strokeColor = nil
        layer.addSublayer(fanLayer)

        puckView.backgroundColor = .systemBlue
        puckView.layer.borderColor = UIColor.white.cgColor
        puckView.layer.borderWidth = 2
        puckView.layer.shadowColor = UIColor.black.cgColor
        puckView.layer.shadowOpacity = 0.28
        puckView.layer.shadowRadius = 2
        puckView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(puckView)
        layoutFan()
    }

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
        fanLayer.frame = bounds
        layoutFan()
    }

    private func layoutFan() {
        fanLayer.path = Self.fanPath(
            in: bounds,
            headingDegrees: headingDegrees,
            radius: Self.fanRadius,
            spreadDegrees: Self.fanDegrees
        )
        accessibilityValue = PhysicalWalkHeadingLock.compassName(headingDegrees)
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

extension MapViewRepresentable.Coordinator {
    func installWalkHeadingHud(on map: MKMapView) {
        let size = WalkHeadingHud.hudSize
        let hud = WalkHeadingHud(frame: CGRect(x: 0, y: 0, width: size, height: size))
        hud.isHidden = true
        map.addSubview(hud)
        walkHeadingHud = hud
    }

    func updateWalkHeadingHud(degrees: Double?, visible: Bool, on map: MKMapView) {
        guard let hud = walkHeadingHud else { return }
        hud.isHidden = !visible
        applyNativeUserLocationVisibility(hidden: visible, on: map)
        if visible {
            centerPin?.isHidden = true
            if let degrees {
                hud.headingDegrees = degrees
            }
            positionWalkHeadingHud(on: map)
        } else {
            centerPin?.isHidden = parent.playbackClock?.markerCoordinate != nil
        }
    }

    func positionWalkHeadingHud(on map: MKMapView) {
        guard let hud = walkHeadingHud, !hud.isHidden else { return }
        hud.center = map.convert(map.centerCoordinate, toPointTo: map)
    }

    func applyNativeUserLocationVisibility(hidden: Bool, on map: MKMapView) {
        map.view(for: map.userLocation)?.isHidden = hidden
    }
}
