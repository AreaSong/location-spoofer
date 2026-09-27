import MapKit
import UIKit

/// 地图北朝上时画在屏幕中心：固定东南西北环 + 可旋转前进箭头。
final class WalkHeadingHud: UIView {
    static let hudSize: CGFloat = 108

    var headingDegrees: Double = 0 {
        didSet { applyArrowTransform() }
    }

    private let arrow = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "前进方向"
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.28)
        layer.cornerRadius = Self.hudSize / 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        addCardinal("北", at: CGPoint(x: Self.hudSize / 2, y: 12))
        addCardinal("东", at: CGPoint(x: Self.hudSize - 12, y: Self.hudSize / 2))
        addCardinal("南", at: CGPoint(x: Self.hudSize / 2, y: Self.hudSize - 12))
        addCardinal("西", at: CGPoint(x: 12, y: Self.hudSize / 2))

        let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        arrow.image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        arrow.contentMode = .center
        arrow.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
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

    private func addCardinal(_ title: String, at center: CGPoint) {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        label.sizeToFit()
        label.center = center
        addSubview(label)
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
