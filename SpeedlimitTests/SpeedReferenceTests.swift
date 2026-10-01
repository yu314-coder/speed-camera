import XCTest
import SQLite3
#if SWIFT_PACKAGE
@testable import SpeedlimitCore
#else
@testable import Speedlimit
#endif

final class SpeedReferenceTests: XCTestCase {
    func testOfficialReferencesKeepConditionalLimitsAndSearchAliases() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let entries = try await store.speedReferences(), summary = try await store.summary()
        XCTAssertEqual(entries.count,84); XCTAssertEqual(summary.speedReferences,84)
        XCTAssertEqual(summary.speedRoads,453)
        XCTAssertNotNil(summary.speedReferencesCheckedAt)
        let route = entries.filter { $0.matches(tokens:SpeedLimitReference.tokens("臺64"),scope:.all) }
        XCTAssertEqual(route.count,2)
        let conditional = try XCTUnwrap(route.first { $0.limitText.contains("彎道") })
        XCTAssertNil(conditional.numericLimit)
        XCTAssertEqual(conditional.limitText,"直線段：70、彎道段：60")
        XCTAssertTrue(conditional.conditions.contains("側車道"))
        XCTAssertTrue(conditional.matches(tokens:SpeedLimitReference.tokens("台64 14k+500"),scope:.expressway))
        XCTAssertFalse(conditional.matches(tokens:[],scope:.taipei))
        XCTAssertEqual(entries.filter { $0.sourceID == "121671" && $0.numericLimit == 30 }.count,3)
        let freeway = try XCTUnwrap(entries.first { $0.roadRef == "國道3甲" })
        XCTAssertTrue(freeway.segment.contains("70")); XCTAssertTrue(freeway.conditions.contains("20公噸"))
    }
    func testLegacyDatabaseWithoutOptionalReferencesStillLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-speed-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at:url) }
        try FileManager.default.copyItem(at:TrafficStore.bundledURL(),to:url)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"DROP TABLE speed_limit_references",nil,nil,nil),SQLITE_OK); sqlite3_close(db)
        let store = try TrafficStore(url:url)
        let entries = try await store.speedReferences(), summary = try await store.summary()
        XCTAssertTrue(entries.isEmpty); XCTAssertEqual(summary.speedReferences,0)
        XCTAssertGreaterThan(summary.cameras,0)
    }
    func testLayerCountsDoNotConfuseCameraGroupsWithSectionEndpoints() async throws {
        let store = try TrafficStore(url:TrafficStore.bundledURL())
        let bounds = MapBounds(south:21.8,north:25.5,west:119.8,east:122.1)
        let cameras = try await store.mapCameras(in:bounds,categories:Set(CameraCategory.allCases),showLimited:true)
        let zones = try await store.sections(in:bounds)
        let counts = MapLayerCounts(cameras:cameras,zones:zones)
        XCTAssertEqual(counts.cctv,cameras.filter { $0.category == .cctv }.count)
        XCTAssertEqual(counts.endpoints,11); XCTAssertEqual(counts.corridors,38)
        XCTAssertTrue(counts.accessibilitySummary.contains("CCTV markers"))
        XCTAssertTrue(counts.hasOSMShapes)
    }
}
