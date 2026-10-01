import XCTest
import ImageIO
import CoreGraphics
import MapKit
import SQLite3
#if SWIFT_PACKAGE
@testable import SpeedlimitCore
#else
import UIKit
@testable import Speedlimit
#endif

enum CameraImageFixture {
    static func image(type: String = "public.jpeg") -> Data {
        let pixels = Data([0,100,220,255,40,160,230,255])
        let provider = CGDataProvider(data:pixels as CFData)!
        let image = CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,
                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output,type as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
    static var jpegWithEmbeddedEOI: Data {
        var bytes = Data([0xff,0xd8,0xff,0xe1,0,8,0x10,0xff,0xd9,0x20,0,0x12])
        bytes.append(image().dropFirst(2))
        return bytes
    }
}

final class JPEGParserTests: XCTestCase {
    func testContinuousParserHandlesEveryByteBoundaryAndEmbeddedExifTerminator() throws {
        let jpeg = CameraImageFixture.jpegWithEmbeddedEOI
        let part = Data("\r\n--camera\r\nContent-Type: image/jpeg\r\n\r\n".utf8)+jpeg
        var parser = JPEGFrameParser(continuous:true), frames: [Data] = []
        for byte in part+part+part {
            if let frame = try parser.append(Data([byte])) { frames.append(frame) }
        }
        XCTAssertEqual(frames,[jpeg,jpeg,jpeg]); XCTAssertEqual(parser.bufferedByteCount,0)
    }
    func testContinuousParserDrainsChunkWithoutRetainingOldFrames() throws {
        let jpeg = CameraImageFixture.image(), boundary = Data("\r\n--camera\r\n\r\n".utf8)
        var chunk = Data(), parser = JPEGFrameParser(continuous:true)
        for _ in 0..<500 { chunk.append(boundary); chunk.append(jpeg) }
        var frame = try parser.append(chunk), count = 0
        while let bytes = frame { XCTAssertEqual(bytes,jpeg); count += 1; frame = try parser.append(Data()) }
        XCTAssertEqual(count,500); XCTAssertEqual(parser.bufferedByteCount,0)
        for _ in 0..<2_000 { XCTAssertEqual(try parser.append(jpeg),jpeg); XCTAssertEqual(parser.bufferedByteCount,0) }
    }
    func testContinuousParserRejectsInvalidOrOversizedNextFrame() throws {
        let jpeg = CameraImageFixture.image()
        var parser = JPEGFrameParser(continuous:true)
        XCTAssertEqual(try parser.append(jpeg),jpeg)
        XCTAssertThrowsError(try parser.append(Data(repeating:0,count:64_002)))
        parser = .init(continuous:true)
        XCTAssertEqual(try parser.append(jpeg),jpeg)
        XCTAssertThrowsError(try parser.append(Data(repeating:0,count:JPEGFrameParser.maximumBytes+1)))
    }
    func testFirstFrameReleasesMultipartBufferAndIgnoresTrailingChunks() throws {
        let jpeg = CameraImageFixture.image()
        var parser = JPEGFrameParser()
        let multipart = jpeg+Data(repeating:0,count:2_000_000)
        XCTAssertEqual(try parser.append(multipart),jpeg)
        XCTAssertEqual(parser.bufferedByteCount,0)
        XCTAssertNil(try parser.append(Data(repeating:0,count:JPEGFrameParser.maximumBytes+1)))
        XCTAssertEqual(parser.bufferedByteCount,0)
    }
    func testPublishedSouthernParameterRepairIsNarrowAndKeepsCameraID() throws {
        let old = "https://cctvs.freeway.gov.tw/live-view/mjpg/video.cgi?cacame=3092"
        XCTAssertEqual(try CCTVService.publicURL(old).absoluteString,old.replacingOccurrences(of:"cacame",with:"camera"))
        let other = "https://example.com/live-view/mjpg/video.cgi?cacame=3092"
        XCTAssertEqual(try CCTVService.publicURL(other).absoluteString,other)
        XCTAssertThrowsError(try CCTVService.publicURL("http://example.com/camera"))
    }
    func testEverySingleByteBoundaryAndExifFalseTerminator() throws {
        let jpeg = CameraImageFixture.jpegWithEmbeddedEOI
        var parser = JPEGFrameParser(), frame: Data?
        let multipart = Data("--camera\r\nContent-Type: image/jpeg\r\n\r\n".utf8)+jpeg
        for byte in multipart { if let result = try parser.append(Data([byte])) { frame = result } }
        XCTAssertEqual(frame,jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(frame) as CFData,nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source,0,nil))
    }
    func testMultipleFramesReturnOnlyFirst() throws {
        let jpeg = CameraImageFixture.image()
        var parser = JPEGFrameParser()
        XCTAssertEqual(try parser.append(jpeg+Data("\r\n--boundary\r\n".utf8)+jpeg),jpeg)
        XCTAssertNil(try parser.append(jpeg))
    }
    func testInvalidPreambleSizeAndTruncatedFrameAreBounded() throws {
        var parser = JPEGFrameParser()
        XCTAssertThrowsError(try parser.append(Data(repeating:0,count:64_002)))
        parser = .init()
        XCTAssertThrowsError(try parser.append(Data(repeating:0,count:JPEGFrameParser.maximumBytes+1)))
        parser = .init()
        let jpeg = CameraImageFixture.image()
        XCTAssertNil(try parser.append(Data(jpeg.dropLast(2))))
    }
    func testProgressiveScanStuffingAndRestartMarkers() throws {
        let jpeg = Data([0xff,0xd8,0xff,0xda,0,2,0x10,0xff,0,0xd9,0xff,0xd1,0x20,
                         0xff,0xda,0,2,0x30,0xff,0xff,0xd9])
        var parser = JPEGFrameParser()
        XCTAssertEqual(try parser.append(jpeg),jpeg)
    }
    func testChunkParserPerformance() throws {
        let jpeg = CameraImageFixture.image()
        let start = Date()
        for _ in 0..<500 {
            var parser = JPEGFrameParser()
            XCTAssertEqual(try parser.append(jpeg),jpeg)
        }
        print("PERFORMANCE chunked JPEG parser: \(Date().timeIntervalSince(start)*1000/500) ms/frame (2x1 fixture; not network latency)")
        XCTAssertLessThan(Date().timeIntervalSince(start),3)
    }
}

final class MapLayerStoreTests: XCTestCase {
    let taiwan = MapBounds(south:21.8,north:25.5,west:119.8,east:122.1)
    private func legacyMapIDs(_ database: OpaquePointer, bounds: MapBounds, categories: Set<CameraCategory>, showLimited: Bool, limit: Int) throws -> [String] {
        func ids(_ sql: String, values: [Double]) throws -> [String] {
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(database,sql,-1,&statement,nil)
            defer { sqlite3_finalize(statement) }
            guard status == SQLITE_OK, let statement else { throw TrafficStoreError.sqlite("Reference query failed") }
            for (index,value) in values.enumerated() { sqlite3_bind_double(statement,Int32(index+1),value) }
            var result: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(statement,0) else { throw TrafficStoreError.sqlite("Reference row failed") }
                result.append(String(cString:text))
            }
        }
        let spatial = [bounds.west,bounds.east,bounds.south,bounds.north]
        let confidence = showLimited ? "" : "AND (c.location_confidence='A' OR c.camera_category='cctv')"
        var result: [String] = []
        if categories.contains(.sectionSpeed) {
            result = try ids("""
            SELECT c.id FROM camera_rtree r JOIN camera_points c ON c.rowid=r.rowid
            WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=?
            AND c.camera_category='section_speed' \(confidence) ORDER BY c.id LIMIT 200
            """,values:spatial)
        }
        let other = CameraCategory.allCases.filter { categories.contains($0) && $0 != .sectionSpeed }
        let weights = other.map { $0 == .speed || $0 == .cctv ? 3 : 1 }
        let remaining = max(200,min(600,limit))-result.count, totalWeight = max(1,weights.reduce(0,+))
        for (index,category) in other.enumerated() {
            let quota = max(1,remaining*weights[index]/totalWeight)
            // Keep the pre-optimization full-row window query as the selection oracle.
            result += try ids("""
            SELECT c.id FROM (
                SELECT c.*,ROW_NUMBER() OVER (
                    PARTITION BY CAST((c.lat-?)/MAX(?,0.000001)*8 AS INTEGER),
                                 CAST((c.lon-?)/MAX(?,0.000001)*12 AS INTEGER) ORDER BY c.id
                ) AS map_rank
                FROM camera_rtree r JOIN camera_points c ON c.rowid=r.rowid
                WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=?
                AND c.camera_category='\(category.rawValue)' \(confidence)
            ) c ORDER BY c.map_rank,c.id LIMIT \(quota)
            """,values:[bounds.south,bounds.north-bounds.south,bounds.west,bounds.east-bounds.west]+spatial)
        }
        return result.sorted()
    }
    func testIDOnlyRankingPreservesLegacyCameraSelectionAcrossRegionsAndFilters() async throws {
        let url = try TrafficStore.bundledURL(), store = try TrafficStore(url:url)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path,&handle,SQLITE_OPEN_READONLY,nil)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(status,SQLITE_OK)
        let database = try XCTUnwrap(handle)
        let regions = [taiwan,MapBounds(center:.init(25.04,121.51),radius:20_000),
                       MapBounds(center:.init(22.63,120.3),radius:20_000),MapBounds(center:.init(23.97,121.6),radius:20_000)]
        let layers = CameraCategory.allCases.map { Set([$0]) } + [Set(CameraCategory.allCases),[.speed,.cctv],[.sectionSpeed,.redLight]]
        var checks = 0
        for bounds in regions {
            for showLimited in [true,false] {
                for budget in [240,360,600] {
                    for categories in layers {
                        let expected = try legacyMapIDs(database,bounds:bounds,categories:categories,showLimited:showLimited,limit:budget)
                        let actual = try await store.mapCameras(in:bounds,categories:categories,showLimited:showLimited,limit:budget)
                        XCTAssertEqual(actual.map(\.id),expected,"Selection changed for \(bounds), \(categories), \(budget), limited=\(showLimited)")
                        checks += 1
                    }
                }
            }
        }
        XCTAssertEqual(checks,192)
    }
    func testReducedMapBudgetKeepsEverySectionEndpointAndEveryLayer() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let sections = try await store.cameras(in:taiwan,categories:[.sectionSpeed])
        for budget in [240,360] {
            let points = try await store.mapCameras(in:taiwan,categories:Set(CameraCategory.allCases),showLimited:true,limit:budget)
            XCTAssertLessThanOrEqual(points.count,budget)
            XCTAssertEqual(Set(points.filter { $0.category == .sectionSpeed }.map(\.id)),Set(sections.map(\.id)))
            for category in CameraCategory.allCases { XCTAssertTrue(points.contains { $0.category == category }) }
        }
    }
    func testMixedLayersCannotStarveCCTVOrSectionEndpoints() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let map = try await store.mapCameras(in:taiwan,categories:Set(CameraCategory.allCases),showLimited:true)
        XCTAssertLessThanOrEqual(map.count,600)
        for category in CameraCategory.allCases { XCTAssertTrue(map.contains { $0.category == category },"Missing layer \(category)") }
        let sections = try await store.cameras(in:taiwan,categories:[.sectionSpeed])
        XCTAssertEqual(Set(map.filter { $0.category == .sectionSpeed }.map(\.id)),Set(sections.map(\.id)))
        let again = try await store.mapCameras(in:taiwan,categories:Set(CameraCategory.allCases),showLimited:true)
        XCTAssertEqual(map,again)
    }
    func testHideLimitedDoesNotHideOfficialSectionExit() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let points = try await store.mapCameras(in:taiwan,categories:[.sectionSpeed],showLimited:false)
        let zones = try await store.sections(in:taiwan,showLimited:false)
        for zone in zones {
            let endpoints = points.filter { $0.sectionID == zone.id }
            XCTAssertEqual(endpoints.count,2,"Both official endpoints required for \(zone.id)")
            XCTAssertTrue(endpoints.contains { !$0.isAlertEnabled })
        }
        XCTAssertTrue(points.allSatisfy { $0.confidence == "A" })
    }
    func testIndependentLayerToggleAndHonestSectionLabels() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let cctv = try await store.mapCameras(in:taiwan,categories:[.cctv],showLimited:false)
        XCTAssertFalse(cctv.isEmpty); XCTAssertTrue(cctv.allSatisfy { $0.category == .cctv && !$0.isAlertEnabled })
        XCTAssertEqual(cctv[0].confidenceTitle,"Official · traffic observation")
        let sections = try await store.mapCameras(in:taiwan,categories:[.sectionSpeed],showLimited:true)
        XCTAssertTrue(sections.filter { $0.sectionID == nil }.allSatisfy { $0.sectionCoverageTitle.contains("unverified") })
        let empty = try await store.mapCameras(in:taiwan,categories:[],showLimited:true)
        XCTAssertTrue(empty.isEmpty)
        let summary = try await store.summary()
        XCTAssertEqual(summary.sections,summary.verifiedSections+summary.estimatedSections)
        XCTAssertEqual(summary.verifiedSections,22); XCTAssertEqual(summary.estimatedSections,16)
        XCTAssertEqual(summary.unresolvedSectionEndpoints,11)
    }
    func testMapLayerBudgetPerformanceOnWholeTaiwan() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL()), start = Date()
        for _ in 0..<10 { _ = try await store.mapCameras(in:taiwan,categories:Set(CameraCategory.allCases),showLimited:true) }
        let elapsed = Date().timeIntervalSince(start)
        print("PERFORMANCE balanced Taiwan map query: \(elapsed*100) ms/update")
        XCTAssertLessThan(elapsed,5)
    }
}

#if !SWIFT_PACKAGE
@MainActor
final class SectionMapStyleTests: XCTestCase {
    func view(revision: Int = 0, cameras: [CameraPoint] = [], zones: [SectionZone] = []) -> TaiwanMapView {
        .init(cameras:cameras,zones:zones,dataRevision:revision,routeOptions:[],selectedRouteID:nil,routeRevision:0,
              destination:nil,destinationTitle:nil,navigating:false,location:location,followRequest:0,traffic:false,picking:false,
              onRegion:{ _ in },onPick:{ _ in },onCamera:{ _ in },onRoute:{ _ in })
    }
    private let location = LocationService()
    func testDismantleReleasesMapAnnotationsOverlaysAndDelegate() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let bounds = MapBounds(south:21.8,north:25.5,west:119.8,east:122.1)
        let cameras = try await store.mapCameras(in:bounds,categories:Set(CameraCategory.allCases),showLimited:true)
        let zones = try await store.sections(in:bounds)
        let parent = view(cameras:cameras,zones:zones), map = MKMapView(), coordinator = parent.makeCoordinator()
        let host = UIView(); host.addSubview(map); coordinator.map = map; coordinator.host = host; map.delegate = coordinator
        coordinator.updateCameras(cameras); coordinator.updateSections(zones)
        XCTAssertFalse(map.annotations.isEmpty); XCTAssertFalse(map.overlays.isEmpty)
        TaiwanMapView.dismantleUIView(host,coordinator:coordinator)
        XCTAssertNil(map.delegate); XCTAssertNil(map.superview)
        XCTAssertNil(coordinator.map); XCTAssertNil(coordinator.host)
        XCTAssertTrue(map.annotations.isEmpty); XCTAssertTrue(map.overlays.isEmpty)
    }
    func testEverySectionMarkerUsesSectionIconIncludingUnverifiedEndpoints() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let points = try await store.mapCameras(in:.init(south:21.8,north:25.5,west:119.8,east:122.1),
            categories:[.sectionSpeed],showLimited:true)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.contains { $0.sectionID == nil })
        let parent = view(), map = MKMapView(), coordinator = parent.makeCoordinator()
        map.register(CameraPinView.self,forAnnotationViewWithReuseIdentifier:"camera")
        let expected = try XCTUnwrap(UIImage(systemName:CameraCategory.sectionSpeed.symbol))
        func renderedGlyph(_ glyph: UIImage) throws -> Data {
            try XCTUnwrap(UIGraphicsImageRenderer(size:.init(width:32,height:32)).image { _ in
                glyph.draw(in:.init(x:0,y:0,width:32,height:32))
            }.pngData())
        }
        let expectedPixels = try renderedGlyph(expected)
        for point in points {
            let marker = try XCTUnwrap(coordinator.mapView(map,viewFor:CameraAnnotation(point)) as? CameraPinView)
            let glyph = try XCTUnwrap(marker.glyphImage,"Missing section icon for \(point.id)")
            XCTAssertEqual(try renderedGlyph(glyph),expectedPixels,"Wrong section icon for \(point.id)")
            XCTAssertNil(marker.clusteringIdentifier)
            if point.sectionID == nil {
                XCTAssertNotNil(marker.image)
                XCTAssertFalse(point.isAlertEnabled)
                XCTAssertTrue(point.sectionCoverageTitle.contains("unverified"))
                XCTAssertTrue(marker.accessibilityLabel?.contains("hidden from alerts") == true)
            }
        }
    }
    func testEveryVerifiedSectionGetsBlueDashedOverlayAboveRoutes() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let zones = try await store.sections(in:.init(south:21.8,north:25.5,west:119.8,east:122.1))
        let parent = view(zones:zones), map = MKMapView(), coordinator = parent.makeCoordinator()
        coordinator.map = map; coordinator.updateSections(zones)
        let groups = SectionOverlayPlan.groups(zones)
        XCTAssertEqual(Set(groups.flatMap { $0.zones.map(\.id) }),Set(zones.map(\.id)))
        XCTAssertEqual(map.overlays(in:.aboveLabels).count,groups.count)
        for overlay in map.overlays {
            let renderer = try XCTUnwrap(coordinator.mapView(map,rendererFor:overlay) as? MKPolylineRenderer)
            XCTAssertTrue(renderer is SectionCorridorRenderer)
            XCTAssertEqual(renderer.lineDashPattern,[12,10]); XCTAssertEqual(renderer.lineCap,.butt)
        }
        coordinator.updateSections(zones); XCTAssertEqual(map.overlays.count,groups.count)
        coordinator.updateSections([]); XCTAssertTrue(map.overlays.isEmpty)
    }
    func testMapSkipsUnrelatedUIUpdatesButNotLayerChanges() {
        XCTAssertEqual(view(),view())
        XCTAssertNotEqual(view(),view(revision:1))
    }
    func testDashGapsRemainVisibleOverSolidBlueNavigationRoute() throws {
        var coordinates = [CLLocationCoordinate2D(latitude:25,longitude:121),.init(latitude:25,longitude:121.01)]
        let renderer = SectionCorridorRenderer(polyline:MKPolyline(coordinates:&coordinates,count:2))
        let path = CGMutablePath(); path.move(to:.init(x:16,y:40)); path.addLine(to:.init(x:304,y:40))
        renderer.path = path; renderer.strokeColor = .systemBlue; renderer.lineWidth = 5
        renderer.lineDashPattern = [12,10]; renderer.lineCap = .butt
        let image = UIGraphicsImageRenderer(size:.init(width:320,height:80)).image { canvas in
            UIColor.white.setFill(); canvas.fill(.init(x:0,y:0,width:320,height:80))
            canvas.cgContext.setStrokeColor(UIColor.systemBlue.cgColor); canvas.cgContext.setLineWidth(7)
            canvas.cgContext.addPath(path); canvas.cgContext.strokePath()
            renderer.draw(.init(x:0,y:0,width:320,height:80),zoomScale:1,in:canvas.cgContext)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating:0,count:320*80*4)
        let context = try XCTUnwrap(CGContext(data:&pixels,width:320,height:80,bitsPerComponent:8,bytesPerRow:320*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg,in:.init(x:0,y:0,width:320,height:80))
        let dash = (40*320+20)*4, gap = (40*320+32)*4
        XCTAssertGreaterThan(pixels[dash+2],pixels[dash])
        XCTAssertGreaterThan(pixels[gap],230,"The route below must not fill a section dash gap")
        XCTAssertGreaterThan(pixels[gap+1],230)
        let attachment = XCTAttachment(image:image); attachment.name = "Section dashes over solid navigation"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testSearchSuspendsAndRestoresCanvasWithoutDiscardingAnnotations() {
        let parent = view(), map = MKMapView(), coordinator = parent.makeCoordinator()
        let host = UIView(); host.addSubview(map)
        coordinator.map = map; coordinator.host = host
        coordinator.setSearchPaused(true); XCTAssertTrue(map.isHidden)
        XCTAssertNil(map.superview)
        XCTAssertEqual(map.userTrackingMode,.none)
        coordinator.setSearchPaused(false); XCTAssertFalse(map.isHidden)
        XCTAssertTrue(map.superview === host)
    }
    func testCCTVAndEnforcementDoNotShareClusters() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let points = try await store.mapCameras(in:.init(center:.init(25.04,121.51),radius:20_000),categories:Set(CameraCategory.allCases),showLimited:true)
        let parent = view(), map = MKMapView(), coordinator = parent.makeCoordinator()
        map.register(CameraPinView.self,forAnnotationViewWithReuseIdentifier:"camera")
        for category in CameraCategory.allCases {
            let point = try XCTUnwrap(points.first { $0.category == category })
            let annotation = CameraAnnotation(point)
            let marker = try XCTUnwrap(coordinator.mapView(map,viewFor:annotation) as? CameraPinView)
            XCTAssertEqual(marker.clusteringIdentifier,category == .sectionSpeed ? nil : (category == .cctv ? "cctv":"enforcement"))
            XCTAssertNotNil(marker.glyphImage); XCTAssertNotNil(marker.image)
            XCTAssertEqual(marker.image?.size,.init(width:34,height:34))
        }
    }
    func testClusterBadgeHasCategoryIconColorAndCountNotAmbiguousGray() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let points = try await store.mapCameras(in:.init(south:21.8,north:25.5,west:119.8,east:122.1),categories:Set(CameraCategory.allCases),showLimited:true)
        let map = MKMapView(), coordinator = view().makeCoordinator()
        map.register(CameraClusterView.self,forAnnotationViewWithReuseIdentifier:"cluster")
        for category in CameraCategory.allCases.filter({ $0 != .sectionSpeed }) {
            let members = points.filter { $0.category == category }.prefix(2).map(CameraAnnotation.init)
            XCTAssertEqual(members.count,2)
            let badge = try XCTUnwrap(coordinator.mapView(map,viewFor:MKClusterAnnotation(memberAnnotations:members)) as? CameraClusterView)
            XCTAssertEqual(badge.representedCategory,category)
            XCTAssertEqual(badge.frame.size,.init(width:66,height:36))
            XCTAssertEqual(badge.backgroundColor,TaiwanMapView.Coordinator.color(category))
            XCTAssertNil(badge.image)
            XCTAssertTrue(badge.accessibilityLabel?.contains("2 cameras") == true)
            XCTAssertEqual(badge.layer.shadowOpacity,0)
            XCTAssertFalse(badge.canShowCallout)
            badge.configure(category:category,count:2,mixed:true)
            XCTAssertEqual(badge.backgroundColor,.systemOrange)
            XCTAssertTrue(badge.accessibilityLabel?.contains("Mixed enforcement") == true)
        }
    }
    func testUnchangedCameraRetainsAnnotationButUpdatedMetadataReplacesIt() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let cameras = try await store.mapCameras(in:.init(center:.init(25.04,121.51),radius:20_000),categories:[.speed],showLimited:true)
        let camera = try XCTUnwrap(cameras.first)
        let map = MKMapView(), coordinator = view().makeCoordinator(); coordinator.map = map
        coordinator.updateCameras([camera])
        let original = try XCTUnwrap(map.annotations.compactMap { $0 as? CameraAnnotation }.first)
        coordinator.updateCameras([camera])
        XCTAssertTrue(map.annotations.contains { ($0 as? CameraAnnotation) === original })
        let revised = camera.validated(confidence:"B",enabled:false,note:"Updated source, hidden from alerts")
        coordinator.updateCameras([revised])
        let replacement = try XCTUnwrap(map.annotations.compactMap { $0 as? CameraAnnotation }.first)
        XCTAssertFalse(replacement === original); XCTAssertEqual(replacement.camera,revised)
        XCTAssertEqual(map.annotations.count,1)
    }
}
#endif
