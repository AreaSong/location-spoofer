import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

enum MapZoomMath {
    private static let minimumDelta = 0.000_05
    private static let maximumLatitudeDelta = 170.0
    private static let maximumLongitudeDelta = 360.0

    static func scaledSpan(_ span: MKCoordinateSpan, factor: Double) -> MKCoordinateSpan {
        guard factor.isFinite, factor > 0 else { return span }
        return MKCoordinateSpan(
            latitudeDelta: min(max(span.latitudeDelta * factor, minimumDelta), maximumLatitudeDelta),
            longitudeDelta: min(max(span.longitudeDelta * factor, minimumDelta), maximumLongitudeDelta)
        )
    }

    static func viewportScaleLabel(distanceMeters: CLLocationDistance) -> String {
        let meters = max(0, distanceMeters)
        if meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        let kilometers = meters / 1_000
        if kilometers < 10 {
            return String(format: "%.1f km", kilometers)
        }
        return "\(Int(kilometers.rounded())) km"
    }
}

struct MapViewRepresentable: UIViewRepresentable {
    let selection: MapSelection
    let initialViewportMeters: CLLocationDistance
    let cameraCommand: MapCameraCommand?
    let onRealtimeLocationChanged: (CLLocation) -> Void
    let onUserCenterChanged: (CLLocationCoordinate2D, CLLocationDistance) -> Void
    let onViewportChanged: (CLLocationDistance) -> Void
    let onMapTap: (CLLocationCoordinate2D) -> Void
    let onUserZoomChanged: ((CLLocationDistance) -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var routePins: [RouteMapPin] = []
    var routeProgressCoordinate: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        let initialDistance = max(50, initialViewportMeters)
        RuntimeLogger.info("APP", "地图", "makeUIView", details: [
            "zoom": String(initialDistance),
            "初始坐标来源": String(describing: selection.source),
            "地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        map.setRegion(
            MKCoordinateRegion(
                center: selection.coordinate,
                latitudinalMeters: initialDistance,
                longitudinalMeters: initialDistance
            ),
            animated: false
        )

        // Center pin — positioned relative to geographic center, not Auto Layout
        let pinSize: CGFloat = 38
        let sizeCfg = UIImage.SymbolConfiguration(pointSize: pinSize, weight: .semibold)
        let paletteCfg = UIImage.SymbolConfiguration(paletteColors: [.white, .red])
        let pinImage = UIImage(systemName: "mappin",
                               withConfiguration: sizeCfg.applying(paletteCfg))
        let pin = UIImageView(image: pinImage)
        pin.frame = CGRect(x: 0, y: 0, width: pinSize, height: pinSize)
        pin.isUserInteractionEnabled = false
        pin.layer.shadowColor = UIColor.black.cgColor
        pin.layer.shadowOpacity = 0.28
        pin.layer.shadowRadius = 5
        pin.layer.shadowOffset = CGSize(width: 0, height: 3)
        map.addSubview(pin)
        context.coordinator.centerPin = pin

        // Zoom controls — UIKit subviews inside MKMapView, move with the map
        let zoomStack = UIStackView()
        zoomStack.axis = .vertical
        zoomStack.spacing = 0
        zoomStack.translatesAutoresizingMaskIntoConstraints = false
        zoomStack.alignment = .center
        zoomStack.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        zoomStack.layer.cornerRadius = 13
        zoomStack.layer.shadowColor = UIColor.black.cgColor
        zoomStack.layer.shadowOpacity = 0.18
        zoomStack.layer.shadowRadius = 7
        zoomStack.layer.shadowOffset = CGSize(width: 0, height: 3)

        let zoomInBtn = UIButton(type: .system)
        zoomInBtn.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        zoomInBtn.addTarget(context.coordinator, action: #selector(Coordinator.zoomInTapped), for: .touchUpInside)
        zoomInBtn.heightAnchor.constraint(equalToConstant: 52).isActive = true
        zoomInBtn.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let zoomLabel = UILabel()
        let roundedDesc = UIFont.systemFont(ofSize: 9, weight: .semibold).fontDescriptor.withDesign(.rounded)
        zoomLabel.font = roundedDesc.flatMap { UIFont(descriptor: $0, size: 9) } ?? .systemFont(ofSize: 9, weight: .semibold)
        zoomLabel.textColor = .secondaryLabel
        zoomLabel.textAlignment = .center
        zoomLabel.adjustsFontSizeToFitWidth = true
        zoomLabel.minimumScaleFactor = 0.7
        zoomLabel.text = MapZoomMath.viewportScaleLabel(distanceMeters: initialDistance)
        zoomLabel.heightAnchor.constraint(equalToConstant: 28).isActive = true
        context.coordinator.zoomLabel = zoomLabel

        let zoomOutBtn = UIButton(type: .system)
        zoomOutBtn.setImage(UIImage(systemName: "minus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        zoomOutBtn.addTarget(context.coordinator, action: #selector(Coordinator.zoomOutTapped), for: .touchUpInside)
        zoomOutBtn.heightAnchor.constraint(equalToConstant: 52).isActive = true
        zoomOutBtn.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let sep1 = UIView(); sep1.translatesAutoresizingMaskIntoConstraints = false
        sep1.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        sep1.backgroundColor = .separator
        sep1.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let sep2 = UIView(); sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        sep2.backgroundColor = .separator
        sep2.widthAnchor.constraint(equalToConstant: 28).isActive = true

        zoomStack.addArrangedSubview(zoomInBtn)
        zoomStack.addArrangedSubview(sep1)
        zoomStack.addArrangedSubview(zoomLabel)
        zoomStack.addArrangedSubview(sep2)
        zoomStack.addArrangedSubview(zoomOutBtn)
        map.addSubview(zoomStack)
        NSLayoutConstraint.activate([
            zoomStack.leadingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            zoomStack.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 130),
        ])

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        context.coordinator.setupKeyboardObservers()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.consume(cameraCommand, on: map)
        context.coordinator.updateRouteOverlay(routeCoordinates, on: map)
        context.coordinator.updateRoutePins(routePins, on: map)
        context.coordinator.updateRouteProgress(routeProgressCoordinate, on: map)
        map.showsUserLocation = routeProgressCoordinate == nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewRepresentable
        weak var map: MKMapView?

        private var lastConsumedCommandID: UInt64?
        private var activeCameraCommandID: UInt64?
        private var activeCommandIsZoom = false
        private var regionChangeWasUserDriven = false
        private var isPinchZoom = false
        weak var zoomLabel: UILabel?
        weak var centerPin: UIImageView?
        private let pinSize: CGFloat = 38
        // 蓝点实际大小从 MKUserLocationView 取，默认 20pt
        private var userDotDiameter: CGFloat = 20
        private var keyboardObserverTokens: [NSObjectProtocol] = []
        private var lastForwardedRealtimeTimestamp: Date?
        private var lastRouteCoordinates: [CLLocationCoordinate2D] = []
        private var lastRoutePins: [RouteMapPin] = []
        private var progressAnnotation: RouteProgressAnnotation?
        private var pinAnnotations: [RoutePinAnnotation] = []

        deinit {
            keyboardObserverTokens.forEach(NotificationCenter.default.removeObserver)
        }

        @objc func zoomInTapped() { parent.onZoomIn?() }
        @objc func zoomOutTapped() { parent.onZoomOut?() }

        init(parent: MapViewRepresentable) {
            self.parent = parent
        }

        private func updatePinPosition(on mapView: MKMapView) {
            guard let pin = centerPin else { return }
            let centerPt = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
            // pin 尖在底边，上移自身一半 + 蓝点半径对齐
            pin.center = CGPoint(
                x: centerPt.x,
                y: centerPt.y - pinSize / 2 + 5
            )
        }

        func setupKeyboardObservers() {
            guard keyboardObserverTokens.isEmpty else { return }
            let nc = NotificationCenter.default
            keyboardObserverTokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let map = self.map else { return }
                self.updatePinPosition(on: map)
            })
            keyboardObserverTokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let map = self.map else { return }
                self.updatePinPosition(on: map)
            })
        }

        func consume(_ command: MapCameraCommand?, on map: MKMapView) {
            guard let command, command.id != lastConsumedCommandID else { return }
            lastConsumedCommandID = command.id
            activeCameraCommandID = command.id
            activeCommandIsZoom = command.kind.isZoom
            regionChangeWasUserDriven = false
            map.userTrackingMode = .none

            switch command.kind {
            case let .focus(coordinate, _):
                // 保持当前 span 不变，避免正方形 region 在竖屏 inflate
                let region = MKCoordinateRegion(center: coordinate, span: map.region.span)
                map.setRegion(region, animated: true)
            case let .zoom(factor):
                let region = MKCoordinateRegion(
                    center: map.centerCoordinate,
                    span: MapZoomMath.scaledSpan(map.region.span, factor: factor)
                )
                map.setRegion(region, animated: true)
            case let .fit(coordinates):
                RouteMapOverlay.fit(coordinates, on: map)
            }
        }

        private func routePinView(for pin: RoutePinAnnotation, on map: MKMapView) -> MKAnnotationView {
            let identifier = "route-pin-\(pin.reuseKey)"
            let view = map.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: identifier)
            view.annotation = pin
            view.canShowCallout = false
            view.displayPriority = .required
            view.image = RouteMapOverlay.pinImage(text: pin.glyph, color: pin.tintColor)
            view.centerOffset = CGPoint(x: 0, y: -11)
            return view
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map else { return }
            let point = gesture.location(in: map)
            parent.onMapTap(map.convert(point, toCoordinateFrom: map))
        }

        func updateRouteOverlay(_ coordinates: [CLLocationCoordinate2D], on map: MKMapView) {
            if coordinates.count == lastRouteCoordinates.count,
               zip(coordinates, lastRouteCoordinates).allSatisfy({
                   $0.latitude == $1.latitude && $0.longitude == $1.longitude
               }) {
                return
            }
            lastRouteCoordinates = coordinates
            map.removeOverlays(map.overlays.filter { $0 is MKPolyline })
            guard coordinates.count >= 2 else { return }
            var points = coordinates
            let polyline = MKPolyline(coordinates: &points, count: points.count)
            map.addOverlay(polyline)
        }

        func updateRoutePins(_ pins: [RouteMapPin], on map: MKMapView) {
            if pins == lastRoutePins { return }
            lastRoutePins = pins
            if !pinAnnotations.isEmpty {
                map.removeAnnotations(pinAnnotations)
            }
            pinAnnotations = pins.map { RoutePinAnnotation(pin: $0) }
            if !pinAnnotations.isEmpty {
                map.addAnnotations(pinAnnotations)
            }
        }

        func updateRouteProgress(_ coordinate: CLLocationCoordinate2D?, on map: MKMapView) {
            centerPin?.isHidden = coordinate != nil
            guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else {
                if let progressAnnotation {
                    map.removeAnnotation(progressAnnotation)
                    self.progressAnnotation = nil
                }
                return
            }
            if let progressAnnotation {
                progressAnnotation.coordinate = coordinate
                return
            }
            let annotation = RouteProgressAnnotation(coordinate: coordinate)
            progressAnnotation = annotation
            map.addAnnotation(annotation)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if let pin = annotation as? RoutePinAnnotation {
                return routePinView(for: pin, on: mapView)
            }
            guard annotation is RouteProgressAnnotation else { return nil }
            let identifier = "route-progress"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
            view.image = UIImage(systemName: "location.fill", withConfiguration: config)?
                .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            view.centerOffset = CGPoint(x: 0, y: 0)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            renderer.lineWidth = 4
            return renderer
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views where view.annotation is MKUserLocation {
                // 取蓝点实际大小，隐藏精度圈
                userDotDiameter = view.bounds.width
                for sub in view.subviews where sub.bounds.width > userDotDiameter + 4 {
                    sub.isHidden = true
                }
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let location = visibleUserLocationSample(userLocation) else {
                RuntimeLogger.warning("APP", "实时定位", "MapKit 蓝点更新但 location 为空", details: [
                    "来源": "MKMapView.didUpdate"
                ])
                return
            }
            guard CLLocationCoordinate2DIsValid(location.coordinate) else {
                RealtimeLocationTrace.log("拒绝 MapKit 蓝点样本：坐标无效", location: location, details: [
                    "来源": "MKMapView.didUpdate"
                ], level: .warning)
                return
            }
            guard location.horizontalAccuracy >= 0 else {
                RealtimeLocationTrace.log("拒绝 MapKit 蓝点样本：水平精度无效", location: location, details: [
                    "来源": "MKMapView.didUpdate"
                ], level: .warning)
                return
            }
            forwardRealtimeLocation(location)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let activeRecognizers = ([mapView as UIView] + mapView.subviews)
                .compactMap(\.gestureRecognizers)
                .flatMap { $0 }
                .filter { recognizer in
                    recognizer.state == .began || recognizer.state == .changed
                }
            let hasActiveGesture = !activeRecognizers.isEmpty

            // Pinching updates the viewport/name granularity only. MapKit can
            // keep its pan recognizer active during a pinch, so only a pure pan
            // is allowed to replace the selected center coordinate.
            let hasActivePan = activeRecognizers.contains { $0 is UIPanGestureRecognizer }
            let hasActivePinch = activeRecognizers.contains { $0 is UIPinchGestureRecognizer }
            regionChangeWasUserDriven = hasActivePan && !hasActivePinch
            isPinchZoom = hasActivePinch
            if hasActiveGesture {
                activeCameraCommandID = nil
                activeCommandIsZoom = false
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let distance = visibleVerticalDistance(in: mapView)
            parent.onViewportChanged(distance)
            zoomLabel?.text = MapZoomMath.viewportScaleLabel(distanceMeters: distance)
            updatePinPosition(on: mapView)
            // 同步蓝点坐标（避免 delegate 更新不及时导致 mapState.realtimeLocation 为 nil）
            if let ul = visibleUserLocationSample(mapView.userLocation),
               CLLocationCoordinate2DIsValid(ul.coordinate), ul.horizontalAccuracy >= 0 {
                if lastForwardedRealtimeTimestamp.map({ ul.timestamp > $0 }) ?? true {
                    forwardRealtimeLocation(ul)
                }
            }

            let userZoomed: Bool
            if activeCameraCommandID != nil {
                userZoomed = activeCommandIsZoom
                activeCameraCommandID = nil
                activeCommandIsZoom = false
            } else if isPinchZoom {
                userZoomed = true
                isPinchZoom = false
            } else {
                userZoomed = false
            }

            if userZoomed {
                parent.onUserZoomChanged?(distance)
            } else if regionChangeWasUserDriven {
                parent.onUserCenterChanged(mapView.centerCoordinate, distance)
            }

            regionChangeWasUserDriven = false
        }

        private func forwardRealtimeLocation(_ location: CLLocation) {
            lastForwardedRealtimeTimestamp = location.timestamp
            parent.onRealtimeLocationChanged(location)
        }

        /// `MKUserLocation.coordinate` is the coordinate of the blue-point
        /// annotation in the current map representation. Keep the native
        /// accuracy/timestamp metadata, but do not replace it with the raw
        /// Core Location coordinate carried by `location.coordinate`.
        private func visibleUserLocationSample(_ userLocation: MKUserLocation) -> CLLocation? {
            guard let native = userLocation.location else { return nil }
            return CLLocation(
                coordinate: userLocation.coordinate,
                altitude: native.altitude,
                horizontalAccuracy: native.horizontalAccuracy,
                verticalAccuracy: native.verticalAccuracy,
                course: native.course,
                speed: native.speed,
                timestamp: native.timestamp
            )
        }

        private func visibleVerticalDistance(in map: MKMapView) -> CLLocationDistance {
            let centerX = map.bounds.midX
            let north = map.convert(CGPoint(x: centerX, y: map.bounds.minY), toCoordinateFrom: map)
            let south = map.convert(CGPoint(x: centerX, y: map.bounds.maxY), toCoordinateFrom: map)
            let northLocation = CLLocation(latitude: north.latitude, longitude: north.longitude)
            let southLocation = CLLocation(latitude: south.latitude, longitude: south.longitude)
            let measured = northLocation.distance(from: southLocation)
            return measured.isFinite && measured > 0 ? measured : 1_000
        }
    }
}
