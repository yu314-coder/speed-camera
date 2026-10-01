import Foundation
import MapKit
import Combine

struct AppPreferences: Codable, Equatable {
    var layers = Set(CameraCategory.allCases)
    var alertCategories: Set<CameraCategory> = [.speed,.redLight,.sectionSpeed,.multiViolation]
    var showLimited = true
    var traffic = true
    var backgroundMonitoring = true
    var notifications = true
}

struct DrivingResult: Sendable {
    let context: MatchedRoadContext?
    let alert: NearbyAlert?
    let zone: SectionZone?
    let sectionRemaining: Double?
}

actor DrivingProcessor {
    private var matcher = RoadMatcher()
    private var engine = AlertEngine()
    private var lastStreet = ""
    private var streetFixes = 0
    func reset() { matcher = .init(); lastStreet = ""; streetFixes = 0 }
    func evaluate(fix: LocationFix, roads: [RoadSegment], cameras: [CameraPoint], zones: [SectionZone],
                  route: RoadPath?, routeRef: String, street: String, streetName: String, stepPath: RoadPath?, driving: Bool) -> DrivingResult {
        guard !Task.isCancelled, fix.coordinate.valid, abs(fix.timestamp.timeIntervalSinceNow) < 8 else {
            return .init(context:nil,alert:nil,zone:nil,sectionRemaining:nil)
        }
        var context: MatchedRoadContext?
        if route == nil || !routeRef.isEmpty {
            context = matcher.match(fix,roads:roads,route:route,routeRef:routeRef)
        }
        if let stepPath, !street.isEmpty, routeRef.isEmpty, fix.canMatch, fix.accuracy <= 15,
           abs(fix.timestamp.timeIntervalSinceNow) < 8, let course = fix.course,
           let p = stepPath.project(fix.coordinate,bearing:course), p.distance <= 12, Geo.angle(course,p.bearing) < 30 {
            streetFixes = lastStreet == street ? streetFixes+1 : 1; lastStreet = street
            if streetFixes >= 3 {
                let segment = RoadSegment(id:"apple:"+street,name:streetName,ref:street,direction:"",speedLimit:nil,
                    path:stepPath,level:"unknown",elevation:nil,sourceID:"apple_route")
                context = .init(segment:segment,projection:p,routeLocked:true,confidence:"Apple route · elevation unknown")
            }
        } else { lastStreet = ""; streetFixes = 0 }
        let alert = driving ? engine.evaluate(fix:fix,context:context,cameras:cameras,zones:zones,route:route) : nil
        let zone = context.flatMap { context in
            zones.first { zone in
                guard zone.isAlertEnabled, zone.ref == context.segment.ref, let p = zone.path.project(fix.coordinate,bearing:fix.course),
                      p.distance <= 20, let course = fix.course, Geo.angle(course,p.bearing) < 40 else { return false }
                return p.along > 10 && p.along < zone.path.length - 10
            }
        }
        let remaining = zone.flatMap { zone in zone.path.project(fix.coordinate).map { max(0,zone.path.length-$0.along) } }
        return .init(context:context,alert:alert,zone:zone,sectionRemaining:remaining)
    }
}

enum DataLoadState: Equatable { case idle, loading, ready, failed }

@MainActor
final class AppModel: ObservableObject {
    typealias StoreLoader = () async throws -> TrafficStore
    let location: LocationService
    let navigation: NavigationService
    let search = SearchService()
    let notifications = NotificationService()
    @Published var preferences: AppPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data,forKey:"map.preferences.v1") }
            if preferences.layers != oldValue.layers || preferences.showLimited != oldValue.showLimited { refreshViewport() }
            updateMonitoring()
        }
    }
    @Published private(set) var cameras: [CameraPoint] = []
    @Published private(set) var zones: [SectionZone] = []
    @Published private(set) var summary = DatasetSummary()
    @Published private(set) var mapRevision = 0
    private(set) var layerCounts = MapLayerCounts()
    @Published private(set) var roadContext: MatchedRoadContext?
    @Published private(set) var sectionZone: SectionZone?
    @Published private(set) var sectionRemaining: Double?
    @Published private(set) var latestAlert: NearbyAlert?
    @Published private(set) var dataError: String?
    @Published private(set) var dataState: DataLoadState = .idle
    @Published private(set) var gpsStale = false
    @Published var automaticDataUpdates = GovernmentDataUpdater.isEnabled {
        didSet {
            UserDefaults.standard.set(automaticDataUpdates,forKey:GovernmentDataUpdater.enabledKey)
            BackgroundDataRefresh.schedule()
            if automaticDataUpdates { refreshGovernmentData() } else { updateTask?.cancel() }
        }
    }
    @Published private(set) var updatingGovernmentData = false
    @Published private(set) var governmentUpdateReport = GovernmentUpdateReport()
    @Published private(set) var governmentUpdateMessage: String?
    @Published var pickedCamera: CameraPoint?
    @Published var showingSettings = false
    @Published var showingRoad = false
    @Published var pickingDestination = false
    @Published private(set) var searchFocused = false
    @Published var followRequest = 0
    @Published var monitoring = false { didSet { updateMonitoring() } }
    @Published private(set) var startingNavigation = false
    private var store: TrafficStore?
    private let processor = DrivingProcessor()
    private var viewport = MapBounds(center:.init(25.04,121.51),radius:12_000)
    private(set) var mapRegion: MKCoordinateRegion?
    private var mapActive = true
    private var loadedBounds: MapBounds?
    private var loadedLayers: Set<CameraCategory> = []
    private var loadedLimited = true
    private var loadedCameraLimit = 600
    private var viewportTask: Task<Void,Never>?
    private var drivingTask: Task<Void,Never>?
    private var alertDismissal: Task<Void,Never>?
    private var viewportGeneration = 0
    private var lastProcessed = Date.distantPast
    private var pendingFix: LocationFix?
    private var started = false
    private var loadTask: Task<Void,Never>?
    private let loadDeadline = LoadingDeadline()
    private let loadTimeout: Duration
    private let storeLoader: StoreLoader
    private let usesDefaultStore: Bool
    private var updateTask: Task<Void,Never>?
    private var gpsDrain: Task<Void,Never>?
    private var gpsExpiry: Task<Void,Never>?
    private var latestFixTimestamp: Date?
    private var drivingGeneration = 0
    private(set) var lastEvaluatedFixTimestamp: Date?
    var isUITesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        return false
        #endif
    }
    var currentFix: LocationFix? {
        #if DEBUG
        if isUITesting {
            if ProcessInfo.processInfo.arguments.contains("--fixture-no-gps") { return nil }
            return .init(coordinate:.init(25.041,121.51),accuracy:5,speed:0,course:nil)
        }
        #endif
        return location.fix
    }
    init(storeLoader: StoreLoader? = nil, loadTimeout: Duration = .seconds(8), location: LocationService? = nil, navigation: NavigationService? = nil) {
        self.location = location ?? LocationService()
        self.loadTimeout = loadTimeout
        usesDefaultStore = storeLoader == nil
        if let storeLoader { self.storeLoader = storeLoader }
        else {
            #if DEBUG
            var failures = ProcessInfo.processInfo.arguments.contains("--fixture-load-failure") ? 1 : 0
            #endif
            self.storeLoader = {
                #if DEBUG
                if failures > 0 { failures -= 1; throw TrafficStoreError.sqlite("Test load failure. Tap Retry to recover.") }
                #endif
                return try await Task.detached(priority:.userInitiated) {
                    let bundle = try TrafficStore.bundledURL()
                    return try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:bundle))
                }.value
            }
        }
        if let navigation { self.navigation = navigation }
        else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--fixture-routes") {
                self.navigation = NavigationService(routeProvider: { fix,destination in
                    try await Task.sleep(for:.milliseconds(300))
                    let end = Coordinate(destination.placemark.coordinate)
                    let mid = Coordinate((fix.coordinate.latitude+end.latitude)/2,(fix.coordinate.longitude+end.longitude)/2)
                    return [RouteOption(name:"Test route A",coordinates:[fix.coordinate,mid,end],instructions:["Continue on test road","Arrive at test destination"]),
                            RouteOption(name:"Test route B",coordinates:[fix.coordinate,.init(mid.latitude+0.004,mid.longitude),end],instructions:["Follow alternate test road","Arrive at test destination"],estimate:420)]
                })
            } else { self.navigation = NavigationService() }
            #else
            self.navigation = NavigationService()
            #endif
        }
        preferences = UserDefaults.standard.data(forKey:"map.preferences.v1")
            .flatMap { try? JSONDecoder().decode(AppPreferences.self,from:$0) } ?? .init()
        #if DEBUG
        // Navigation UI tests avoid OS permission dialogs; production still requests consent.
        if isUITesting { preferences.notifications = false }
        #endif
        search.onPick = { [weak self] item in self?.pick(item) }
        self.location.onFix = { [weak self] fix in
            guard let self, !self.isUITesting else { return }
            self.receive(fix)
        }
        self.location.onAcquisitionFailure = { [weak self] message in
            guard let self else { return }
            if self.startingNavigation || self.navigation.phase == .waitingForLocation { self.navigation.locationFailed(message) }
            self.startingNavigation = false
        }
        self.location.onSignalLost = { [weak self] in
            guard let self, !self.isUITesting else { return }
            self.expireGPS()
        }
    }
    func start() async {
        guard !started else { return }; started = true
        UserDefaults.standard.set(monitoring || navigation.isDriving,forKey:BackgroundDataRefresh.drivingKey)
        reloadData()
        let unitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isUITesting && !unitTestHost && location.hasPermission { location.requestPermission() }
    }
    func reloadData() {
        loadTask?.cancel(); invalidateDriving()
        viewportGeneration += 1; viewportTask?.cancel()
        dataState = .loading; dataError = nil
        let token = loadDeadline.begin(after:loadTimeout) { [weak self] in
            guard let self else { return }
            self.loadTask?.cancel(); self.loadTask = nil; self.dataState = .failed
            self.dataError = "Camera data loading timed out. Tap Retry. The map and destination picker are still available."
        }
        let loader = storeLoader
        loadTask = Task { [weak self] in
            do {
                let store = try await loader()
                let summary = try await store.summary()
                guard let self, !Task.isCancelled, self.loadDeadline.accepts(token) else { return }
                self.loadDeadline.finish(token); self.loadTask = nil
                self.store = store; self.summary = summary; self.dataState = .ready; self.dataError = nil
                self.loadedBounds = nil; self.refreshViewport()
                #if DEBUG
                if self.isUITesting, ProcessInfo.processInfo.arguments.contains("--live-cctv-details") {
                    // Stable official ID/coordinate for the opt-in network smoke test, not a fabricated feed.
                    let cameras = try TrafficStore(url:TrafficStore.bundledURL())
                    let points = try await cameras.cameras(in:.init(center:.init(23.9882779,120.5081697),radius:100),categories:[.cctv])
                    self.pickedCamera = points.first { $0.cctvURL?.contains("T76-15K+000") == true }
                }
                #endif
                if let fix = self.currentFix { self.receive(fix) }
                self.refreshGovernmentData()
            } catch {
                guard let self, !Task.isCancelled, self.loadDeadline.accepts(token) else { return }
                self.loadDeadline.finish(token); self.loadTask = nil; self.dataState = .failed
                self.dataError = error.localizedDescription
            }
        }
    }
    func regionChanged(_ region: MKCoordinateRegion) {
        guard Coordinate(region.center).valid, region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else { return }
        mapRegion = region
        let latitude = min(180,max(0.001,region.span.latitudeDelta))
        let longitude = min(360,max(0.001,region.span.longitudeDelta))
        viewport = .init(south:region.center.latitude-latitude/2,north:region.center.latitude+latitude/2,
                         west:region.center.longitude-longitude/2,east:region.center.longitude+longitude/2)
        search.updateRegion(region); refreshViewport()
    }
    func speedReferences() async throws -> [SpeedLimitReference] {
        guard let store else {
            throw TrafficStoreError.sqlite(dataState == .loading ? "Offline data is still loading. Retry shortly." : "Offline data is not ready. Tap Retry on the map.")
        }
        return try await store.speedReferences()
    }
    private func refreshViewport() {
        // Even a cache hit invalidates a pending query for a different viewport.
        viewportGeneration += 1; let token = viewportGeneration
        viewportTask?.cancel(); viewportTask = nil
        guard !searchFocused, mapActive else { return }
        let cameraLimit = MapRenderBudget.cameraLimit(for:viewport)
        if let loadedBounds, loadedBounds.contains(viewport), loadedLayers == preferences.layers,
           loadedLimited == preferences.showLimited, loadedCameraLimit == cameraLimit,
           (loadedBounds.north-loadedBounds.south) < (viewport.north-viewport.south)*3 { return }
        let bounds = viewport.expanded(); let preferences = preferences
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(220))
            guard !Task.isCancelled, let self, self.dataState == .ready, let store = self.store else { return }
            do {
                let cameras = try await store.mapCameras(in:bounds,categories:preferences.layers,showLimited:preferences.showLimited,limit:cameraLimit)
                let zones = preferences.layers.contains(.sectionSpeed) ? try await store.sections(in:bounds,showLimited:preferences.showLimited) : []
                guard !Task.isCancelled, self.viewportGeneration == token else { return }
                self.loadedBounds = bounds; self.loadedLayers = preferences.layers; self.loadedLimited = preferences.showLimited
                self.loadedCameraLimit = cameraLimit
                self.dataError = nil
                if self.cameras != cameras || self.zones.map(\.id) != zones.map(\.id) {
                    self.layerCounts = MapLayerCounts(cameras:cameras,zones:zones)
                    self.cameras = cameras; self.zones = zones; self.mapRevision += 1
                }
            } catch {
                guard !Task.isCancelled, self.viewportGeneration == token else { return }
                self.dataError = error.localizedDescription
            }
        }
    }
    func pick(_ item: MKMapItem) {
        updateTask?.cancel()
        invalidateDriving()
        startingNavigation = false; location.cancelFreshLocation()
        search.dismiss(); pickingDestination = false; pickedCamera = nil
        navigation.pick(item,from:currentFix,waitForLocation:true); updateMonitoring()
        if navigation.phase == .waitingForLocation, !isUITesting { location.requestFreshLocation() }
    }
    func retryRoute() { if let destination = navigation.destination { pick(destination) } }
    func retryGPS() {
        #if DEBUG
        if isUITesting, ProcessInfo.processInfo.arguments.contains("--fixture-gps-outage") {
            receive(.init(coordinate:.init(25.041,121.51),accuracy:5,speed:0,course:nil)); return
        }
        #endif
        if navigation.phase == .failed, navigation.destination != nil { retryRoute() }
        else { location.requestFreshLocation() }
    }
    func pick(_ coordinate: Coordinate) {
        guard coordinate.valid else { return }
        let item = MKMapItem(placemark:MKPlacemark(coordinate:coordinate.cl))
        item.name = "Dropped pin · \(String(format:"%.4f",coordinate.latitude)), \(String(format:"%.4f",coordinate.longitude))"
        pick(item)
    }
    func startNavigation() {
        #if DEBUG
        if isUITesting { print("UI_NAV_START phase=\(navigation.phase) selected=\(navigation.selected != nil) GPS=\(currentFix != nil)") }
        #endif
        guard navigation.phase == .preview, !startingNavigation else { return }
        if currentFix?.usableForRouting(maxAge:8) != true {
            startingNavigation = true; location.requestFreshLocation()
            return
        }
        finishStartingNavigation()
        #if DEBUG
        if isUITesting { print("UI_NAV_RESULT phase=\(navigation.phase) error=\(navigation.error ?? "none")") }
        #endif
    }
    private func finishStartingNavigation() {
        if navigation.start(fix:currentFix) {
            invalidateDriving()
            startingNavigation = false; location.cancelFreshLocation()
            updateMonitoring(); followRequest += 1
            if preferences.notifications { Task { await notifications.request() } }
            #if DEBUG
            if isUITesting, ProcessInfo.processInfo.arguments.contains("--fixture-gps-outage") {
                receive(.init(coordinate:.init(25.041,121.51),timestamp:Date().addingTimeInterval(-7.5),accuracy:5,speed:0,course:nil))
            }
            #endif
        }
    }
    func stopNavigation() { invalidateDriving(); startingNavigation = false; location.cancelFreshLocation(); navigation.stop(); updateMonitoring() }
    func toggleMonitoring() {
        monitoring.toggle()
        if monitoring {
            location.requestPermission()
        }
    }
    func setSearchFocused(_ focused: Bool) {
        guard searchFocused != focused else { return }
        searchFocused = focused
        if focused { viewportGeneration += 1; viewportTask?.cancel(); viewportTask = nil }
        else { refreshViewport(); refreshGovernmentData() }
    }
    func setMapActive(_ active: Bool) {
        guard mapActive != active else { return }
        mapActive = active
        if active {
            refreshViewport()
            if navigation.isDriving { followRequest += 1 }
            refreshGovernmentData()
        } else {
            viewportGeneration += 1; viewportTask?.cancel(); viewportTask = nil
            loadedBounds = nil; layerCounts = MapLayerCounts(); cameras = []; zones = []; mapRevision += 1
            Task { [weak self] in await self?.releaseMemory(includeCameraFrames:false) }
        }
    }
    func releaseMemory(includeCameraFrames: Bool = true) async {
        TaiwanMapView.releaseMarkerImages()
        SnapshotDecoder.releaseMemory(); Geo.releaseCachedNames()
        await store?.releaseMemory()
        // Retain a small compressed frame cache in background so a sheet can restore without
        // violating the public feed's one-minute request cooldown. Warnings clear it too.
        if includeCameraFrames { updateTask?.cancel(); await CCTVService.shared.releaseMemory() }
    }
    func updateMonitoring() {
        // A changed preference/route must not publish an alert computed under the previous settings.
        invalidateDriving()
        let driving = monitoring || navigation.isDriving
        if UserDefaults.standard.bool(forKey:BackgroundDataRefresh.drivingKey) != driving {
            UserDefaults.standard.set(driving,forKey:BackgroundDataRefresh.drivingKey)
        }
        if driving { updateTask?.cancel() }
        location.setDriving(monitoring || navigation.isDriving,allowBackground:preferences.backgroundMonitoring)
        if !driving { refreshGovernmentData() }
    }
    func refreshGovernmentData(force: Bool = false) {
        guard usesDefaultStore, !isUITesting, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              automaticDataUpdates || force, dataState == .ready, updateTask == nil, mapActive else { return }
        guard !monitoring, !navigation.isDriving, !startingNavigation, !searchFocused,
              navigation.phase != .loading, navigation.phase != .waitingForLocation else {
            if force { governmentUpdateMessage = "Refresh resumes when navigation, monitoring and search are idle." }
            return
        }
        updatingGovernmentData = true; governmentUpdateMessage = nil
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.updatingGovernmentData = false; self.updateTask = nil }
            let report = await GovernmentDataUpdater.shared.refresh(force:force)
            guard !Task.isCancelled else { return }
            self.governmentUpdateReport = report
            self.governmentUpdateMessage = report.hasFailures ? "Some sources could not refresh. Their previous data is retained.":"Government feeds checked. The downloaded snapshot also works offline."
            guard !self.monitoring, !self.navigation.isDriving, !self.searchFocused else { return }
            do {
                let candidate = try await Task.detached(priority:.utility) {
                    let bundle = try TrafficStore.bundledURL()
                    return try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:bundle))
                }.value
                let summary = try await candidate.summary()
                guard !Task.isCancelled, summary.governmentUpdatedAt != self.summary.governmentUpdatedAt,
                      !self.monitoring, !self.navigation.isDriving else { return }
                self.invalidateDriving(); self.store = candidate; self.summary = summary
                self.loadedBounds = nil; self.refreshViewport()
            } catch { self.governmentUpdateMessage = "Update could not be opened. The current offline snapshot is retained." }
        }
    }
    func recenter() { location.requestFreshLocation(); followRequest += 1 }
    func clearAlert() { latestAlert = nil }
    private func invalidateDriving() {
        drivingGeneration += 1; drivingTask?.cancel(); gpsDrain?.cancel()
        drivingTask = nil; gpsDrain = nil; pendingFix = nil
        roadContext = nil; sectionZone = nil; sectionRemaining = nil; latestAlert = nil
        Task { await processor.reset() }
    }
    func receive(_ fix: LocationFix) {
        guard fix.coordinate.valid, fix.accuracy.isFinite, fix.accuracy >= 0,
              fix.isFresh(maxAge:8), latestFixTimestamp.map({ fix.timestamp > $0 }) ?? true else { return }
        latestFixTimestamp = fix.timestamp
        if gpsStale { gpsStale = false }
        scheduleGPSExpiry()
        if fix.usableForRouting(maxAge:5) {
            navigation.resumePendingRoute(from:fix)
            if startingNavigation, navigation.phase == .preview {
                startingNavigation = false
                if navigation.start(fix:fix) {
                    invalidateDriving(); updateMonitoring(); followRequest += 1
                    if preferences.notifications { Task { await notifications.request() } }
                }
            }
        }
        navigation.update(fix)
        if fix.accuracy > 25, roadContext != nil || sectionZone != nil || latestAlert != nil || drivingTask != nil {
            invalidateDriving()
        }
        if navigation.phase == .arrived { updateMonitoring() }
        pendingFix = fix; drainFix()
    }
    private func scheduleGPSExpiry() {
        guard gpsExpiry == nil else { return }
        // One sleeper follows the latest timestamp, instead of recreating a timer on each GPS callback.
        gpsExpiry = Task { [weak self] in
            while !Task.isCancelled {
                guard let timestamp = self?.latestFixTimestamp else { return }
                let remaining = 8-Date().timeIntervalSince(timestamp)
                if remaining <= 0 { self?.expireGPS(); return }
                do { try await Task.sleep(for:.seconds(remaining)) } catch { return }
            }
        }
    }
    private func expireGPS() {
        gpsExpiry?.cancel(); gpsExpiry = nil
        if !gpsStale { gpsStale = true; invalidateDriving() }
        navigation.pauseForLocation()
    }
    private func drainFix() {
        guard drivingTask == nil, gpsDrain == nil, let fix = pendingFix, dataState == .ready, store != nil else { return }
        let delay = 0.7-Date().timeIntervalSince(lastProcessed)
        if delay > 0 {
            gpsDrain = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                self?.gpsDrain = nil; self?.drainFix()
            }
            return
        }
        pendingFix = nil
        guard abs(fix.timestamp.timeIntervalSinceNow) <= 8 else { return }
        lastProcessed = Date()
        let route = navigation.isDriving ? navigation.selected?.path : nil
        let ref = navigation.routeRef
        let street = navigation.currentStreet
        let streetName = navigation.currentStreetName
        let stepPath = navigation.currentStepPath
        let driving = monitoring || navigation.isDriving
        let categories = preferences.alertCategories
        let routeRevision = navigation.revision
        let token = drivingGeneration
        drivingTask = Task { [weak self] in
            guard let self, let store = self.store else { return }
            defer {
                if self.drivingGeneration == token { self.drivingTask = nil; self.drainFix() }
            }
            do {
                let roads = try await store.roads(near:fix.coordinate)
                let cameras = try await store.cameras(in:.init(center:fix.coordinate,radius:1000),categories:categories)
                let zones = try await store.sections(in:.init(center:fix.coordinate,radius:1000))
                guard !Task.isCancelled, self.drivingGeneration == token, self.navigation.revision == routeRevision else { return }
                let result = await self.processor.evaluate(fix:fix,roads:roads,cameras:cameras,zones:zones,route:route,routeRef:ref,street:street,streetName:streetName,stepPath:stepPath,driving:driving)
                guard !Task.isCancelled, self.drivingGeneration == token, abs(fix.timestamp.timeIntervalSinceNow) <= 8,
                      self.navigation.revision == routeRevision else { return }
                self.lastEvaluatedFixTimestamp = fix.timestamp
                if self.roadContext?.segment.id != result.context?.segment.id || self.roadContext?.confidence != result.context?.confidence { self.roadContext = result.context }
                if self.sectionZone?.id != result.zone?.id { self.sectionZone = result.zone }
                let quantizedRemaining = result.sectionRemaining.map { ($0 / 10).rounded() * 10 }
                if self.sectionRemaining != quantizedRemaining { self.sectionRemaining = quantizedRemaining }
                if let alert = result.alert, self.monitoring || self.navigation.isDriving {
                    self.latestAlert = alert
                    if self.preferences.notifications { await self.notifications.post(alert) }
                    self.alertDismissal?.cancel()
                    self.alertDismissal = Task { [weak self] in
                        try? await Task.sleep(for:.seconds(10))
                        if !Task.isCancelled { self?.latestAlert = nil }
                    }
                }
            } catch {
                if !Task.isCancelled, self.drivingGeneration == token { self.dataError = error.localizedDescription }
            }
        }
    }
}
