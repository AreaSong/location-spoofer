import MapKit
import UIKit

/// 地图北朝上时画在选点中心的前进箭头。东南西北在底卡里设置，这里只提示当前朝向。
final class WalkHeadingHud: UIView {
    static let hudSize: CGFloat = 40

    var headingDegrees: Double = 0 {
        didSet { applyArrowTransform() }
    }

    private let arrow = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "前进方向"
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.72)
        layer.cornerRadius = Self.hudSize / 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        arrow.image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        arrow.contentMode = .center
        arrow.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        addSubview(arrow)
        applyArrowTransform()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arrow.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func applyArrowTransform() {
        arrow.transform = CGAffineTransform(rotationAngle: headingDegrees * .pi / 180)
        accessibilityValue = PhysicalWalkHeadingLock.compassName(headingDegrees)
    }
}

extension MapViewRepresentable.Coordinator {
    func installWalkHeadingHud(on map: MKMapView) {
        let hud = WalkHeadingHud(frame: CGRect(x: 0, y: 0, width: WalkHeadingHud.hudSize, height: WalkHeadingHud.hudSize))
        hud.isHidden = true
        map.addSubview(hud)
        walkHeadingHud = hud
    }

    func updateWalkHeadingHud(degrees: Double?, visible: Bool, on map: MKMapView) {
        guard let hud = walkHeadingHud else { return }
        hud.isHidden = !visible
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
}
