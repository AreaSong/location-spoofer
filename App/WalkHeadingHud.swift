import MapKit
import UIKit

/// 锁定东南西北时只画前进箭头；跟随罗盘时画出东南西北环。
final class WalkHeadingHud: UIView {
    static let compactSize: CGFloat = 40
    static let compassSize: CGFloat = 108

    var headingDegrees: Double = 0 {
        didSet { applyArrowTransform() }
    }

    var showsCompassRing = false {
        didSet {
            guard oldValue != showsCompassRing else { return }
            applyChrome()
        }
    }

    private let arrow = UIImageView()
    private var cardinalLabels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "前进方向"
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        addCardinal("北")
        addCardinal("东")
        addCardinal("南")
        addCardinal("西")

        arrow.contentMode = .center
        addSubview(arrow)
        applyChrome()
        applyArrowTransform()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arrow.center = CGPoint(x: bounds.midX, y: bounds.midY)
        layoutCardinals()
    }

    var hudSize: CGFloat {
        showsCompassRing ? Self.compassSize : Self.compactSize
    }

    private func applyChrome() {
        let size = hudSize
        bounds = CGRect(origin: bounds.origin, size: CGSize(width: size, height: size))
        layer.cornerRadius = size / 2
        backgroundColor = UIColor.systemBackground.withAlphaComponent(showsCompassRing ? 0.28 : 0.72)
        layer.borderColor = UIColor.white.withAlphaComponent(showsCompassRing ? 0.55 : 0.7).cgColor
        cardinalLabels.forEach { $0.isHidden = !showsCompassRing }
        let pointSize: CGFloat = showsCompassRing ? 26 : 16
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        arrow.image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        arrow.bounds = CGRect(x: 0, y: 0, width: showsCompassRing ? 40 : 24, height: showsCompassRing ? 40 : 24)
        setNeedsLayout()
    }

    private func applyArrowTransform() {
        arrow.transform = CGAffineTransform(rotationAngle: headingDegrees * .pi / 180)
        accessibilityValue = PhysicalWalkHeadingLock.compassName(headingDegrees)
    }

    private func addCardinal(_ title: String) {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        label.isHidden = true
        addSubview(label)
        cardinalLabels.append(label)
    }

    private func layoutCardinals() {
        guard showsCompassRing, cardinalLabels.count == 4 else { return }
        let size = bounds.width
        let centers = [
            CGPoint(x: size / 2, y: 12),
            CGPoint(x: size - 12, y: size / 2),
            CGPoint(x: size / 2, y: size - 12),
            CGPoint(x: 12, y: size / 2)
        ]
        for (label, center) in zip(cardinalLabels, centers) {
            label.sizeToFit()
            label.center = center
        }
    }
}

extension MapViewRepresentable.Coordinator {
    func installWalkHeadingHud(on map: MKMapView) {
        let hud = WalkHeadingHud(frame: CGRect(x: 0, y: 0, width: WalkHeadingHud.compactSize, height: WalkHeadingHud.compactSize))
        hud.isHidden = true
        map.addSubview(hud)
        walkHeadingHud = hud
    }

    func updateWalkHeadingHud(degrees: Double?, visible: Bool, showsCompassRing: Bool, on map: MKMapView) {
        guard let hud = walkHeadingHud else { return }
        hud.showsCompassRing = showsCompassRing
        let size = hud.hudSize
        hud.bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
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
