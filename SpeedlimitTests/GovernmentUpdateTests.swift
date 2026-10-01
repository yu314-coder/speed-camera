import XCTest
import SQLite3
#if SWIFT_PACKAGE
@testable import SpeedlimitCore
#else
@testable import Speedlimit
#endif

private actor GovernmentFeedFixture {
    var calls = 0
    var version = 1
    var failed: GovernmentFeedKind?
    var customPolice: Data?
    var delay: Duration?
    func configure(version: Int = 1, failed: GovernmentFeedKind? = nil, police: Data? = nil, delay: Duration? = nil) {
        self.version = version; self.failed = failed; customPolice = police; self.delay = delay
    }
    func count() -> Int { calls }
    func download(_ url: URL, etag: String?, modified: String?) async throws -> GovernmentDataUpdater.Response {
        calls += 1
        if let delay { try await Task.sleep(for:delay) }
        if url == GovernmentFeedKind.police.url {
            return .init(data:Data("""
                {"result":{"datasetId":7320,"modifiedDate":"2026-10-01","distribution":[{"resourceFormat":"CSV","resourceDownloadUrl":"https://opdadm.moi.gov.tw/fixture.csv"}]}}
                """.utf8),etag:nil,lastModified:nil,notModified:false)
        }
        let kind: GovernmentFeedKind = url.path == "/fixture.csv" ? .police:(url == GovernmentFeedKind.freeway.url ? .freeway:.provincial)
        if failed == kind { throw URLError(.notConnectedToInternet) }
        let tag = "v\(version)-\(kind.rawValue)"+(kind == .police && customPolice != nil ? "-custom":"")
        if etag == tag { return .init(data:Data(),etag:tag,lastModified:nil,notModified:true) }
        let data: Data
        if kind == .police {
            data = customPolice ?? GovernmentUpdateTests.policeCSV("金門縣,金湖鎮,和平路\(version)段,警局,分局,121.51,25.041,南向北,50")
        } else {
            data = GovernmentUpdateTests.cctvXML(id:"fixture-\(version)",road:"國道1號",stream:"https://cctvn.freeway.gov.tw/abs2mjpg/bmjpg?camera=10000")
        }
        return .init(data:data,etag:tag,lastModified:"Thu, 01 Oct 2026 00:00:00 GMT",notModified:false)
    }
}

final class GovernmentUpdateTests: XCTestCase {
    static func policeCSV(_ rows: String) -> Data {
        Data(("\u{FEFF}CityName,RegionName,Address,DeptNm,BranchNm,Longitude,Latitude,direct,limit\r\n" +
              "設置縣市,設置市區鄉鎮,設置地址,管轄警局,管轄分局,經度,緯度,拍攝方向,速限\r\n" + rows + "\r\n").utf8)
    }
    static func cctvXML(id: String = "fixture", road: String = "國道1號", lon: String = "121.51", endpoint: String = "https://cctvn.freeway.gov.tw/image", stream: String? = nil) -> Data {
        Data("""
            <CCTVList xmlns="http://traffic.transportdata.tw/standard/traffic/schema/">
            <UpdateTime>2026-10-01T00:00:00+08:00</UpdateTime><CCTVs><CCTV>
            <CCTVID>\(id)</CCTVID><RoadName>\(road)</RoadName><RoadDirection>N</RoadDirection>
            <PositionLon>\(lon)</PositionLon><PositionLat>25.041</PositionLat><VideoImageURL>\(endpoint)</VideoImageURL>
            \(stream.map { "<VideoStreamURL>\($0)</VideoStreamURL>" } ?? "")
            </CCTV></CCTVs></CCTVList>
            """.utf8)
    }
    private func fixture() throws -> (root: URL, bundle: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("government-tests-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bundle = root.appendingPathComponent("bundle.db")
        try FileManager.default.copyItem(at:TrafficStore.bundledURL(),to:bundle)
        try execute(bundle,"DELETE FROM camera_points WHERE source_dataset_id IN ('7320','freeway_cctv','thb_cctv'); DELETE FROM camera_rtree WHERE rowid NOT IN (SELECT rowid FROM camera_points)")
        return (root,bundle,root.appendingPathComponent("cache",isDirectory:true))
    }
    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
    }
    private func updater(_ fixture: (root: URL,bundle: URL,cache: URL), server: GovernmentFeedFixture) -> GovernmentDataUpdater {
        .init(directory:fixture.cache,bundle:fixture.bundle,minimumRecords:1,downloader:{ url,etag,modified in
            try await server.download(url,etag:etag,modified:modified)
        })
    }
    func testDualHeaderCSVQuotingAndExplicitDirection() throws {
        let data = Self.policeCSV("台北市,中山區,\"和平路,路口\",警局,分局,121.51,25.041,南向北,50")
        let parsed = try GovernmentFeedParser.parse(.police,data:data,minimumRecords:1)
        XCTAssertEqual(parsed.publishedCount,1); XCTAssertEqual(parsed.cameras.count,1)
        XCTAssertEqual(parsed.cameras[0].roadName,"和平路,路口")
        XCTAssertEqual(parsed.cameras[0].bearings,[0])
        XCTAssertFalse(parsed.cameras[0].isAlertEnabled)
        XCTAssertEqual(try GovernmentFeedParser.csv("name,value\r\n\"a\"\"b\nline\",c\r\n"),[["name","value"],["a\"b\nline","c"]])
        XCTAssertThrowsError(try GovernmentFeedParser.csv("header\n\"unclosed"))
        XCTAssertThrowsError(try GovernmentFeedParser.csv("header\n\"closed\"junk"))
    }
    func testBig5DecodingAndDirectionAmbiguity() throws {
        let text = String(data:Self.policeCSV("台北市,中山區,和平路,警局,分局,121.51,25.041,雙向,50"),encoding:.utf8)!.replacingOccurrences(of:"\u{FEFF}",with:"")
        let encoding = String.Encoding(rawValue:0x80000A03)
        let data = try XCTUnwrap(text.data(using:encoding))
        let parsed = try GovernmentFeedParser.parse(.police,data:data,minimumRecords:1)
        XCTAssertEqual(parsed.cameras.first?.roadName,"和平路")
        XCTAssertEqual(parsed.cameras.first?.bearings,[])
        XCTAssertEqual(GovernmentFeedParser.bearings("南北雙向"),[0,180])
        XCTAssertEqual(GovernmentFeedParser.bearings("西向東北"),[45])
    }
    func testRejectsWrongCoordinatesSchemaHTMLAndXMLThreats() throws {
        XCTAssertThrowsError(try GovernmentFeedParser.parse(.police,data:Self.policeCSV("x,x,台61,x,x,25.1,121.5,北上,90"),minimumRecords:1))
        XCTAssertThrowsError(try GovernmentFeedParser.parse(.police,data:Data("<html>blocked</html>".utf8),minimumRecords:1))
        XCTAssertThrowsError(try GovernmentFeedParser.parse(.freeway,data:Self.cctvXML(lon:"0"),minimumRecords:1))
        XCTAssertThrowsError(try GovernmentFeedParser.parse(.freeway,data:Self.cctvXML(endpoint:"https://example.com/image"),minimumRecords:1))
        XCTAssertThrowsError(try GovernmentFeedParser.parse(.freeway,data:Data("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><x>&a;</x>".utf8),minimumRecords:1))
        XCTAssertThrowsError(try GovernmentFeedParser.parse(.freeway,data:Data(repeating:0,count:8_000_001),minimumRecords:1))
        XCTAssertNil(GovernmentFeedParser.secureGovernmentURL("http://data.gov.tw/file"))
        XCTAssertNil(GovernmentFeedParser.secureGovernmentURL("https://data.gov.tw.evil.com/file"))
        XCTAssertNil(GovernmentFeedParser.secureGovernmentURL("https://user:secret@data.gov.tw/file"))
    }
    func testCCTVUsesPublishedCoordinatesAndIsNeverEnforcement() throws {
        let feed = try GovernmentFeedParser.parse(.freeway,data:Self.cctvXML(),minimumRecords:1)
        let camera = try XCTUnwrap(feed.cameras.first)
        XCTAssertEqual(camera.id,"freeway:fixture"); XCTAssertEqual(camera.category,.cctv)
        XCTAssertEqual(camera.coordinate,.init(25.041,121.51)); XCTAssertEqual(camera.roadRef,"國道1")
        XCTAssertFalse(camera.isAlertEnabled); XCTAssertNil(camera.speedLimit)
        XCTAssertEqual(feed.updated,"2026-10-01T00:00:00+08:00")
    }
    func testCCTVPreservesSeparatePublishedStreamAndNeverGuessesVideoURL() throws {
        let snapshot = "https://cctv-ss02.thb.gov.tw/T62-9K+020/snapshot", stream = "https://cctv-ss02.thb.gov.tw/T62-9K+020"
        let parsed = try GovernmentFeedParser.parse(.provincial,data:Self.cctvXML(endpoint:snapshot,stream:stream),minimumRecords:1)
        let camera = try XCTUnwrap(parsed.cameras.first)
        XCTAssertEqual(camera.cctvURL,snapshot); XCTAssertEqual(camera.cctvStreamURL,stream)
        XCTAssertEqual(camera.validated(confidence:"B",enabled:false,note:"Still official").cctvStreamURL,stream)
        let onlySnapshot = try GovernmentFeedParser.parse(.provincial,data:Self.cctvXML(endpoint:snapshot),minimumRecords:1)
        XCTAssertNil(onlySnapshot.cameras.first?.cctvStreamURL)
        let unsafe = try GovernmentFeedParser.parse(.provincial,data:Self.cctvXML(endpoint:snapshot,stream:"https://example.com/video"),minimumRecords:1)
        XCTAssertNil(unsafe.cameras.first?.cctvStreamURL)
    }
    func testOlderCacheRefetchesUnchangedCCTVOnceToRecoverStreamURLs() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture(), updater = updater(fixture,server:server), now = Date()
        _ = await updater.refresh(force:true,now:now)
        let statusURL = fixture.cache.appendingPathComponent("refresh-status.json")
        var report = await updater.status()
        for index in report.sources.indices { report.sources[index].parserVersion = nil }
        try JSONEncoder().encode(report).write(to:statusURL,options:.atomic)
        let cached = fixture.cache.appendingPathComponent("current.db")
        try execute(cached,"ALTER TABLE camera_points DROP COLUMN cctv_stream_endpoint")
        let old = try TrafficStore(url:cached)
        let oldPoints = try await old.cameras(in:.init(center:.init(25.041,121.51),radius:50),categories:[.cctv])
        XCTAssertFalse(oldPoints.isEmpty); XCTAssertTrue(oldPoints.allSatisfy { $0.cctvStreamURL == nil })
        let oldCalls = await server.count()
        report = await updater.refresh(now:now.addingTimeInterval(60))
        XCTAssertTrue(report.snapshotChanged); XCTAssertFalse(report.hasFailures)
        let calls = await server.count(); XCTAssertEqual(calls,oldCalls+2)
        let reopened = try TrafficStore(url:cached)
        let points = try await reopened.cameras(in:.init(center:.init(25.041,121.51),radius:50),categories:[.cctv])
        XCTAssertEqual(points.count,2); XCTAssertTrue(points.allSatisfy { $0.cctvStreamURL != nil })
        _ = await updater.refresh(now:now.addingTimeInterval(120))
        let noRepeat = await server.count(); XCTAssertEqual(noRepeat,calls)
    }
    func testAtomicUpdateAddsNewCamerasAndOfflineReopenPreservesSections() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture(), updater = updater(fixture,server:server)
        let before = try TrafficStore(url:fixture.bundle), beforeSummary = try await before.summary()
        let report = await updater.refresh(force:true)
        XCTAssertTrue(report.snapshotChanged); XCTAssertFalse(report.hasFailures)
        let active = TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache)
        XCTAssertNotEqual(active,fixture.bundle)
        let reopened = try TrafficStore(url:active), summary = try await reopened.summary()
        XCTAssertEqual(summary.sections,beforeSummary.sections); XCTAssertEqual(summary.verifiedSections,beforeSummary.verifiedSections)
        XCTAssertEqual(summary.roads,beforeSummary.roads); XCTAssertEqual(summary.cctv,2)
        XCTAssertEqual(summary.speedReferences,beforeSummary.speedReferences)
        let references = try await reopened.speedReferences()
        XCTAssertEqual(references.count,84)
        XCTAssertNotNil(summary.governmentUpdatedAt)
        let original = try await before.summary()
        XCTAssertEqual(original.cctv,beforeSummary.cctv)
        let points = try await reopened.cameras(in:.init(center:.init(25.041,121.51),radius:50),categories:[.speed,.cctv])
        XCTAssertEqual(points.filter { $0.sourceID == "7320" }.count,1)
        XCTAssertEqual(points.filter { $0.category == .cctv }.count,2)
        await server.configure(failed:.police)
        _ = await updater.refresh(force:true)
        let lastWorking = try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache))
        let retained = try await lastWorking.summary()
        XCTAssertEqual(retained.cameras,summary.cameras)
    }
    func testDailyCadenceConditionalRequestsAndPartialFailureRetainData() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture(), updater = updater(fixture,server:server), now = Date()
        _ = await updater.refresh(force:true,now:now)
        let firstCalls = await server.count()
        XCTAssertEqual(firstCalls,4)
        let unchanged = await updater.refresh(now:now.addingTimeInterval(60))
        XCTAssertFalse(unchanged.snapshotChanged)
        let secondCalls = await server.count(); XCTAssertEqual(firstCalls,secondCalls)
        let checked = await updater.refresh(now:now.addingTimeInterval(90_000))
        XCTAssertFalse(checked.snapshotChanged); XCTAssertTrue(checked.sources.allSatisfy { $0.status == "Up to date" })
        await server.configure(version:2,failed:.police)
        let partial = await updater.refresh(force:true,now:now.addingTimeInterval(180_000))
        XCTAssertTrue(partial.snapshotChanged); XCTAssertTrue(partial.hasFailures)
        XCTAssertEqual(partial.sources.first { $0.id == "7320" }?.status,"Previous data retained")
        let store = try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache))
        let points = try await store.cameras(in:.init(center:.init(25.041,121.51),radius:50),categories:[.speed,.cctv])
        XCTAssertTrue(points.contains { $0.roadName == "和平路1段" })
        XCTAssertTrue(points.contains { $0.id == "freeway:fixture-2" })
        XCTAssertFalse(points.contains { $0.id == "freeway:fixture-1" })
    }
    func testMalformedDownloadAndCancellationCannotReplaceSnapshot() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture(), updater = updater(fixture,server:server)
        _ = await updater.refresh(force:true)
        let active = TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache)
        let bytes = try Data(contentsOf:active)
        await server.configure(police:Data("bad,columns\n1,2".utf8))
        let result = await updater.refresh(force:true)
        XCTAssertTrue(result.hasFailures); XCTAssertFalse(result.snapshotChanged)
        XCTAssertEqual(try Data(contentsOf:active),bytes)
        await server.configure(version:2,delay:.milliseconds(200))
        let task = Task { await updater.refresh(force:true) }
        try await Task.sleep(for:.milliseconds(30)); task.cancel(); _ = await task.value
        XCTAssertEqual(try Data(contentsOf:active),bytes)
        let files = try FileManager.default.contentsOfDirectory(atPath:fixture.cache.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("staged-") })
    }
    func testNewSectionEndpointAndUnknownDirectionRemainHiddenFromAlerts() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture()
        await server.configure(police:Self.policeCSV("x,x,和平路區間測速,x,x,121.51,25.041,南向北,50\r\nx,x,和平路2段,x,x,121.511,25.041,雙向,50"))
        let report = await updater(fixture,server:server).refresh(force:true)
        XCTAssertFalse(report.hasFailures)
        let store = try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache))
        let points = try await store.enforcementCameras().filter { $0.sourceID == "7320" }
        XCTAssertEqual(points.count,2); XCTAssertTrue(points.allSatisfy { !$0.isAlertEnabled })
        XCTAssertEqual(points.first { $0.category == .sectionSpeed }?.sectionID,nil)
        XCTAssertTrue(points.allSatisfy { $0.confidence == "B" })
    }
    func testThreeConflictingDuplicatesNeverRegainAlertEligibility() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture()
        await server.configure(police:Self.policeCSV([50,60,60].map { "x,x,和平路,x,x,121.51,25.041,南向北,\($0)" }.joined(separator:"\r\n")))
        let report = await updater(fixture,server:server).refresh(force:true)
        XCTAssertFalse(report.hasFailures)
        let store = try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache))
        let points = try await store.enforcementCameras().filter { $0.sourceID == "7320" }
        XCTAssertEqual(points.count,1); XCTAssertFalse(points[0].isAlertEnabled)
        XCTAssertNil(points[0].speedLimit)
        XCTAssertTrue(points[0].qualityNote.contains("Conflicting"))
    }
    func testTruncatedFirstRefreshCannotRemoveMostPublishedCameras() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let rows = (0..<240).map { "x,x,和平路\($0)段,x,x,121.51,\(25.04+Double($0)*0.00001),南向北,50" }.joined(separator:"\r\n")
        let parsed = try GovernmentFeedParser.parse(.police,data:Self.policeCSV(rows),minimumRecords:1)
        try TrafficDatabaseFiles.publish(base:fixture.bundle,bundle:fixture.bundle,directory:fixture.cache,feeds:[(.police,parsed)],now:Date())
        let server = GovernmentFeedFixture()
        let report = await updater(fixture,server:server).refresh(force:true)
        XCTAssertTrue(report.hasFailures)
        XCTAssertTrue(report.sources.first { $0.id == "7320" }?.error?.contains("20%") == true)
        let store = try TrafficStore(url:TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache))
        let counts = try await store.cameraSourceCounts()
        XCTAssertEqual(counts["7320"],240)
    }
    func testNewBundledRevisionAndCorruptCacheFallBackSafely() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture()
        _ = await updater(fixture,server:server).refresh(force:true)
        try execute(fixture.bundle,"UPDATE build_metadata SET value='2099-01-01' WHERE key='built_at'")
        XCTAssertEqual(TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache),fixture.bundle)
        try Data("corrupt".utf8).write(to:fixture.cache.appendingPathComponent("current.db"),options:.atomic)
        XCTAssertEqual(TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache),fixture.bundle)
    }
    func testReferenceOnlyRevisionInvalidatesOlderCacheWithoutPretendingCameraFreshness() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at:fixture.root) }
        let server = GovernmentFeedFixture(), updater = updater(fixture,server:server), now = Date()
        _ = await updater.refresh(force:true,now:now)
        let beforeCalls = await server.count()
        let cached = TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache)
        XCTAssertNotEqual(cached,fixture.bundle)
        let built = TrafficDatabaseFiles.metadata(fixture.bundle,key:"built_at")
        try execute(fixture.bundle,"INSERT OR REPLACE INTO build_metadata VALUES ('snapshot_revision','new-reference-only-revision')")
        XCTAssertEqual(TrafficDatabaseFiles.metadata(fixture.bundle,key:"built_at"),built)
        XCTAssertEqual(TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache),fixture.bundle)
        let report = await updater.refresh(now:now.addingTimeInterval(5))
        XCTAssertTrue(report.snapshotChanged)
        XCTAssertFalse(report.hasFailures)
        let calls = await server.count(); XCTAssertEqual(calls,beforeCalls+4)
        XCTAssertNotEqual(TrafficDatabaseFiles.activeURL(bundle:fixture.bundle,directory:fixture.cache),fixture.bundle)
    }
}
