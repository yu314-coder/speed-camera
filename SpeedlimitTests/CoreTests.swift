import XCTest
import MapKit
#if SWIFT_PACKAGE
@testable import SpeedlimitCore
#else
@testable import Speedlimit
#endif

final class CoreTests: XCTestCase {
    let north = RoadPath([Coordinate(25,121),Coordinate(25.02,121)])
    func road(ref: String = "國道1",offset: Double = 0,elevation: Double? = nil) -> RoadSegment {
        .init(id:ref,name:ref,ref:ref,direction:"N",speedLimit:100,
              path:RoadPath([.init(25,121+offset),.init(25.02,121+offset)]),level:"unknown",elevation:elevation,sourceID:"test")
    }
    func fix(_ latitude: Double = 25.004,course: Double? = 0,date: Date = Date(),altitude: Double = 0) -> LocationFix {
        .init(coordinate:.init(latitude,121),timestamp:date,accuracy:5,speed:20,course:course,altitude:altitude,verticalAccuracy:3)
    }
    func camera(_ latitude: Double = 25.008,category: CameraCategory = .speed,section: String? = nil,enabled: Bool = true) -> CameraPoint {
        .init(id:"camera",coordinate:.init(latitude,121),category:category,enforcementType:"Speed",roadName:"國道1",roadRef:"國道1",
              direction:"南向北",speedLimit:100,sourceID:"test",sourceAuthority:"Test",sourceUpdated:"2026-09-30",confidence:"A",
              isAlertEnabled:enabled,roadLevel:"unknown",bearings:[0],qualityNote:"Explicit test fixture",sectionID:section,cctvURL:nil)
    }
    func context(_ fix: LocationFix) -> MatchedRoadContext {
        .init(segment:road(),projection:north.project(fix.coordinate)!,routeLocked:true,confidence:"Test")
    }
    func testProjectionUsesAlongRoadNotChord() {
        let path = RoadPath([.init(25,121),.init(25.01,121),.init(25.01,121.01)])
        let projection = path.project(.init(25.01,121.005))!
        XCTAssertLessThan(projection.distance,1)
        XCTAssertGreaterThan(projection.along,1600)
        XCTAssertEqual(projection.bearing,90,accuracy:1)
        XCTAssertLessThan(path.length-projection.along,510)
    }
    func testLongStraightSegmentRemainsProjectableInProgressWindow() {
        let path = RoadPath([.init(25,121),.init(25.2,121)])
        let projection = path.project(.init(25.12,121),nearAlong:13_000,bearing:0)
        XCTAssertNotNil(projection)
        XCTAssertEqual(projection?.along ?? 0,13_358.4,accuracy:5)
    }
    private func referenceProjection(_ coordinates: [Coordinate], point: Coordinate, nearAlong: Double?, bearing: Double?) -> PathProjection? {
        guard coordinates.count >= 2, coordinates.allSatisfy(\.valid), point.valid,
              nearAlong?.isFinite != false, bearing?.isFinite != false else { return nil }
        var cumulative = [0.0]
        for (a,b) in zip(coordinates,coordinates.dropFirst()) { cumulative.append(cumulative.last!+Geo.distance(a,b)) }
        var lower = 0, upper = coordinates.count-1
        if let nearAlong {
            lower = max(0,(cumulative.firstIndex { $0 >= nearAlong-1800 } ?? cumulative.count)-1)
            upper = min(upper,(cumulative.firstIndex { $0 >= nearAlong+1800 } ?? cumulative.count)+1)
        }
        guard lower < upper else { return nil }
        let scale = cos(point.latitude * .pi/180)
        var best: PathProjection?, score = Double.infinity
        for i in lower..<upper {
            let a = coordinates[i], b = coordinates[i+1]
            let latitudeDelta = b.latitude-a.latitude, longitudeDelta = b.longitude-a.longitude
            let dx = longitudeDelta*scale, dy = latitudeDelta
            let denominator = dx*dx+dy*dy
            guard denominator > 0 else { continue }
            let t = max(0,min(1,((point.longitude-a.longitude)*scale*dx+(point.latitude-a.latitude)*dy)/denominator))
            let q = Coordinate(a.latitude+t*latitudeDelta,a.longitude+t*longitudeDelta)
            let distance = hypot((point.longitude-q.longitude)*scale,point.latitude-q.latitude)*111_320
            let heading = Geo.bearing(a,b), candidateScore = distance+(bearing.map { Geo.angle($0,heading)*0.25 } ?? 0)
            if candidateScore < score {
                score = candidateScore
                best = .init(distance:distance,along:cumulative[i]+t*Geo.distance(a,b),bearing:heading,index:i,coordinate:q)
            }
        }
        return best
    }
    private func assertProjectionEquivalent(_ coordinates: [Coordinate], points: [Coordinate]) {
        let path = RoadPath(coordinates)
        let headings: [Double?] = [nil,0,90,180,359]
        let windows: [Double?] = [nil,-2000,0,path.length/2,path.length,path.length+2000]
        for point in points {
            for bearing in headings {
                for window in windows {
                    let expected = referenceProjection(coordinates,point:point,nearAlong:window,bearing:bearing)
                    let actual = path.project(point,nearAlong:window,bearing:bearing)
                    XCTAssertEqual(actual?.index,expected?.index)
                    XCTAssertEqual(actual?.coordinate,expected?.coordinate)
                    XCTAssertEqual(actual?.distance,expected?.distance)
                    XCTAssertEqual(actual?.along,expected?.along)
                    XCTAssertEqual(actual?.bearing,expected?.bearing)
                }
            }
        }
    }
    func testCompactProjectionMatchesReferenceOnCurvedAndReversedRoads() {
        let coordinates = (0..<120).map { Coordinate(24+Double($0)*0.0005,121+sin(Double($0)/8)*0.003) }
        let points = stride(from:0,to:120,by:4).map { Coordinate(coordinates[$0].latitude+0.0001,coordinates[$0].longitude-0.0001) }
        assertProjectionEquivalent(coordinates,points:points)
        assertProjectionEquivalent(Array(coordinates.reversed()),points:points)
    }
    func testCompactProjectionMatchesReferenceAtCrossingsAndDuplicateVertices() {
        let crossing: [Coordinate] = [.init(25,121),.init(25.02,121.02),.init(25,121.02),.init(25.02,121),.init(25,121)]
        let duplicate: [Coordinate] = [.init(25,121),.init(25,121),.init(25.02,121),.init(25.02,121)]
        for coordinates in [crossing,duplicate,[.init(25,121),.init(25,121)],[],[.init(25,121)]] {
            assertProjectionEquivalent(coordinates,points:[.init(25,121),.init(25.01,121.01),.init(25.02,121)])
        }
    }
    func testCompactGeometryStorageRemovesOnlyRedundantBuffers() {
        let count = 50_000
        let path = RoadPath((0..<count).map { Coordinate(24+Double($0)*0.00001,121) })
        let sharedBytes = count*(MemoryLayout<Coordinate>.stride+MemoryLayout<Double>.stride)
        let legacyBytes = sharedBytes+(count-1)*7*MemoryLayout<Double>.stride
        let compactBytes = sharedBytes+(count-1)*4*MemoryLayout<Double>.stride
        let indexBytes = ((count-1+63)/64)*4*MemoryLayout<Double>.stride
        XCTAssertEqual(path.projectionIndexByteCount,indexBytes)
        XCTAssertEqual(path.estimatedByteCount,compactBytes+indexBytes)
        XCTAssertEqual(path.coordinates.count,count); XCTAssertEqual(path.cumulative.count,count)
        XCTAssertLessThan(Double(path.estimatedByteCount)/Double(legacyBytes),0.707)
        print("STORAGE 50000-vertex path buffers: \(legacyBytes) -> \(path.estimatedByteCount) bytes (not total app RAM)")
    }
    func testIndexedProjectionMatchesFullScanOnLongCurvedAndReversedRoutes() {
        let coordinates = (0..<2048).map { Coordinate(24+Double($0)*0.00008,121+sin(Double($0)/25)*0.005) }
        let points = stride(from:0,to:2048,by:127).map {
            Coordinate(coordinates[$0].latitude+0.0002,coordinates[$0].longitude-0.0003)
        }
        assertProjectionEquivalent(coordinates,points:points)
        assertProjectionEquivalent(Array(coordinates.reversed()),points:points)
    }
    func testIndexedProjectionPreservesEarliestEdgeAtLoopsAndCrossings() {
        let loop: [Coordinate] = [.init(25,121),.init(25.02,121.02),.init(25,121.02),.init(25.02,121),.init(25,121)]
        let coordinates = (0..<70).flatMap { _ in loop }
        assertProjectionEquivalent(coordinates,points:[.init(25,121),.init(25.01,121.01),.init(25,121.015),.init(25.1,121.1)])
    }
    func testIndexedProjectionHandlesDegenerateBlocksAndVeryLongEdges() {
        var coordinates = [Coordinate](repeating:.init(25,121),count:256)
        coordinates += [.init(25.5,121),.init(25.5,121.5)]
        coordinates += [Coordinate](repeating:.init(25.5,121.5),count:130)
        assertProjectionEquivalent(coordinates,points:[.init(25.12,121),.init(25.5,121.2),.init(25.4,121.3)])
        let emptyEdges = RoadPath([Coordinate](repeating:.init(25,121),count:300))
        XCTAssertNil(emptyEdges.project(.init(25,121)))
        XCTAssertNil(emptyEdges.project(.init(25,121),nearAlong:0,bearing:90))
    }
    func testIndexedProjectionNearPolesAndAcrossLongitudeBoundary() {
        for latitude in [89.99,-89.99,25.0] {
            let coordinates = (0..<320).map { Coordinate(latitude,Double($0%2 == 0 ? 179:-179)+Double($0%8)*0.0001) }
            assertProjectionEquivalent(coordinates,points:[.init(latitude,180),.init(latitude,-180),.init(latitude,0)])
        }
    }
    func testShortPathsDoNotAllocateProjectionIndex() {
        let short = RoadPath((0..<256).map { Coordinate(25+Double($0)*0.0001,121) })
        let indexed = RoadPath((0..<257).map { Coordinate(25+Double($0)*0.0001,121) })
        XCTAssertEqual(short.projectionIndexByteCount,0)
        XCTAssertEqual(indexed.projectionIndexByteCount,4*4*MemoryLayout<Double>.stride)
        XCTAssertNil(indexed.project(.init(.nan,121)))
        XCTAssertNil(indexed.project(.init(25,121),nearAlong:.infinity))
        XCTAssertNil(indexed.project(.init(25,121),bearing:.nan))
    }
    func testNameCacheEvictionAndMemoryCleanupPreserveRoadIdentity() {
        let texts = ["沿著國道一號行駛","臺64甲","Turn right onto Heping W Rd Sec 3","向右轉進入和平西路3段","Keep left",""]
        let expected = texts.map { [Geo.roadRef($0),Geo.streetName($0),Geo.streetKey($0)] }
        for i in 0..<1100 {
            let text = "Continue on Provincial Highway No. \(i)"
            XCTAssertEqual(Geo.roadRef(text),"台\(i)")
            _ = Geo.streetName(text); _ = Geo.streetKey(text)
        }
        Geo.releaseCachedNames()
        XCTAssertEqual(texts.map { [Geo.roadRef($0),Geo.streetName($0),Geo.streetKey($0)] },expected)
        let oversized = String(repeating:" ",count:3000)+"台61乙"
        XCTAssertEqual(Geo.roadRef(oversized),"台61乙")
        XCTAssertEqual(Geo.streetName(oversized),"")
    }
    func testLongRouteProjectionPerformance() {
        let coordinates = (0..<50_000).map { Coordinate(24+Double($0)*0.00001,121+sin(Double($0)/200)*0.0003) }
        let path = RoadPath(coordinates)
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(options:options) {
            for i in 0..<300 { _ = path.project(coordinates[(i*157+137)%coordinates.count],bearing:0) }
        }
    }
    func testStreetNormalizationForAppleRouteMatching() {
        XCTAssertEqual(Geo.streetKey("向右轉進入和平西路3段"),"hepingwrd")
        XCTAssertEqual(Geo.streetKey("和平西路3段199號前"),"hepingwrd")
        XCTAssertEqual(Geo.streetKey("Turn right onto Heping W Rd Sec 3"),"hepingwrd")
        XCTAssertEqual(Geo.streetKey("承德路3段"),Geo.streetKey("Turn right onto Chengde Rd Sec 3"))
        XCTAssertEqual(Geo.streetKey("臺北市士林區承德路5段"),"chengderd")
        XCTAssertEqual(Geo.streetKey("承德路與敦煌路口"),"chengderd")
        XCTAssertEqual(Geo.roadRef("沿著國道一號行駛"),"國道1")
        XCTAssertEqual(Geo.roadRef("Continue on National Highway No. 1"),"國道1")
    }
    func testWrongDirectionDoesNotMatch() {
        var matcher = RoadMatcher()
        for _ in 0..<5 { XCTAssertNil(matcher.match(fix(course:180),roads:[road()])) }
    }
    func testRoadLockRequiresThreeStableFixes() {
        var matcher = RoadMatcher()
        XCTAssertNil(matcher.match(fix(),roads:[road()]))
        XCTAssertNil(matcher.match(fix(),roads:[road()]))
        XCTAssertNotNil(matcher.match(fix(),roads:[road()]))
    }
    func testParallelRoadAmbiguityIsSuppressed() {
        var matcher = RoadMatcher()
        for _ in 0..<5 { XCTAssertNil(matcher.match(fix(),roads:[road(),road(ref:"台1",offset:0.00008)])) }
    }
    func testRouteRefRejectsParallelRoad() {
        var matcher = RoadMatcher()
        var match: MatchedRoadContext?
        for _ in 0..<3 { match = matcher.match(fix(),roads:[road(),road(ref:"台1",offset:0.00008)],route:north,routeRef:"國道1") }
        XCTAssertEqual(match?.segment.ref,"國道1")
        XCTAssertEqual(match?.routeLocked,true)
    }
    func testAltitudeRequiresSurveyedRoadHeight() {
        var matcher = RoadMatcher()
        for _ in 0..<3 { XCTAssertNil(matcher.match(fix(altitude:0),roads:[road(elevation:40)])) }
        var match: MatchedRoadContext?
        for _ in 0..<3 { match = matcher.match(fix(altitude:600),roads:[road(elevation:nil)]) }
        XCTAssertNotNil(match)
        XCTAssertTrue(match?.confidence.contains("elevation unknown") == true)
    }
    func testStaleAndDirectionlessGPSAreSuppressed() {
        var matcher = RoadMatcher()
        XCTAssertNil(matcher.match(fix(date:Date().addingTimeInterval(-30)),roads:[road()]))
        XCTAssertNil(matcher.match(fix(course:nil),roads:[road()]))
    }
    func testAlertsEscalateButDoNotRepeat() {
        var engine = AlertEngine(); let now = Date(); let first = fix(date:now)
        let warning = engine.evaluate(fix:first,context:context(first),cameras:[camera()],zones:[],route:north,now:now)
        XCTAssertEqual(warning?.severity,.warning)
        XCTAssertNil(engine.evaluate(fix:first,context:context(first),cameras:[camera()],zones:[],route:north,now:now.addingTimeInterval(1)))
        let later = now.addingTimeInterval(10); let near = fix(25.006,date:later)
        XCTAssertEqual(engine.evaluate(fix:near,context:context(near),cameras:[camera()],zones:[],route:north,now:later)?.severity,.critical)
        XCTAssertNil(engine.evaluate(fix:near,context:context(near),cameras:[camera()],zones:[],route:north,now:later.addingTimeInterval(1)))
        let retry = later.addingTimeInterval(121); let current = fix(25.006,date:retry)
        XCTAssertNotNil(engine.evaluate(fix:current,context:context(current),cameras:[camera()],zones:[],route:north,now:retry))
    }
    func testBehindAndLimitedCamerasAreNotAlerted() {
        var engine = AlertEngine(); let fix = fix()
        XCTAssertNil(engine.evaluate(fix:fix,context:context(fix),cameras:[camera(25.001)],zones:[],route:north))
        XCTAssertNil(engine.evaluate(fix:fix,context:context(fix),cameras:[camera(enabled:false)],zones:[],route:north))
    }
    func testSectionZoneProgress() {
        var engine = AlertEngine(); let fix = fix()
        let zone = SectionZone(id:"zone",name:"Test section",ref:"國道1",speedLimit:90,path:north,length:north.length,isAlertEnabled:true,confidence:"A")
        let alert = engine.evaluate(fix:fix,context:context(fix),cameras:[camera(25,category:.sectionSpeed,section:"zone")],zones:[zone],route:north)
        XCTAssertEqual(alert?.severity,.inSection)
        XCTAssertTrue(alert?.inSection == true)
        XCTAssertEqual(alert?.distance ?? 0,north.length-445.28,accuracy:2)
    }
    func testNavigationProgressAndSustainedOffRoute() {
        var progress = NavigationProgress()
        _ = progress.update(fix:fix(25.012),path:north,stepEnds:[1000,north.length])
        XCTAssertEqual(progress.stepIndex,1)
        XCTAssertEqual(progress.remaining,north.length-1335.84,accuracy:2)
        let off = LocationFix(coordinate:.init(25.012,121.003),speed:20,course:0)
        for _ in 0..<3 { _ = progress.update(fix:off,path:north,stepEnds:[1000,north.length]) }
        XCTAssertEqual(progress.offRouteFixes,3)
    }
    func testCachedGeometryPerformance() {
        let coordinates = (0..<4000).map { Coordinate(24+Double($0)*0.00001,121+sin(Double($0)/200)*0.0003) }
        let path = RoadPath(coordinates)
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(options:options) {
            for i in 0..<100 { _ = path.project(coordinates[1000+i],nearAlong:1200,bearing:0) }
        }
    }
}

final class StoreTests: XCTestCase {
    func testBundledDatabaseAndPublicCCTV() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let summary = try await store.summary()
        XCTAssertGreaterThan(summary.cameras,2000); XCTAssertGreaterThan(summary.cctv,3000)
        XCTAssertGreaterThan(summary.sections,15)
        let cameras = try await store.cameras(in:.init(center:.init(25.10,121.70),radius:20_000),categories:[.cctv])
        XCTAssertFalse(cameras.isEmpty)
        XCTAssertTrue(cameras.allSatisfy { $0.cctvURL?.hasPrefix("https://") == true && !$0.isAlertEnabled })
    }
    func testTai64CorridorsHaveRealGeometry() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let zones = try await store.sections(in:.init(center:.init(25.04,121.46),radius:20_000)).filter { $0.ref == "台64" }
        XCTAssertGreaterThanOrEqual(zones.count,5)
        XCTAssertTrue(zones.allSatisfy { $0.path.coordinates.count >= 3 && $0.isAlertEnabled && $0.confidence == "A" &&
            abs($0.path.length-$0.length) < max(150,$0.length*0.12) })
    }
    func testMisplacedMiaoliCoordinateIsExcluded() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let bad = try await store.cameras(in:.init(center:.init(24.4974587,122.6769237),radius:300),categories:[.sectionSpeed])
        XCTAssertTrue(bad.isEmpty)
    }
    func testSpatialQueriesAndRoadMatchPerformance() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let start = Date()
        for index in 0..<100 {
            let coordinate = Coordinate(25.0+Double(index%10)*0.005,121.45+Double(index%10)*0.005)
            _ = try await store.cameras(in:.init(center:coordinate,radius:1500),categories:Set(CameraCategory.allCases))
            let roads = try await store.roads(near:coordinate)
            var matcher = RoadMatcher()
            _ = matcher.match(.init(coordinate:coordinate,speed:20,course:90),roads:roads)
        }
        let seconds = Date().timeIntervalSince(start)
        print("PERFORMANCE spatial+matching: \(seconds*1000/100) ms/update across 100 real Taiwan windows")
        XCTAssertLessThan(seconds,8,"Database and geometry work must stay well below a one-second GPS cadence")
    }
}

#if !SWIFT_PACKAGE
@MainActor
final class NavigationTests: XCTestCase {
    func destination(_ name: String) -> MKMapItem {
        let item = MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:25.05,longitude:121.53))); item.name = name; return item
    }
    var fix: LocationFix { .init(coordinate:.init(25.04,121.51),speed:0,course:nil) }
    func testLatestDestinationWins() async throws {
        let service = NavigationService(routeProvider:{ fix,item in
            // Deliberately ignore cancellation, like an already-delivered network response.
            try? await Task.sleep(for:.milliseconds(item.name == "old" ? 400 : 30))
            return [RouteOption(name:item.name!,coordinates:[fix.coordinate,.init(item.placemark.coordinate)],instructions:["Continue"])]
        })
        service.pick(destination("old"),from:fix); service.pick(destination("new"),from:fix)
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(service.phase,.preview); XCTAssertEqual(service.selected?.name,"new")
    }
    func testCancelNeverResurrectsNavigation() async throws {
        let service = NavigationService(routeProvider:{ fix,item in
            try? await Task.sleep(for:.milliseconds(100))
            return [RouteOption(name:"old",coordinates:[fix.coordinate,.init(item.placemark.coordinate)],instructions:["Continue"])]
        })
        service.pick(destination("old"),from:fix); service.stop()
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertEqual(service.phase,.idle); XCTAssertTrue(service.routes.isEmpty); XCTAssertNil(service.destination)
    }
    func testReadyRouteStartsAndAlternateSelectionPersists() async throws {
        let service = NavigationService(routeProvider:{ fix,item in
            [RouteOption(name:"A",coordinates:[fix.coordinate,.init(item.placemark.coordinate)],instructions:["Continue"]),
             RouteOption(name:"B",coordinates:[fix.coordinate,.init(25.045,121.54),.init(item.placemark.coordinate)],instructions:["Continue"])]
        })
        service.pick(destination("test"),from:fix)
        try await Task.sleep(for:.milliseconds(100))
        service.select(service.routes[1].id)
        XCTAssertTrue(service.start(fix:fix)); XCTAssertEqual(service.phase,.navigating); XCTAssertEqual(service.selected?.name,"B")
        service.stop(); XCTAssertEqual(service.phase,.idle)
    }
    func testStartWithoutGPSFailsClearly() async throws {
        let service = NavigationService(); service.pick(destination("test"),from:nil)
        XCTAssertEqual(service.phase,.failed); XCTAssertNotNil(service.error); XCTAssertFalse(service.start(fix:nil))
    }
}
#endif
