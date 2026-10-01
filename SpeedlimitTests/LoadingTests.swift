import XCTest
import MapKit
import SQLite3
#if SWIFT_PACKAGE
@testable import SpeedlimitCore
#else
import UIKit
@testable import Speedlimit
#endif

final class LoadingCoreTests: XCTestCase {
    func testMapMarkerBudgetAdaptsToZoomWithoutChangingNearRoadQueries() {
        let center = Coordinate(25.04,121.51)
        XCTAssertEqual(MapRenderBudget.cameraLimit(for:.init(center:center,radius:2000)),600)
        XCTAssertEqual(MapRenderBudget.cameraLimit(for:.init(center:center,radius:10_000)),360)
        XCTAssertEqual(MapRenderBudget.cameraLimit(for:.init(center:center,radius:50_000)),240)
    }
    func testByteBudgetEvictsLeastRecentlyUsedEntries() {
        var cache = BoundedCache<String,Int>(capacity:10,costLimit:10)
        cache.insert(1,for:"a",cost:4); cache.insert(2,for:"b",cost:4)
        XCTAssertEqual(cache.value(for:"a"),1)
        cache.insert(3,for:"c",cost:5)
        XCTAssertNil(cache.value(for:"b")); XCTAssertEqual(cache.value(for:"a"),1)
        XCTAssertEqual(cache.totalCost,9); XCTAssertEqual(cache.count,2)
    }
    func testReplacementRemovalAndOversizedCostsCannotGrowCache() {
        var cache = BoundedCache<String,Int>(capacity:3,costLimit:10)
        cache.insert(1,for:"a",cost:8); cache.insert(2,for:"a",cost:2)
        XCTAssertEqual(cache.totalCost,2)
        cache.insert(3,for:"large",cost:.max)
        XCTAssertNil(cache.value(for:"large")); XCTAssertEqual(cache.totalCost,2)
        cache.removeValue(for:"a"); XCTAssertEqual(cache.totalCost,0)
        cache.insert(4,for:"b",cost:3); cache.removeAll()
        XCTAssertEqual(cache.count,0); XCTAssertEqual(cache.totalCost,0)
    }
    func testLRUEvictsOldestWithoutDiscardingHotEntries() {
        var cache = BoundedCache<String,Int>(capacity:2)
        cache.insert(1,for:"a"); cache.insert(2,for:"b")
        XCTAssertEqual(cache.value(for:"a"),1)
        cache.insert(3,for:"c")
        XCTAssertNil(cache.value(for:"b")); XCTAssertEqual(cache.value(for:"a"),1)
        XCTAssertEqual(cache.count,2)
    }
    func testInvalidGPSAndGeometryAreRejectedWithoutBridging() {
        for coordinate in [Coordinate(.nan,121),Coordinate(25,.infinity),Coordinate(95,121)] {
            XCTAssertFalse(coordinate.valid)
            XCTAssertFalse(LocationFix(coordinate:coordinate).canMatch)
            XCTAssertTrue(RoadPath([.init(25,121),coordinate,.init(25.01,121)]).coordinates.isEmpty)
        }
        let path = RoadPath([.init(25,121),.init(25.01,121)])
        XCTAssertNil(path.project(.init(.nan,121)))
        XCTAssertNil(path.project(.init(25,121),nearAlong:.infinity))
        XCTAssertFalse(LocationFix(coordinate:.init(25,121),speed:20,course:.nan).canMatch)
    }
    @MainActor func testDeadlineInvalidatesLateCompletion() async throws {
        let deadline = LoadingDeadline(); var expired = false
        let token = deadline.begin(after:.milliseconds(20)) { expired = true }
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertTrue(expired); XCTAssertFalse(deadline.accepts(token))
    }
    @MainActor func testReplacementAndFinishCancelOldDeadline() async throws {
        let deadline = LoadingDeadline(); var expired = 0
        let old = deadline.begin(after:.milliseconds(20)) { expired += 1 }
        let current = deadline.begin(after:.milliseconds(100)) { expired += 1 }
        XCTAssertFalse(deadline.accepts(old)); XCTAssertTrue(deadline.accepts(current))
        deadline.finish(current)
        try await Task.sleep(for:.milliseconds(140))
        XCTAssertEqual(expired,0); XCTAssertFalse(deadline.accepts(current))
    }
}

final class LoadingStoreTests: XCTestCase {
    func testSectionGeometryCacheHitsAndCleanupKeepEveryVertexAndTrustField() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let bounds = MapBounds(south:21.8,north:25.5,west:119.8,east:122.1)
        let original = try await store.sections(in:bounds)
        XCTAssertEqual(original.count,38)
        let cold = await store.cacheUsage()
        for _ in 0..<3 {
            let cached = try await store.sections(in:bounds)
            XCTAssertEqual(cached.map(\.id),original.map(\.id))
            for (before,after) in zip(original,cached) {
                XCTAssertEqual(before.path.coordinates,after.path.coordinates)
                XCTAssertEqual(before.path.cumulative,after.path.cumulative)
                XCTAssertEqual(before.isAlertEnabled,after.isAlertEnabled)
                XCTAssertEqual(before.confidence,after.confidence)
                XCTAssertEqual(before.length,after.length)
            }
            let warm = await store.cacheUsage()
            XCTAssertEqual(warm.geometryBytes,cold.geometryBytes)
        }
        await store.releaseMemory()
        let restored = try await store.sections(in:bounds)
        for (before,after) in zip(original,restored) {
            XCTAssertEqual(before.path.coordinates,after.path.coordinates)
            XCTAssertEqual(before.path.cumulative,after.path.cumulative)
        }
        XCTAssertEqual(restored.count,original.count)
    }
    func testRoadCacheBudgetsAndPressureCleanupPreserveQueryResults() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let taipei = Coordinate(25.04,121.51)
        let original = try await store.roads(near:taipei)
        for coordinate in [taipei,.init(25.14,121.74),.init(24.82,121.02),.init(24.7,121.8),
                           .init(24.15,120.68),.init(23.97,121.6),.init(23.48,120.45),
                           .init(23.0,120.2),.init(22.63,120.3),.init(22.76,121.14)] {
            _ = try await store.roads(near:coordinate)
            let usage = await store.cacheUsage()
            XCTAssertLessThanOrEqual(usage.roadBytes,2_000_000)
            XCTAssertLessThanOrEqual(usage.geometryBytes,2_000_000)
            XCTAssertLessThanOrEqual(usage.statements,32)
        }
        await store.releaseMemory()
        let cleared = await store.cacheUsage()
        XCTAssertEqual(cleared.roadBytes,0); XCTAssertEqual(cleared.geometryBytes,0); XCTAssertEqual(cleared.statements,0)
        let restored = try await store.roads(near:taipei)
        XCTAssertEqual(restored.map(\.id),original.map(\.id))
        for (before,after) in zip(original,restored) {
            XCTAssertEqual(before.path.coordinates,after.path.coordinates)
            XCTAssertEqual(before.speedLimit,after.speedLimit)
        }
    }
    func temporarySnapshot(_ sql: String) throws -> URL {
        let directory = ProcessInfo.processInfo.environment["SPEED_CAMERA_TEST_TMPDIR"].map {
            URL(fileURLWithPath:$0,isDirectory:true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("SpeedlimitTests",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url = directory.appendingPathComponent(UUID().uuidString+".db")
        try FileManager.default.copyItem(at:TrafficStore.bundledURL(),to:url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path,&db) == SQLITE_OK else { throw TrafficStoreError.sqlite("Test setup failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw TrafficStoreError.sqlite("Test mutation failed") }
        return url
    }
    func testCorruptAndUnsupportedSnapshotsThrowRecoverableError() throws {
        let url = try temporarySnapshot("PRAGMA user_version=99")
        defer { try? FileManager.default.removeItem(at:url) }
        XCTAssertThrowsError(try TrafficStore(url:url))
        try Data("Not a SQLite snapshot".utf8).write(to:url)
        XCTAssertThrowsError(try TrafficStore(url:url))
    }
    func testMissingSchemaIsRejectedAtStartup() throws {
        let url = try temporarySnapshot("DROP TABLE section_zones")
        defer { try? FileManager.default.removeItem(at:url) }
        XCTAssertThrowsError(try TrafficStore(url:url))
    }
    func testOversizedOrInvalidGeometryIsSkipped() async throws {
        let url = try temporarySnapshot("UPDATE road_segments SET geometry_json='[[121,25],[121,95],[121,25.01]]'; UPDATE section_zones SET geometry_json=zeroblob(300000)")
        defer { try? FileManager.default.removeItem(at:url) }
        let store = try TrafficStore(url:url)
        let roads = try await store.roads(near:.init(25.04,121.46))
        let zones = try await store.sections(in:.init(center:.init(25.04,121.46),radius:20_000))
        XCTAssertTrue(roads.isEmpty); XCTAssertTrue(zones.isEmpty)
    }
    func testInvalidCoordinatesAndCancellationCannotCrashQueries() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let roads = try await store.roads(near:.init(.nan,.infinity))
        XCTAssertTrue(roads.isEmpty)
        let task = Task { () throws -> [RoadSegment] in
            try await Task.sleep(for:.seconds(1))
            return try await store.roads(near:.init(25,121))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled query must not run") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

#if !SWIFT_PACKAGE
@MainActor
final class LoadingAppTests: XCTestCase {
    var fix: LocationFix { .init(coordinate:.init(25.04,121.51),speed:10,course:0) }
    func place(_ latitude: Double = 25.06) -> MKMapItem { MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:latitude,longitude:121.51))) }
    func route() -> RouteOption { .init(name:"Fixture",coordinates:[.init(25.04,121.51),.init(25.06,121.51)],instructions:["Continue north"]) }
    func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(condition(),"Condition did not settle before deadline")
    }
    // Simulates a server callback that arrives even after its request is cancelled.
    func lateResponse() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { continuation.resume() }
        }
    }
    func testDismissedSearchCannotReplaceDroppedPin() async throws {
        let service = SearchService(provider:{ _ in await self.lateResponse(); return [self.place()] })
        var picks = 0; service.onPick = { _ in picks += 1 }
        service.query = "Taipei"; service.submit(); service.dismiss()
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertFalse(service.isSearching); XCTAssertTrue(service.results.isEmpty); XCTAssertEqual(picks,0)
    }
    func testSearchTimeoutIgnoresLateResultAndAllowsRetry() async throws {
        var requests = 0
        let service = SearchService(provider:{ _ in
            requests += 1
            if requests == 1 { await self.lateResponse() }
            return [self.place()]
        },timeout:.milliseconds(40))
        service.query = "Taipei"; service.submit()
        try await waitUntil { !service.isSearching }
        XCTAssertTrue(service.error?.contains("timed out") == true)
        service.submit(); try await waitUntil { !service.isSearching }
        XCTAssertEqual(service.results.count,1); XCTAssertNil(service.error)
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertEqual(service.results.count,1); XCTAssertNil(service.error)
    }
    func testNewSearchRejectsOldResultsAndOldSelection() async throws {
        var count = 0
        let service = SearchService(provider:{ _ in count += 1; return [self.place(Double(count)+25)] })
        service.query = "First"; service.submit(); try await waitUntil { !service.isSearching }
        let old = try XCTUnwrap(service.results.first)
        service.query = "Second"; service.textChanged()
        var picked = false; service.onPick = { _ in picked = true }; service.choose(old)
        XCTAssertFalse(picked); XCTAssertTrue(service.results.isEmpty)
        service.submit(); try await waitUntil { !service.isSearching }
        XCTAssertEqual(service.results.first?.item.placemark.coordinate.latitude,27)
        service.clear()
    }
    func testRouteDeadlineEndsSpinnerAndRetryWorks() async throws {
        var requests = 0
        let service = NavigationService(routeProvider:{ _,_ in
            requests += 1
            if requests == 1 { await self.lateResponse() }
            return [self.route()]
        },routeTimeout:.milliseconds(40))
        service.pick(place(),from:fix)
        try await waitUntil { service.phase == .failed }
        XCTAssertTrue(service.error?.contains("timed out") == true)
        service.retry(from:fix); try await waitUntil { service.phase == .preview }
        let id = service.selectedID
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertEqual(service.selectedID,id); XCTAssertNil(service.error)
    }
    func testCancelledRouteDoesNotReappear() async throws {
        let service = NavigationService(routeProvider:{ _,_ in await self.lateResponse(); return [self.route()] })
        service.pick(place(),from:fix); service.stop()
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertEqual(service.phase,.idle); XCTAssertTrue(service.routes.isEmpty)
    }
    func testNavigationReleasesAlternatesOnlyAfterStartingSelectedRoute() async throws {
        let service = NavigationService(routeProvider:{ _,_ in [self.route(),self.route()] })
        service.pick(place(),from:fix); try await waitUntil { service.phase == .preview }
        XCTAssertEqual(service.routes.count,2)
        let chosen = service.routes[1]; service.select(chosen.id)
        XCTAssertTrue(service.start(fix:fix))
        XCTAssertEqual(service.routes.count,1); XCTAssertEqual(service.selectedID,chosen.id)
        XCTAssertEqual(service.selected?.path.coordinates,chosen.path.coordinates)
        XCTAssertTrue(service.isDriving); service.stop()
    }
    func testMapBackgroundCleanupKeepsMonitoringRouteAndRestoresLayers() async throws {
        let manager = TestLocationManager()
        let location = LocationService(manager:manager,headingSupported:false)
        let navigation = NavigationService(routeProvider:{ _,_ in [self.route()] })
        let model = AppModel(location:location,navigation:navigation)
        let savedPreferences = model.preferences
        defer { model.preferences = savedPreferences }
        model.preferences.notifications = false; model.preferences.layers = Set(CameraCategory.allCases)
        await model.start(); try await waitUntil { !model.cameras.isEmpty }
        let region = MKCoordinateRegion(center:.init(latitude:22.63,longitude:120.3),latitudinalMeters:15_000,longitudinalMeters:15_000)
        model.regionChanged(region)
        navigation.pick(place(),from:fix); try await waitUntil { navigation.phase == .preview }
        XCTAssertTrue(navigation.start(fix:fix)); model.monitoring = true
        let selected = navigation.selectedID, stops = manager.stops
        model.setMapActive(false)
        XCTAssertTrue(model.cameras.isEmpty); XCTAssertTrue(model.zones.isEmpty)
        await model.releaseMemory()
        XCTAssertTrue(model.monitoring); XCTAssertTrue(navigation.isDriving)
        XCTAssertEqual(navigation.selectedID,selected); XCTAssertEqual(manager.stops,stops)
        XCTAssertEqual(model.mapRegion?.center.latitude,region.center.latitude)
        XCTAssertEqual(model.mapRegion?.center.longitude,region.center.longitude)
        model.setMapActive(true); try await waitUntil { !model.cameras.isEmpty }
        XCTAssertEqual(navigation.selectedID,selected)
        model.monitoring = false; model.stopNavigation(); location.setForeground(false)
    }
    func testRerouteTimeoutKeepsActiveRouteUsable() async throws {
        var calls = 0
        let service = NavigationService(routeProvider:{ _,_ in
            calls += 1
            if calls > 1 { await self.lateResponse() }
            return [self.route()]
        },routeTimeout:.milliseconds(40))
        service.pick(place(),from:fix); try await waitUntil { service.phase == .preview }
        XCTAssertTrue(service.start(fix:fix)); let id = service.selectedID
        let offRoute = LocationFix(coordinate:.init(25.045,121.515),speed:20,course:0)
        for _ in 0..<3 { service.update(offRoute) }
        XCTAssertTrue(service.rerouting)
        try await waitUntil { !service.rerouting }
        XCTAssertTrue(service.isDriving); XCTAssertEqual(service.selectedID,id)
        XCTAssertTrue(service.error?.contains("timed out") == true)
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertEqual(service.selectedID,id)
    }
    func testInvalidRouteAndLocationFailGracefully() async throws {
        let service = NavigationService(routeProvider:{ _,_ in [.init(name:"Invalid",coordinates:[],instructions:[])] })
        service.pick(place(),from:LocationFix(coordinate:.init(.nan,121)))
        XCTAssertEqual(service.phase,.failed)
        service.pick(place(),from:fix); try await waitUntil { service.phase == .failed }
        XCTAssertTrue(service.routes.isEmpty)
        XCTAssertEqual(NavigationService.minutes(.infinity),1)
        XCTAssertEqual(distanceText(.nan),"Unknown"); XCTAssertEqual(distanceText(.infinity),"Unknown")
    }
    func testTrafficDeadlineRejectsLateETAWithoutLosingRoute() async throws {
        let service = NavigationService(routeProvider:{ _,_ in [self.route()] },etaProvider:{ _,_ in
            await self.lateResponse(); return .init(time:300,distance:2000)
        },etaTimeout:.milliseconds(30))
        service.pick(place(),from:fix); try await waitUntil { service.phase == .preview }
        try await Task.sleep(for:.milliseconds(230))
        XCTAssertNil(service.trafficETA); XCTAssertEqual(service.phase,.preview)
        XCTAssertTrue(service.trafficLabel.contains("unavailable"))
    }
    func testTrafficEstimateExpiresRatherThanStayingFreshForever() async throws {
        let service = NavigationService(routeProvider:{ _,_ in [self.route()] },etaProvider:{ _,_ in
            .init(time:300,distance:2000)
        },trafficLifetime:.milliseconds(60))
        service.pick(place(),from:fix); try await waitUntil { service.trafficETA != nil }
        try await waitUntil { service.trafficETA == nil }
        XCTAssertNil(service.trafficFetched); XCTAssertEqual(service.phase,.preview)
    }
    func testFailedDataStartupCanRetrySuccessfully() async throws {
        var calls = 0
        let model = AppModel(storeLoader:{
            calls += 1
            if calls == 1 { throw TrafficStoreError.missingDatabase }
            return try TrafficStore(url:TrafficStore.bundledURL())
        })
        await model.start(); try await waitUntil { model.dataState == .failed }
        XCTAssertNotNil(model.dataError)
        model.reloadData(); try await waitUntil { model.dataState == .ready }
        try await waitUntil { !model.cameras.isEmpty }
        XCTAssertNil(model.dataError); XCTAssertEqual(calls,2)
    }
    func testDataLoadTimeoutCannotOverwriteSuccessfulRetry() async throws {
        var calls = 0
        let model = AppModel(storeLoader:{
            calls += 1
            if calls == 1 { await self.lateResponse() }
            return try TrafficStore(url:TrafficStore.bundledURL())
        },loadTimeout:.milliseconds(40))
        await model.start(); try await waitUntil { model.dataState == .failed }
        XCTAssertTrue(model.dataError?.contains("timed out") == true)
        model.reloadData(); try await waitUntil { model.dataState == .ready }
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(model.dataState,.ready); XCTAssertNil(model.dataError)
    }
    func testReturningToCachedViewportCancelsPendingDifferentArea() async throws {
        let model = AppModel()
        await model.start(); try await waitUntil { !model.cameras.isEmpty }
        let original = model.cameras.map(\.id)
        model.regionChanged(.init(center:.init(latitude:23.5,longitude:120.5),span:.init(latitudeDelta:0.1,longitudeDelta:0.1)))
        model.regionChanged(.init(center:.init(latitude:25.04,longitude:121.51),latitudinalMeters:24_000,longitudinalMeters:24_000))
        try await Task.sleep(for:.milliseconds(450))
        XCTAssertEqual(model.cameras.map(\.id),original)
    }
    func testGPSExpiryPausesOldRoadInformation() async throws {
        let model = AppModel()
        await model.start(); try await waitUntil { model.dataState == .ready }
        model.receive(.init(coordinate:.init(25.04,121.51),timestamp:Date().addingTimeInterval(-7.8),speed:20,course:0))
        try await waitUntil { model.gpsStale }
        XCTAssertNil(model.roadContext); XCTAssertNil(model.sectionZone); XCTAssertNil(model.latestAlert)
        model.receive(.init(coordinate:.init(25.04,121.51),speed:20,course:0))
        XCTAssertFalse(model.gpsStale)
    }
    func testThrottledGPSQueueDrainsWithoutNeedingAnotherFix() async throws {
        let model = AppModel()
        await model.start(); try await waitUntil { model.dataState == .ready }
        let first = LocationFix(coordinate:.init(25.04,121.51),speed:0,course:nil)
        model.receive(first); try await waitUntil { model.lastEvaluatedFixTimestamp == first.timestamp }
        let second = LocationFix(coordinate:.init(25.041,121.51),speed:0,course:nil)
        model.receive(second)
        try await waitUntil { model.lastEvaluatedFixTimestamp == second.timestamp }
    }
    func testRoadMatchingResetPreservesAlertRepeatSuppression() async throws {
        let processor = DrivingProcessor(), path = RoadPath([.init(25,121),.init(25.02,121)])
        let road = RoadSegment(id:"road",name:"國道1",ref:"國道1",direction:"N",speedLimit:100,path:path,level:"unknown",elevation:nil,sourceID:"fixture")
        let camera = CameraPoint(id:"camera",coordinate:.init(25.008,121),category:.speed,enforcementType:"Speed",roadName:"國道1",roadRef:"國道1",
                                 direction:"N",speedLimit:100,sourceID:"fixture",sourceAuthority:"Fixture",sourceUpdated:"2026-09-30",confidence:"A",isAlertEnabled:true,
                                 roadLevel:"unknown",bearings:[0],qualityNote:"Fixture",sectionID:nil,cctvURL:nil)
        let fix = LocationFix(coordinate:.init(25.004,121),speed:20,course:0)
        var result: DrivingResult?
        for _ in 0..<3 {
            result = await processor.evaluate(fix:fix,roads:[road],cameras:[camera],zones:[],route:path,routeRef:"國道1",street:"",streetName:"",stepPath:nil,driving:true)
        }
        XCTAssertNotNil(result?.alert)
        await processor.reset()
        for _ in 0..<3 {
            result = await processor.evaluate(fix:fix,roads:[road],cameras:[camera],zones:[],route:path,routeRef:"國道1",street:"",streetName:"",stepPath:nil,driving:true)
        }
        XCTAssertNotNil(result?.context); XCTAssertNil(result?.alert)
    }
}

final class LoadingImageTests: XCTestCase {
    func testDecodedFramesAreByteBoundedAndNewFrameReplacesOldCameraEntry() throws {
        SnapshotDecoder.releaseMemory(); defer { SnapshotDecoder.releaseMemory() }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size:.init(width:1200,height:300),format:format)
            .jpegData(withCompressionQuality:0.5) { canvas in
                UIColor.blue.setFill(); canvas.fill(.init(x:0,y:0,width:1200,height:300))
            }
        for index in 0..<12 {
            let snapshot = CameraSnapshot(data:data,downloadedAt:Date(timeIntervalSince1970:Double(index)))
            _ = try SnapshotDecoder.decode(snapshot,url:"https://camera.invalid/\(index/3)")
            let usage = SnapshotDecoder.cacheUsage()
            XCTAssertLessThanOrEqual(usage.bytes,4_000_000); XCTAssertLessThanOrEqual(usage.count,2)
            if index < 3 { XCTAssertEqual(usage.count,1,"Refresh must replace, not retain old frames") }
        }
        XCTAssertGreaterThan(SnapshotDecoder.cacheUsage().bytes,0)
        SnapshotDecoder.releaseMemory()
        XCTAssertEqual(SnapshotDecoder.cacheUsage().bytes,0); XCTAssertEqual(SnapshotDecoder.cacheUsage().count,0)
    }
    func testImageDecoderRejectsGarbageAndOversizedDimensions() throws {
        XCTAssertThrowsError(try SnapshotDecoder.decode(Data("Not a JPEG".utf8)))
        let renderer = UIGraphicsImageRenderer(size:.init(width:8001,height:1))
        let data = renderer.jpegData(withCompressionQuality:0.1) { context in UIColor.black.setFill(); context.fill(.init(x:0,y:0,width:8001,height:1)) }
        XCTAssertThrowsError(try SnapshotDecoder.decode(data))
    }
    func testImageDecoderDownsamplesBeforeDisplay() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size:.init(width:2000,height:400),format:format)
        let data = renderer.jpegData(withCompressionQuality:0.5) { context in UIColor.blue.setFill(); context.fill(.init(x:0,y:0,width:2000,height:400)) }
        let image = try SnapshotDecoder.decode(data)
        XCTAssertLessThanOrEqual(image.cgImage!.width,SnapshotDecoder.maximumPixelSize); XCTAssertGreaterThan(image.cgImage!.height,0)
    }
}

private final class CameraProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.path
        let response = HTTPURLResponse(url:request.url!,statusCode:mode == "/offline" ? 503 : 200,httpVersion:"HTTP/1.1",
                                       headerFields:mode == "/large" ? ["Content-Length":"4000000"] :
                                        ["Content-Type":mode == "/mjpeg" ? "multipart/x-mixed-replace; boundary=camera" : mode == "/html" ? "text/html" : mode == "/png" ? "image/png" : "image/jpeg"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if mode == "/hang" { return }
        if mode == "/mjpeg" {
            let bytes = Data("--camera\r\nContent-Type: image/jpeg\r\n\r\n".utf8)+CameraImageFixture.jpegWithEmbeddedEOI
            for byte in bytes { client?.urlProtocol(self,didLoad:Data([byte])) }
            return // The multipart server stays open; loading must finish after its first frame.
        }
        let image = CameraImageFixture.image(type:mode == "/png" ? "public.png" : "public.jpeg")
        client?.urlProtocol(self,didLoad:mode == "/truncated" ? Data(image.dropLast(2)) : image)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LoadingCCTVTests: XCTestCase {
    func service(timeout: TimeInterval = 1) -> CCTVService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CameraProtocol.self]
        return CCTVService(configuration:config,timeout:timeout)
    }
    func testCompressedFrameEvictionAndMemoryWarningKeepPublicFeedCooldown() async throws {
        let service = service()
        var frameBytes = 0
        for index in 0..<8 {
            let frame = try await service.snapshot(urlString:"https://camera.invalid/good/\(index)")
            frameBytes = frame.data.count
            let retained = await service.cachedByteCount()
            XCTAssertLessThanOrEqual(retained,4_000_000)
        }
        let retained = await service.cachedByteCount()
        XCTAssertEqual(retained,frameBytes*3)
        await service.releaseMemory()
        let cleared = await service.cachedByteCount(); XCTAssertEqual(cleared,0)
        do { _ = try await service.snapshot(urlString:"https://camera.invalid/good/7"); XCTFail("Must retain cooldown") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.wait.localizedDescription) }
    }
    @MainActor func testDismissalReleasesDecodedImage() async throws {
        let model = CCTVImageModel(service:service())
        model.load(url:"https://camera.invalid/good")
        let end = Date().addingTimeInterval(2)
        while model.loading && Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(model.image)
        model.stop(); XCTAssertNil(model.image); XCTAssertNil(model.downloadedAt)
        XCTAssertFalse(model.loading)
    }
    func testOfflineCameraFailsAndThrottlesRetry() async throws {
        let service = service()
        do { _ = try await service.snapshot(urlString:"https://camera.invalid/offline"); XCTFail("Expected offline failure") }
        catch { XCTAssertTrue(error is CCTVError) }
        do { _ = try await service.snapshot(urlString:"https://camera.invalid/offline"); XCTFail("Expected retry rate limit") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.wait.localizedDescription) }
    }
    func testHangingFeedEndsAtWallClockDeadline() async throws {
        let service = service(timeout:0.1), start = Date()
        do { _ = try await service.snapshot(urlString:"https://camera.invalid/hang"); XCTFail("Expected timeout") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
    }
    func testDismissalCancelsDownloadPromptlyAndAllowsRetry() async throws {
        let service = service(timeout:0.5)
        let task = Task { try await service.snapshot(urlString:"https://camera.invalid/hang") }
        try await Task.sleep(for:.milliseconds(30)); let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.4)
        do { _ = try await service.snapshot(urlString:"https://camera.invalid/hang"); XCTFail("Expected timeout") }
        catch { XCTAssertNotEqual(error.localizedDescription,CCTVError.wait.localizedDescription) }
    }
    func testCachedFrameAvoidsRepeatRequestAndOversizedFeedIsRejected() async throws {
        let service = service()
        let first = try await service.snapshot(urlString:"https://camera.invalid/good")
        let second = try await service.snapshot(urlString:"https://camera.invalid/good")
        XCTAssertEqual(first.downloadedAt,second.downloadedAt); XCTAssertEqual(first.data,second.data)
        do { _ = try await service.snapshot(urlString:"https://camera.invalid/large"); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.imageTooLarge.localizedDescription) }
        do { _ = try await service.snapshot(urlString:"http://camera.invalid/good"); XCTFail("Expected insecure URL rejection") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.invalidURL.localizedDescription) }
    }
    func testMJPEGStopsAtRealDecodableFirstFrameWithoutWaitingForServerClose() async throws {
        let start = Date(), snapshot = try await service().snapshot(urlString:"https://camera.invalid/mjpeg")
        XCTAssertNotNil(try SnapshotDecoder.decode(snapshot.data).cgImage)
        XCTAssertEqual(snapshot.data,CameraImageFixture.jpegWithEmbeddedEOI)
        XCTAssertLessThan(Date().timeIntervalSince(start),1)
    }
    func testPNGAndDecodeCacheAvoidRepeatImageDecode() async throws {
        let snapshot = try await service().snapshot(urlString:"https://camera.invalid/png")
        let first = try SnapshotDecoder.decode(snapshot,url:"https://camera.invalid/png")
        XCTAssertTrue(first === (try SnapshotDecoder.decode(snapshot,url:"https://camera.invalid/png")))
    }
    func testWebpageAndTruncatedFrameHaveActionableFailures() async throws {
        for path in ["html","truncated"] {
            do { _ = try await service().snapshot(urlString:"https://camera.invalid/\(path)"); XCTFail("Must reject \(path)") }
            catch { XCTAssertTrue(error is CCTVError) }
        }
    }
    @MainActor func testViewModelShowsFailureCooldownAndCanLoadNewCamera() async throws {
        let model = CCTVImageModel(service:service())
        model.load(url:"https://camera.invalid/offline")
        let end = Date().addingTimeInterval(2)
        while model.loading && Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(model.loading); XCTAssertTrue(model.error?.contains("503") == true)
        XCTAssertGreaterThan(model.cooldown,0); XCTAssertNil(model.image)
        model.load(url:"https://camera.invalid/good")
        while model.loading && Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(model.image); XCTAssertNil(model.error); XCTAssertNotNil(model.downloadedAt)
        model.stop()
    }
    @MainActor func testDismissedImageCannotPublishOrLeaveSpinner() async throws {
        let model = CCTVImageModel(service:service(timeout:0.1))
        model.load(url:"https://camera.invalid/hang")
        try await Task.sleep(for:.milliseconds(20)); model.stop()
        model.load(url:"https://camera.invalid/good")
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertFalse(model.loading); XCTAssertNotNil(model.image); XCTAssertNil(model.error)
        model.stop()
    }
}
#endif
