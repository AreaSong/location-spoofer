import MapKit
import UIKit

enum RouteMapOverlay {
    static func fit(_ coordinates: [CLLocationCoordinate2D], on map: MKMapView) {
        guard coordinates.count >= 2 else { return }
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        let pad = max(max(rect.size.width, rect.size.height) * 0.12, 80)
        rect = rect.insetBy(dx: -pad, dy: -pad)
        map.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 150, left: 36, bottom: 250, right: 36),
            animated: true
        )
    }

    static func pinImage(text: String, color: UIColor) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
}

final class RouteProgressAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

final class RoutePinAnnotation: NSObject, MKAnnotation {
    let role: RouteMapPin.Role
    var coordinate: CLLocationCoordinate2D

    init(pin: RouteMapPin) {
        role = pin.role
        coordinate = pin.coordinate
    }

    var glyph: String {
        switch role {
        case .start: return "起"
        case .end: return "终"
        case let .via(index): return "\(index)"
        }
    }

    var tintColor: UIColor {
        switch role {
        case .start: return .systemGreen
        case .end: return .systemRed
        case .via: return .systemOrange
        }
    }

    var reuseKey: String {
        switch role {
        case .start: return "start"
        case .end: return "end"
        case .via: return "via"
        }
    }
}
