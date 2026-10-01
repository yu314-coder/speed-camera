import SwiftUI
import MapKit
import Combine

final class CameraAnnotation: NSObject, MKAnnotation {
    let camera: CameraPoint
    var coordinate: CLLocationCoordinate2D { camera.coordinate.cl }
    var title: String? { camera.category.title }
    var subtitle: String? { camera.roadName }
    init(_ camera: CameraPoint) { self.camera = camera }
}

private enum CameraMarkerStyle {
    static let glyphs = Dictionary(uniqueKeysWithValues:CameraCategory.allCases.compactMap { category in
        UIImage(systemName:category.symbol).map { (category,$0) }
    })
    private static let images: NSCache<NSString,UIImage> = {
        let cache = NSCache<NSString,UIImage>(); cache.countLimit = 64; cache.totalCostLimit = 2_000_000; return cache
    }()
    static func badge(category: CameraCategory, endpoint: Bool = false, traits: UITraitCollection) -> UIImage {
        let key = "\(category.rawValue):\(endpoint):\(traits.userInterfaceStyle.rawValue):\(traits.displayScale)" as NSString
        if let image = images.object(forKey:key) { return image }
        let size = CGSize(width:34,height:34)
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1,traits.displayScale); format.opaque = false; format.preferredRange = .standard
        var rendered: UIImage?
        traits.performAsCurrent {
            rendered = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                let shape = UIBezierPath(roundedRect:CGRect(origin:.zero,size:size).insetBy(dx:1,dy:1),cornerRadius:size.height/2)
                (endpoint ? UIColor.systemGray : TaiwanMapView.Coordinator.color(category)).setFill(); shape.fill()
                UIColor.white.setStroke(); shape.lineWidth = 2; shape.stroke()
                let iconRect = CGRect(x:8,y:8,width:18,height:18)
                glyphs[category]?.withTintColor(.white,renderingMode:.alwaysOriginal).draw(in:iconRect)
            }
        }
        guard let image = rendered else { return UIImage() }
        let cost = image.cgImage.map { $0.bytesPerRow*$0.height } ?? Int(image.size.width*image.size.height*image.scale*image.scale*4)
        images.setObject(image,forKey:key,cost:cost)
        return image
    }
    static func releaseMemory() { images.removeAllObjects() }
}

final class CameraPinView: MKAnnotationView {
    private var category: CameraCategory?
    private var endpointOnly = false
    var glyphImage: UIImage? { category.flatMap { CameraMarkerStyle.glyphs[$0] } }
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation:annotation,reuseIdentifier:reuseIdentifier); setup()
    }
    required init?(coder: NSCoder) { super.init(coder:coder); setup() }
    private func setup() {
        frame = CGRect(x:0,y:0,width:34,height:34)
        collisionMode = .circle; canShowCallout = false; isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self,UITraitDisplayScale.self]) { (view:CameraPinView, _: UITraitCollection) in view.refreshImage() }
    }
    private func refreshImage() {
        guard let category else { return }
        image = CameraMarkerStyle.badge(category:category,endpoint:endpointOnly,traits:traitCollection)
    }
    func configure(_ camera: CameraPoint) {
        let endpoint = camera.category == .sectionSpeed && camera.sectionID == nil
        if category != camera.category || endpointOnly != endpoint {
            category = camera.category; endpointOnly = endpoint
            refreshImage()
            clusteringIdentifier = camera.category == .sectionSpeed ? nil : (camera.category == .cctv ? "cctv":"enforcement")
            displayPriority = camera.category == .sectionSpeed ? .required : .defaultHigh
        }
        alpha = camera.confidence == "A" || camera.category == .cctv ? 1 : 0.7
        accessibilityLabel = "\(camera.category.title), \(camera.roadName), \(camera.confidenceTitle)"
    }
}

final class CameraClusterView: MKAnnotationView {
    private let icon = UIImageView()
    private let countLabel = UILabel()
    private var representedCount = -1
    private var representsMixedTypes = false
    private(set) var representedCategory: CameraCategory = .speed
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation:annotation,reuseIdentifier:reuseIdentifier); setup()
    }
    required init?(coder: NSCoder) { super.init(coder:coder); setup() }
    private func setup() {
        frame = CGRect(x:0,y:0,width:66,height:36)
        layer.cornerRadius = 18; layer.borderWidth = 2; layer.borderColor = UIColor.white.cgColor
        icon.frame = CGRect(x:10,y:10,width:16,height:16); icon.contentMode = .scaleAspectFit; icon.tintColor = .white
        countLabel.frame = CGRect(x:29,y:0,width:30,height:36)
        countLabel.font = .monospacedDigitSystemFont(ofSize:15,weight:.bold)
        countLabel.textColor = .white; countLabel.textAlignment = .center; countLabel.adjustsFontSizeToFitWidth = true
        icon.isAccessibilityElement = false; icon.accessibilityElementsHidden = true
        countLabel.isAccessibilityElement = false; countLabel.accessibilityElementsHidden = true
        addSubview(icon); addSubview(countLabel)
        collisionMode = .rectangle; displayPriority = .defaultHigh; canShowCallout = false; isAccessibilityElement = true
        accessibilityTraits = .button
    }
    func configure(category: CameraCategory, count: Int, mixed: Bool = false) {
        if representedCount < 0 || representedCategory != category || representsMixedTypes != mixed {
            backgroundColor = mixed ? .systemOrange : TaiwanMapView.Coordinator.color(category)
            icon.image = mixed ? UIImage(systemName:"shield.fill") : CameraMarkerStyle.glyphs[category]
        }
        if representedCount != count { countLabel.text = count > 999 ? "999+" : String(count) }
        if representedCategory != category || representedCount != count || representsMixedTypes != mixed {
            accessibilityLabel = "\(mixed ? "Mixed enforcement" : category.title) cluster, \(count) cameras. Tap to zoom."
            representedCategory = category; representedCount = count; representsMixedTypes = mixed
        }
    }
}

final class DestinationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    init(coordinate: Coordinate, title: String?) { self.coordinate = coordinate.cl; self.title = title }
}

final class SectionCorridorRenderer: MKPolylineRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // A solid route underneath must not fill the blue dash gaps.
        context.saveGState()
        applyStrokeProperties(to:context,atZoomScale:zoomScale)
        context.setLineDash(phase:0,lengths:[])
        context.setLineWidth(lineWidth*1.6/max(zoomScale,0.000001))
        context.setStrokeColor(UIColor(white:1,alpha:0.92).cgColor)
        context.addPath(path); context.strokePath()
        context.restoreGState()
        super.draw(mapRect,zoomScale:zoomScale,in:context)
    }
}

final class UserDotView: MKAnnotationView {
    private let arrow = CAShapeLayer()
    private let dot = CAShapeLayer()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation:annotation,reuseIdentifier:reuseIdentifier)
        configure()
    }
    private func configure() {
        frame = CGRect(x:0,y:0,width:56,height:56)
        let triangle = UIBezierPath()
        triangle.move(to:CGPoint(x:28,y:1)); triangle.addLine(to:CGPoint(x:19,y:15)); triangle.addLine(to:CGPoint(x:37,y:15)); triangle.close()
        arrow.path = triangle.cgPath; arrow.fillColor = UIColor.systemBlue.cgColor
        arrow.frame = bounds; layer.addSublayer(arrow)
        dot.path = UIBezierPath(ovalIn:CGRect(x:18,y:18,width:20,height:20)).cgPath
        dot.fillColor = UIColor.systemBlue.cgColor; dot.strokeColor = UIColor.white.cgColor; dot.lineWidth = 3
        dot.shadowColor = UIColor.black.cgColor; dot.shadowOpacity = 0.18; dot.shadowRadius = 3; dot.shadowOffset = CGSize(width:0,height:2)
        layer.addSublayer(dot); displayPriority = .required; collisionMode = .circle; isAccessibilityElement = true
        accessibilityLabel = "Your GPS location"
    }
    required init?(coder: NSCoder) { super.init(coder:coder); configure() }
    func update(heading: Double?, mapHeading: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let heading = heading.flatMap { $0.isFinite && $0 >= 0 && $0 < 360 ? $0 : nil }
        arrow.isHidden = heading == nil || !mapHeading.isFinite
        if mapHeading.isFinite { arrow.setAffineTransform(CGAffineTransform(rotationAngle:CGFloat(((heading ?? 0)-mapHeading)*Double.pi/180))) }
        CATransaction.commit()
    }
}

struct TaiwanMapView: UIViewRepresentable, Equatable {
    static func releaseMarkerImages() { CameraMarkerStyle.releaseMemory() }
    let cameras: [CameraPoint]
    let zones: [SectionZone]
    let dataRevision: Int
    let routeOptions: [RouteOption]
    let selectedRouteID: UUID?
    let routeRevision: Int
    let destination: Coordinate?
    let destinationTitle: String?
    let navigating: Bool
    let location: LocationService
    let followRequest: Int
    let traffic: Bool
    let picking: Bool
    var searching = false
    var initialRegion: MKCoordinateRegion? = nil
    let onRegion: (MKCoordinateRegion) -> Void
    let onPick: (Coordinate) -> Void
    let onCamera: (CameraPoint) -> Void
    let onRoute: (UUID) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dataRevision == rhs.dataRevision && lhs.routeRevision == rhs.routeRevision &&
        lhs.selectedRouteID == rhs.selectedRouteID && lhs.destination == rhs.destination &&
        lhs.destinationTitle == rhs.destinationTitle && lhs.navigating == rhs.navigating &&
        lhs.followRequest == rhs.followRequest && lhs.traffic == rhs.traffic && lhs.picking == rhs.picking && lhs.searching == rhs.searching &&
        lhs.location === rhs.location
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .systemBackground
        let map = MKMapView(frame:.zero)
        map.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        host.addSubview(map)
        map.delegate = context.coordinator
        let configuration = MKStandardMapConfiguration(elevationStyle:.flat,emphasisStyle:.muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = traffic; map.preferredConfiguration = configuration
        map.showsUserLocation = true; map.showsCompass = false; map.showsScale = true
        map.isPitchEnabled = false
        map.setRegion(initialRegion ?? .init(center:.init(latitude:25.035,longitude:121.51),latitudinalMeters:20_000,longitudinalMeters:20_000),animated:false)
        map.register(CameraPinView.self,forAnnotationViewWithReuseIdentifier:"camera")
        map.register(CameraClusterView.self,forAnnotationViewWithReuseIdentifier:"cluster")
        map.register(UserDotView.self,forAnnotationViewWithReuseIdentifier:"gps")
        let hold = UILongPressGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.55; map.addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator; map.addGestureRecognizer(tap)
        context.coordinator.map = map
        context.coordinator.host = host
        map.accessibilityIdentifier = "traffic.map"
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let map = coordinator.map else { return }
        coordinator.setSearchPaused(searching)
        if let configuration = map.preferredConfiguration as? MKStandardMapConfiguration, configuration.showsTraffic != traffic {
            configuration.showsTraffic = traffic
            map.preferredConfiguration = configuration
        }
        if !searching && coordinator.dataRevision != dataRevision {
            coordinator.dataRevision = dataRevision
            coordinator.updateCameras(cameras)
            coordinator.updateSections(zones)
        }
        if coordinator.routeRevision != routeRevision {
            coordinator.routeRevision = routeRevision
            coordinator.updateRoutes()
        }
        if coordinator.lastDestination != destination {
            coordinator.lastDestination = destination
            if let pin = coordinator.destinationAnnotation { map.removeAnnotation(pin) }
            coordinator.destinationAnnotation = destination.map { DestinationAnnotation(coordinate:$0,title:destinationTitle) }
            if let pin = coordinator.destinationAnnotation { map.addAnnotation(pin) }
        }
        if !searching && coordinator.followRequest != followRequest {
            coordinator.followRequest = followRequest
            map.setUserTrackingMode(.followWithHeading,animated:true)
            if navigating, let center = Self.navigationCenter(mapLocation:map.userLocation.location,fallback:location.fix) {
                map.setCamera(.init(lookingAtCenter:center.cl,fromDistance:1100,pitch:0,heading:location.heading ?? 0),animated:true)
            }
        }
        coordinator.updateUserHeading()
    }
    static func navigationCenter(mapLocation: CLLocation?, fallback: LocationFix?, now: Date = Date()) -> Coordinate? {
        // MKUserLocation.coordinate can be (0, 0) before it has any system location.
        if let location = mapLocation, Coordinate(location.coordinate).valid,
           location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
           now.timeIntervalSince(location.timestamp) >= -1, now.timeIntervalSince(location.timestamp) <= 8 {
            return Coordinate(location.coordinate)
        }
        if let fallback, fallback.coordinate.valid, fallback.accuracy.isFinite,
           fallback.accuracy >= 0, fallback.accuracy <= 100, fallback.isFresh(maxAge:8,now:now) {
            return fallback.coordinate
        }
        return nil
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.releaseMap() }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: TaiwanMapView
        var map: MKMapView?
        weak var host: UIView?
        var dataRevision = -1, routeRevision = -1, followRequest = 0
        var lastDestination: Coordinate?
        var destinationAnnotation: DestinationAnnotation?
        private var annotations: [String:CameraAnnotation] = [:]
        private var sections: [String:MKPolyline] = [:]
        private var routes: [UUID:MKPolyline] = [:]
        private var fittedDestination: Coordinate?
        private var centeredOnUser = false
        private var suppressSelectionUntil = Date.distantPast
        private var headingSubscription: AnyCancellable?
        private var latestHeading: Double?
        private var routeHitTest: Task<Void,Never>?
        private var hitGeneration = 0
        private var searchPaused = false
        private var savedTracking: MKUserTrackingMode = .none
        func setSearchPaused(_ paused: Bool) {
            guard let map, searchPaused != paused else { return }
            searchPaused = paused
            map.isHidden = paused
            if paused {
                savedTracking = map.userTrackingMode
                map.setUserTrackingMode(.none,animated:false)
                map.removeFromSuperview()
            } else {
                if let host { map.frame = host.bounds; host.addSubview(map) }
                if parent.destination == nil, !parent.picking, map.userTrackingMode == .none {
                    map.setUserTrackingMode(savedTracking,animated:false)
                }
            }
        }
        init(_ parent: TaiwanMapView) {
            self.parent = parent
            latestHeading = parent.location.heading
            centeredOnUser = parent.initialRegion != nil
            followRequest = parent.navigating ? parent.followRequest-1 : parent.followRequest
            super.init()
            // Compass updates rotate only the dot, not the SwiftUI map/search/route hierarchy.
            headingSubscription = parent.location.$heading.removeDuplicates()
                .throttle(for:.milliseconds(50),scheduler:RunLoop.main,latest:true)
                .sink { [weak self] value in self?.latestHeading = value; self?.updateUserHeading() }
        }
        func cancel() { headingSubscription?.cancel(); routeHitTest?.cancel(); hitGeneration += 1 }
        func releaseMap() {
            cancel()
            map?.delegate = nil; map?.setUserTrackingMode(.none,animated:false); map?.showsUserLocation = false
            if let map {
                map.removeOverlays(map.overlays)
                map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
                map.removeFromSuperview()
            }
            annotations.removeAll(keepingCapacity:false); sections.removeAll(keepingCapacity:false); routes.removeAll(keepingCapacity:false)
            destinationAnnotation = nil; map = nil; host = nil
        }
        func updateCameras(_ cameras: [CameraPoint]) {
            guard let map else { return }
            let ids = Set(cameras.map(\.id))
            var removed = annotations.filter { !ids.contains($0.key) }
            for camera in cameras {
                if let old = annotations[camera.id], old.camera != camera { removed[camera.id] = old }
            }
            if !removed.isEmpty {
                map.removeAnnotations(Array(removed.values))
                for key in removed.keys { annotations.removeValue(forKey:key) }
            }
            var added: [CameraAnnotation] = []
            for camera in cameras where annotations[camera.id] == nil {
                let annotation = CameraAnnotation(camera); annotations[camera.id] = annotation; added.append(annotation)
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }
        func updateSections(_ zones: [SectionZone]) {
            guard let map else { return }
            let groups = SectionOverlayPlan.groups(zones)
            let ids = Set(groups.map(\.id))
            for (id,line) in Array(sections) where !ids.contains(id) { map.removeOverlay(line); sections.removeValue(forKey:id) }
            for group in groups where sections[group.id] == nil {
                var coordinates = group.path.coordinates.map(\.cl)
                let line = MKPolyline(coordinates:&coordinates,count:coordinates.count)
                line.title = "section"; line.subtitle = group.confidence
                sections[group.id] = line; map.addOverlay(line,level:.aboveLabels)
            }
        }
        func updateRoutes() {
            guard let map else { return }
            hitGeneration += 1; routeHitTest?.cancel()
            let ids = Set(parent.routeOptions.map(\.id))
            for (id,line) in Array(routes) where !ids.contains(id) { map.removeOverlay(line); routes.removeValue(forKey:id) }
            let options = parent.routeOptions.sorted { $0.id == parent.selectedRouteID ? false : $1.id == parent.selectedRouteID }
            for option in options {
                let selected = option.id == parent.selectedRouteID
                let line = routes[option.id] ?? option.polyline
                let title = selected ? "selected-route" : "alternate-route"
                if routes[option.id] == nil {
                    line.title = title; routes[option.id] = line; map.addOverlay(line,level:.aboveRoads)
                } else if line.title != title {
                    line.title = title
                    if let renderer = map.renderer(for:line) as? MKPolylineRenderer {
                        Self.styleRoute(renderer,selected:selected); renderer.setNeedsDisplay()
                    }
                }
            }
            // Reorder the retained overlay instead of destroying and rebuilding all route renderers.
            if let id = parent.selectedRouteID, let selected = routes[id],
               let selectedIndex = map.overlays.firstIndex(where:{ $0 === selected }),
               let lastIndex = map.overlays.lastIndex(where:{ overlay in routes.values.contains { $0 === overlay } }), selectedIndex != lastIndex {
                map.exchangeOverlay(at:selectedIndex,withOverlayAt:lastIndex)
            }
            if !parent.navigating, let selected = parent.routeOptions.first(where: { $0.id == parent.selectedRouteID }), fittedDestination != parent.destination {
                fittedDestination = parent.destination
                map.setVisibleMapRect(selected.polyline.boundingMapRect,
                    edgePadding:UIEdgeInsets(top:160,left:50,bottom:280,right:50),animated:true)
            }
            if parent.destination == nil { fittedDestination = nil }
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier:"gps",for:annotation) as? UserDotView ?? UserDotView(annotation:annotation,reuseIdentifier:"gps")
                view.update(heading:latestHeading,mapHeading:mapView.camera.heading); return view
            }
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier:"cluster",for:cluster) as? CameraClusterView ?? CameraClusterView(annotation:cluster,reuseIdentifier:"cluster")
                let categories = Set(cluster.memberAnnotations.compactMap { ($0 as? CameraAnnotation)?.camera.category })
                view.configure(category:(cluster.memberAnnotations.first as? CameraAnnotation)?.camera.category ?? .speed,
                    count:cluster.memberAnnotations.count,mixed:categories.count > 1)
                return view
            }
            if let point = annotation as? CameraAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier:"camera",for:point) as? CameraPinView ?? CameraPinView(annotation:point,reuseIdentifier:"camera")
                view.configure(point.camera)
                return view
            }
            if annotation is DestinationAnnotation {
                let view = MKMarkerAnnotationView(annotation:annotation,reuseIdentifier:nil)
                view.markerTintColor = .systemBlue; view.glyphImage = UIImage(systemName:"flag.fill"); view.displayPriority = .required
                return view
            }
            return nil
        }
        static func color(_ category: CameraCategory) -> UIColor {
            switch category {
            case .speed: return .systemOrange
            case .redLight: return .systemRed
            case .sectionSpeed: return .systemBlue
            case .multiViolation: return .systemIndigo
            case .cctv: return .systemBlue
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay:overlay) }
            let renderer = line.title == "section" ? SectionCorridorRenderer(polyline:line) : MKPolylineRenderer(polyline:line)
            if line.title == "section" {
                renderer.strokeColor = line.subtitle == "A" ? .systemBlue : UIColor.systemBlue.withAlphaComponent(0.55)
                renderer.lineWidth = 5; renderer.lineDashPattern = [12,10]
                renderer.lineCap = .butt; renderer.lineJoin = .round
                renderer.shouldRasterize = true
                return renderer
            } else {
                let selected = line.title == "selected-route"
                Self.styleRoute(renderer,selected:selected)
            }
            renderer.lineCap = .round; renderer.lineJoin = .round; return renderer
        }
        private static func styleRoute(_ renderer: MKPolylineRenderer, selected: Bool) {
            renderer.strokeColor = selected ? .systemBlue : UIColor.systemGray.withAlphaComponent(0.7)
            renderer.lineWidth = selected ? 7 : 5
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // Native annotation selection and our pin gesture can receive the same tap.
            if parent.picking || Date() < suppressSelectionUntil {
                if let annotation = view.annotation { mapView.deselectAnnotation(annotation,animated:false) }
                return
            }
            if let camera = view.annotation as? CameraAnnotation { parent.onCamera(camera.camera); mapView.deselectAnnotation(camera,animated:false) }
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.showAnnotations(cluster.memberAnnotations,animated:true)
                mapView.deselectAnnotation(cluster,animated:false)
            }
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { updateUserHeading(); parent.onRegion(mapView.region) }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { updateUserHeading() }
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            // MapKit can deliver a newer system fix before our manager; never invent its timestamp.
            if let fix = userLocation.location { parent.location.receiveLocations([fix]) }
            updateUserHeading()
            if !searchPaused, !centeredOnUser, parent.destination == nil, let location = userLocation.location,
               location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 15 {
                centeredOnUser = true
                mapView.setRegion(.init(center:location.coordinate,latitudinalMeters:8000,longitudinalMeters:8000),animated:true)
            }
        }
        func updateUserHeading() {
            guard !searchPaused, let map, let view = map.view(for:map.userLocation) as? UserDotView else { return }
            view.update(heading:latestHeading,mapHeading:map.camera.heading)
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map else { return }
            chooseDestination(Coordinate(map.convert(gesture.location(in:map),toCoordinateFrom:map)))
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map else { return }
            let coordinate = Coordinate(map.convert(gesture.location(in:map),toCoordinateFrom:map))
            if parent.picking { chooseDestination(coordinate); return }
            let mapWidth = max(1,map.bounds.width)
            let tolerance = max(20,map.visibleMapRect.size.width / Double(mapWidth) * MKMetersPerMapPointAtLatitude(coordinate.latitude) * 18)
            let paths = parent.routeOptions.map { ($0.id,$0.path) }
            hitGeneration += 1; let token = hitGeneration; routeHitTest?.cancel()
            routeHitTest = Task { [weak self] in
                let nearest = await Task.detached(priority:.userInitiated) {
                    paths.compactMap { id,path in path.project(coordinate).map { (id,$0.distance) } }.min { $0.1 < $1.1 }
                }.value
                guard !Task.isCancelled, let self, self.hitGeneration == token, !self.parent.picking, !self.parent.navigating else { return }
                if let nearest, nearest.1 < tolerance { self.parent.onRoute(nearest.0) }
            }
        }
        private func chooseDestination(_ coordinate: Coordinate) {
            hitGeneration += 1; routeHitTest?.cancel()
            suppressSelectionUntil = Date().addingTimeInterval(0.75)
            parent.onPick(coordinate)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { parent.picking || (!parent.navigating && parent.routeOptions.count > 1) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
