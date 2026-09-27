import MapKit
import UIKit

/// 画在当前选点坐标上的定位箭头，样式接近系统蓝点带朝向，而不是第二套定位标。
final class WalkHeadingHud: UIView {
    static let puckSize: CGFloat = 28

    var headingDegrees: Double = 0 {
        didSet { applyArrowTransform() }
    }

    private let arrow = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "前进方向"
        backgroundColor = .clear
        clipsToBounds = false

        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        arrow.image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        arrow.contentMode = .center
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 0.28
        arrow.layer.shadowRadius = 3
        arrow.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(arrow)
        applyArrowTransform()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arrow.frame = bounds
    }

    private func applyArrowTransform() {
        arrow.transform = CGAffineTransform(rotationAngle: headingDegrees * .pi / 180)
        accessibilityValue = PhysicalWalkHeadingLock.compassName(headingDegrees)
    }
}

extension MapViewRepresentable.Coordinator {
    func installWalkHeadingHud(on map: MKMapView) {
        let hud = WalkHeadingHud(
            frame: CGRect(x: 0, y: 0, width: WalkHeadingHud.puckSize, height: WalkHeadingHud.puckSize)
        )
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
