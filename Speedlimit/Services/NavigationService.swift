import Foundation
import MapKit
import Combine

extension MKPolyline {
    var roadPath: RoadPath {
        guard pointCount >= 2, pointCount <= 250_000 else { return RoadPath([]) }
        var values = [CLLocationCoordinate2D](repeating:.init(),count:pointCount)
        getCoordinates(&values,range:NSRange(location:0,length:pointCount))
        return RoadPath(values.map(Coordinate.init))
    }
}

struct RouteOption: Identifiable {
    let id: UUID
    let polyline: MKPolyline
    let path: RoadPath
    let instructions: [String]
    let stepEnds: [Double]
    let stepPaths: [RoadPath]
    let name: String
    let distance: Double
    let estimate: TimeInterval
    init(route: MKRoute) {
        id = UUID(); polyline = route.polyline; name = route.name; distance = route.distance; estimate = route.expectedTravelTime
        let geometry = route.polyline.roadPath; path = geometry
        let steps = route.steps.filter { !$0.instructions.isEmpty }
        instructions = steps.map(\.instructions)
        let paths = steps.map { $0.polyline.roadPath }; stepPaths = paths
        var last = 0.0
        stepEnds = zip(steps,paths).map { step,stepPath in
            let end = stepPath.coordinates.last.flatMap { geometry.project($0,nearAlong:nil)?.along } ?? (last+step.distance)
            last = max(last,end); return last
        }
    }
    init(name: String, coordinates: [Coordinate], instructions: [String], estimate: TimeInterval = 300) {
        id = UUID(); self.name = name; self.estimate = estimate
        let geometry = RoadPath(coordinates); path = geometry; distance = geometry.length
        var values = geometry.coordinates.map(\.cl)
        polyline = MKPolyline(coordinates:&values,count:values.count)
        self.instructions = instructions; stepEnds = instructions.enumerated().map { index,_ in geometry.length * Double(index+1) / Double(max(1,instructions.count)) }
        stepPaths = []
    }
}

enum NavigationPhase: Equatable { case idle, waitingForLocation, loading, preview, navigating, arrived, failed }

@MainActor
final class NavigationService: ObservableObject {
    typealias RouteProvider = (LocationFix,MKMapItem) async throws -> [RouteOption]
    struct TrafficEstimate { let time: TimeInterval; let distance: Double }
    typealias ETAProvider = (LocationFix,MKMapItem) async throws -> TrafficEstimate
    private let routeProvider: RouteProvider?
    private let etaProvider: ETAProvider?
    private let routeTimeout: Duration
    private let etaTimeout: Duration
    private let trafficLifetime: Duration
    private let routeDeadline = LoadingDeadline()
    private let etaDeadline = LoadingDeadline()
    private var trafficExpiry: Task<Void,Never>?
    init(routeProvider: RouteProvider? = nil, etaProvider: ETAProvider? = nil,
         routeTimeout: Duration = .seconds(20), etaTimeout: Duration = .seconds(12), trafficLifetime: Duration = .seconds(120)) {
        self.routeProvider = routeProvider; self.etaProvider = etaProvider
        self.routeTimeout = routeTimeout; self.etaTimeout = etaTimeout; self.trafficLifetime = trafficLifetime
    }
    @Published private(set) var phase: NavigationPhase = .idle
    @Published private(set) var destination: MKMapItem?
    @Published private(set) var routes: [RouteOption] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var error: String?
    @Published private(set) var trafficETA: TimeInterval?
    @Published private(set) var trafficDistance: Double?
    @Published private(set) var trafficFetched: Date?
    @Published private(set) var instruction = ""
    @Published private(set) var maneuverDistance = 0.0
    @Published private(set) var remainingDistance = 0.0
    @Published private(set) var rerouting = false
    @Published private(set) var revision = 0
    @Published private(set) var guidancePaused = false
    private var directions: MKDirections?
    private var etaDirections: MKDirections?
    private var routeTask: Task<Void,Never>?
    private var etaTask: Task<Void,Never>?
    private var generation = 0
    private var progress = NavigationProgress()
    private var lastReroute = Date.distantPast
    private var lastFix: LocationFix?
    private var lastETARequest = Date.distantPast
    var selected: RouteOption? { routes.first { $0.id == selectedID } }
    var isDriving: Bool { phase == .navigating }
    var routeRef: String { Geo.roadRef(instruction) }
    var currentStreet: String { routeRef.isEmpty ? Geo.streetKey(instruction) : "" }
    var currentStreetName: String { Geo.streetName(instruction) }
    var currentStepPath: RoadPath? {
        guard let selected, selected.stepPaths.indices.contains(progress.stepIndex) else { return nil }
        return selected.stepPaths[progress.stepIndex]
    }
    var coordinate: Coordinate? { destination.map { Coordinate($0.placemark.coordinate) } }
    var trafficLabel: String {
        guard let trafficETA, let trafficFetched, Date().timeIntervalSince(trafficFetched) < 120 else { return "Traffic ETA unavailable" }
        return "Apple traffic ETA · \(Self.minutes(trafficETA)) min"
    }
    static func minutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds >= 0 else { return 1 }
        return max(1,Int(min(1_000_000,ceil(seconds/60))))
    }
    func pick(_ item: MKMapItem, from fix: LocationFix?, waitForLocation: Bool = false) {
        cancelRequests(); destination = item; routes = []; selectedID = nil; trafficETA = nil; trafficDistance = nil
        trafficFetched = nil; error = nil; instruction = ""; progress = .init(); guidancePaused = false; revision += 1
        guard Coordinate(item.placemark.coordinate).valid else { phase = .failed; error = "Invalid destination coordinate."; return }
        guard let fix, fix.usableForRouting() else {
            if waitForLocation { phase = .waitingForLocation; return }
            phase = .failed; error = "Waiting for a usable current location. Enable GPS, then tap Retry."; return
        }
        calculate(from:fix,continuing:false)
    }
    @discardableResult func resumePendingRoute(from fix: LocationFix) -> Bool {
        guard phase == .waitingForLocation, fix.usableForRouting(maxAge:5) else { return false }
        calculate(from:fix,continuing:false); return true
    }
    func locationFailed(_ message: String) {
        guard phase == .waitingForLocation || phase == .preview else { return }
        error = message
        if phase == .waitingForLocation { phase = .failed }
    }
    func retry(from fix: LocationFix?) {
        guard let destination else { return }
        pick(destination,from:fix)
    }
    private func request(from fix: LocationFix, to destination: MKMapItem) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark:MKPlacemark(coordinate:fix.coordinate.cl))
        request.destination = destination; request.transportType = .automobile
        request.departureDate = Date(); request.requestsAlternateRoutes = true
        return request
    }
    private func calculate(from fix: LocationFix, continuing: Bool) {
        guard let destination else { return }
        cancelRequests(); let token = generation
        lastFix = fix; rerouting = continuing
        if !continuing { phase = .loading }
        error = nil
        let service = MKDirections(request:request(from:fix,to:destination)); directions = service
        let provider = routeProvider
        let deadlineToken = routeDeadline.begin(after:routeTimeout) { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancelRequests(); self.rerouting = false
            self.error = "Routes timed out. Check your connection and tap Retry."
            if !continuing { self.phase = .failed }
        }
        routeTask = Task { [weak self] in
            do {
                let received: [RouteOption]
                if let provider { received = try await provider(fix,destination) }
                else {
                    let response = try await service.calculate()
                    received = await Task.detached(priority:.userInitiated) { response.routes.map { RouteOption(route:$0) } }.value
                }
                guard let self, !Task.isCancelled, self.generation == token, self.routeDeadline.accepts(deadlineToken) else { return }
                let options = received.filter { $0.path.coordinates.count >= 2 && $0.path.length > 0 && $0.distance.isFinite && $0.estimate.isFinite && $0.estimate >= 0 }
                guard !options.isEmpty else { throw NSError(domain:"Navigation",code:1,userInfo:[NSLocalizedDescriptionKey:"Apple returned no usable driving routes."]) }
                self.routeDeadline.finish(deadlineToken); self.routeTask = nil; self.directions = nil
                self.routes = continuing ? [options[0]] : options; self.selectedID = options[0].id
                self.progress = .init(); self.rerouting = false; self.phase = continuing ? .navigating : .preview; self.revision += 1
                self.remainingDistance = options[0].path.length
                self.instruction = options[0].instructions.first ?? "Follow the route"
                if continuing, let current = self.lastFix { self.update(current) }
                self.refreshTraffic(from:fix,force:true)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.routeDeadline.accepts(deadlineToken) else { return }
                self.routeDeadline.finish(deadlineToken); self.routeTask = nil; self.directions = nil
                self.rerouting = false
                self.error = "Routes unavailable. Check your connection and retry."
                if !continuing { self.phase = .failed }
            }
        }
    }
    func select(_ id: UUID) {
        guard phase == .preview, selectedID != id, routes.contains(where: { $0.id == id }) else { return }
        selectedID = id; progress = .init(); revision += 1
    }
    @discardableResult func start(fix: LocationFix?) -> Bool {
        guard phase == .preview, let selected, selected.path.coordinates.count >= 2, let fix, fix.coordinate.valid,
              fix.accuracy.isFinite, fix.accuracy >= 0, fix.accuracy <= 100,
              fix.isFresh(maxAge:8) else {
            error = "A ready route and a fresh GPS fix are needed to start."; return false
        }
        routes = [selected]
        phase = .navigating; progress = .init(); instruction = selected.instructions.first ?? "Follow the route"
        remainingDistance = selected.path.length; revision += 1; update(fix); return true
    }
    func stop() {
        cancelRequests(); phase = .idle; destination = nil; routes = []; selectedID = nil
        instruction = ""; error = nil; trafficETA = nil; trafficDistance = nil; trafficFetched = nil
        progress = .init(); rerouting = false; guidancePaused = false; lastFix = nil; revision += 1
    }
    private func cancelRequests() {
        generation += 1; routeDeadline.cancel(); etaDeadline.cancel()
        directions?.cancel(); etaDirections?.cancel(); routeTask?.cancel(); etaTask?.cancel(); trafficExpiry?.cancel()
        directions = nil; etaDirections = nil; routeTask = nil; etaTask = nil
        trafficETA = nil; trafficDistance = nil; trafficFetched = nil
    }
    func update(_ fix: LocationFix) {
        guard fix.usableForRouting(maxAge:8), fix.accuracy <= 50 else {
            pauseForLocation(); return
        }
        lastFix = fix
        guard isDriving, let selected else { return }
        if guidancePaused { guidancePaused = false }
        guard let p = progress.update(fix:fix,path:selected.path,stepEnds:selected.stepEnds) else { return }
        let remaining = (progress.remaining / 5).rounded() * 5
        if remainingDistance != remaining { remainingDistance = remaining }
        let index = min(progress.stepIndex,max(0,selected.instructions.count-1))
        if !selected.instructions.isEmpty, instruction != selected.instructions[index] { instruction = selected.instructions[index] }
        let maneuver = selected.stepEnds.indices.contains(index) ? max(0,selected.stepEnds[index]-progress.along) : remainingDistance
        let displayDistance = (maneuver / 5).rounded() * 5
        if maneuverDistance != displayDistance { maneuverDistance = displayDistance }
        if p.distance < 25, remainingDistance < 35, Geo.distance(fix.coordinate,selected.path.coordinates.last ?? fix.coordinate) < 40 {
            phase = .arrived; instruction = "You have arrived"; revision += 1; return
        }
        if progress.offRouteFixes >= 3, !rerouting, Date().timeIntervalSince(lastReroute) > 25 {
            lastReroute = Date(); calculate(from:fix,continuing:true)
        }
        if !rerouting { refreshTraffic(from:fix,force:false) }
    }
    func pauseForLocation() {
        guard isDriving else { return }
        if !guidancePaused { guidancePaused = true }
        // Keep the route, but prevent an old-origin reroute/ETA response from resuming guidance.
        if rerouting { cancelRequests(); rerouting = false }
        else {
            etaDeadline.cancel(); etaDirections?.cancel(); etaTask?.cancel(); trafficExpiry?.cancel()
            etaDirections = nil; etaTask = nil; trafficETA = nil; trafficDistance = nil; trafficFetched = nil
        }
        lastFix = nil
    }
    func refreshTraffic(from fix: LocationFix, force: Bool) {
        guard routeProvider == nil || etaProvider != nil, fix.usableForRouting(maxAge:8), !guidancePaused, let destination,
              force || Date().timeIntervalSince(lastETARequest) > 90 else { return }
        lastETARequest = Date(); etaDirections?.cancel(); etaTask?.cancel(); let token = generation
        let request = request(from:fix,to:destination); request.requestsAlternateRoutes = false
        let service = MKDirections(request:request); etaDirections = service
        let provider = etaProvider
        let deadlineToken = etaDeadline.begin(after:etaTimeout) { [weak self] in
            guard let self, self.generation == token else { return }
            self.etaDirections?.cancel(); self.etaTask?.cancel(); self.etaTask = nil; self.etaDirections = nil
            self.trafficETA = nil; self.trafficDistance = nil; self.trafficFetched = nil
        }
        etaTask = Task { [weak self] in
            do {
                let result: TrafficEstimate
                if let provider { result = try await provider(fix,destination) }
                else {
                    let response = try await service.calculateETA()
                    result = .init(time:response.expectedTravelTime,distance:response.distance)
                }
                guard let self, !Task.isCancelled, self.generation == token, self.etaDeadline.accepts(deadlineToken) else { return }
                guard result.time.isFinite, result.time >= 0, result.distance.isFinite, result.distance >= 0 else { throw URLError(.cannotParseResponse) }
                self.etaDeadline.finish(deadlineToken); self.etaDirections = nil; self.etaTask = nil
                self.trafficETA = result.time; self.trafficDistance = result.distance; self.trafficFetched = Date()
                self.trafficExpiry?.cancel()
                self.trafficExpiry = Task { [weak self, trafficLifetime = self.trafficLifetime] in
                    do { try await Task.sleep(for:trafficLifetime) } catch { return }
                    self?.trafficETA = nil; self?.trafficDistance = nil; self?.trafficFetched = nil
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.etaDeadline.accepts(deadlineToken) else { return }
                self.etaDeadline.finish(deadlineToken); self.etaTask = nil; self.etaDirections = nil
                self.trafficETA = nil; self.trafficDistance = nil; self.trafficFetched = nil
            }
        }
    }
    func hasTrafficETA(_ option: RouteOption) -> Bool {
        guard let distance = trafficDistance, trafficETA != nil, let trafficFetched,
              Date().timeIntervalSince(trafficFetched) < 120 else { return false }
        // ETAResponse cannot target an alternate route; only a unique distance match is labelled.
        let matches = routes.filter { abs($0.distance-distance) <= max(100,distance*0.01) }
        return matches.count == 1 && matches[0].id == option.id
    }
}
