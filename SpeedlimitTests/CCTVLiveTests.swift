import XCTest
#if SWIFT_PACKAGE
@testable import SpeedlimitCore
#else
@testable import Speedlimit
#endif

private final class CameraLiveProtocol: URLProtocol {
    final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String:Int] = [:]
        func record(_ url: String) { lock.lock(); requests[url,default:0] += 1; lock.unlock() }
        func count(_ url: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[url] ?? 0 }
    }
    static let ledger = Ledger()
    private let lock = NSLock()
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var index = 0
    private let queue = DispatchQueue(label:"test.cctv.video")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func frame(_ index: Int) -> Data {
        Data([0xff,0xd8,0xff,0xe1,0,4,UInt8(index%256),0])+CameraImageFixture.image().dropFirst(2)
    }
    override func startLoading() {
        let url = request.url!, mode = url.path.split(separator:"/").first.map(String.init) ?? ""
        Self.ledger.record(url.absoluteString)
        let multipart = ["video","burst","stall","truncated","hang"].contains(mode)
        let response = HTTPURLResponse(url:url,statusCode:mode == "offline" ? 503:200,httpVersion:"HTTP/1.1",headerFields:[
            "Content-Type":multipart ? "multipart/x-mixed-replace; boundary=camera":mode == "png" ? "image/png":mode == "html" ? "text/html":"image/jpeg",
            "Content-Length":mode == "burst" ? "9000000":"-1"
        ])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if mode == "offline" || mode == "html" { client?.urlProtocolDidFinishLoading(self); return }
        if mode == "hang" { return }
        if mode == "video" {
            emitFrame()
            let timer = DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now()+0.2,repeating:0.2)
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            lock.lock(); self.timer = timer; timer.resume(); if stopped { timer.cancel(); self.timer = nil }; lock.unlock()
        } else if mode == "burst" {
            var chunk = Data()
            for index in 0..<500 { chunk.append(Self.frame(index)) }
            client?.urlProtocol(self,didLoad:chunk); client?.urlProtocolDidFinishLoading(self)
        } else if mode == "stall" { emitFrame() }
        else {
            let bytes = mode == "png" ? CameraImageFixture.image(type:"public.png"):Self.frame(0)
            client?.urlProtocol(self,didLoad:mode == "truncated" ? Data(bytes.dropLast(2)):bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    private func emitFrame() {
        lock.lock(); let cancelled = stopped, index = self.index; self.index += 1; lock.unlock()
        guard !cancelled else { return }
        client?.urlProtocol(self,didLoad:Data("\r\n--camera\r\nContent-Type: image/jpeg\r\n\r\n".utf8)+Self.frame(index))
    }
    override func stopLoading() {
        lock.lock(); stopped = true; let timer = self.timer; self.timer = nil; lock.unlock(); timer?.cancel()
    }
}

final class CCTVLiveTests: XCTestCase {
    private func service(timeout: TimeInterval = 2) -> CCTVService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CameraLiveProtocol.self]
        return CCTVService(configuration:config,timeout:timeout)
    }
    private func url(_ mode: String) -> String { "https://camera.invalid/\(mode)/\(UUID().uuidString)" }
    func testLiveConnectionDeliversChangingFramesWithoutRepeatedRequestsOrSnapshotCache() async throws {
        let service = service(), url = url("video"), feed = try await service.live(urlString:url)
        defer { feed.cancel() }
        var images: [Data] = [], dates: [Date] = []
        for try await frame in feed.frames {
            XCTAssertTrue(frame.isContinuous)
            images.append(frame.snapshot.data); dates.append(frame.snapshot.downloadedAt)
            if images.count == 3 { break }
        }
        XCTAssertEqual(Set(images).count,3)
        XCTAssertGreaterThanOrEqual(dates[2].timeIntervalSince(dates[0]),0.9)
        XCTAssertEqual(CameraLiveProtocol.ledger.count(url),1)
        let cached = await service.cachedByteCount(); XCTAssertEqual(cached,0)
    }
    func testSlowConsumerKeepsNewestFrameNotGrowingBacklog() async throws {
        let feed = try await service().live(urlString:url("video")), start = Date()
        defer { feed.cancel() }
        try await Task.sleep(for:.milliseconds(1400))
        var iterator = feed.frames.makeAsyncIterator()
        let next = try await iterator.next(), frame = try XCTUnwrap(next)
        XCTAssertGreaterThan(frame.snapshot.downloadedAt.timeIntervalSince(start),0.8)
        XCTAssertNotEqual(frame.snapshot.data,CameraLiveProtocol.frame(0))
    }
    func testBurstDrainsAllFramesAndKeepsOnlyLatestEvenWithLargeTotalContentLength() async throws {
        let feed = try await service().live(urlString:url("burst"))
        defer { feed.cancel() }
        var frames: [CameraVideoFrame] = []
        for try await frame in feed.frames { frames.append(frame) }
        XCTAssertEqual(frames.count,1); XCTAssertEqual(frames[0].snapshot.data,CameraLiveProtocol.frame(499))
    }
    func testStillJPEGAndPNGAreNeverLabelledContinuousVideo() async throws {
        for mode in ["still","png"] {
            let feed = try await service().live(urlString:url(mode))
            var frames: [CameraVideoFrame] = []
            for try await frame in feed.frames { frames.append(frame) }
            XCTAssertEqual(frames.count,1); XCTAssertFalse(frames[0].isContinuous)
            feed.cancel()
        }
    }
    func testNativeMultipartResponsePerImageKeepsConnectionOpenAndPromotesToLive() async throws {
        let channel = AsyncThrowingStream<CameraVideoFrame,Error>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let download = CCTVStreamDownload(continuation:channel.continuation,configuration:.ephemeral,timeout:2)
        let session = URLSession(configuration:.ephemeral), url = URL(string:self.url("parts"))!, task = session.dataTask(with:url)
        defer { download.cancel(); session.invalidateAndCancel() }
        let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"image/jpeg"])!
        var iterator = channel.stream.makeAsyncIterator()
        download.urlSession(session,dataTask:task,didReceive:response) { XCTAssertEqual($0,.allow) }
        download.urlSession(session,dataTask:task,didReceive:CameraLiveProtocol.frame(0))
        let first = try await iterator.next()
        XCTAssertNotNil(first); XCTAssertFalse(first?.isContinuous ?? true)
        try await Task.sleep(for:.milliseconds(550))
        download.urlSession(session,dataTask:task,didReceive:response) { XCTAssertEqual($0,.allow) }
        download.urlSession(session,dataTask:task,didReceive:CameraLiveProtocol.frame(1))
        let second = try await iterator.next()
        XCTAssertEqual(second?.snapshot.data,CameraLiveProtocol.frame(1)); XCTAssertTrue(second?.isContinuous == true)
        download.urlSession(session,task:task,didCompleteWithError:nil)
        let end = try await iterator.next(); XCTAssertNil(end)
    }
    func testFrameStallTimeoutDoesNotWaitIndefinitely() async throws {
        let feed = try await service(timeout:0.15).live(urlString:url("stall")), start = Date()
        var count = 0
        do {
            for try await _ in feed.frames { count += 1 }
            XCTFail("Expected idle deadline")
        } catch { XCTAssertEqual(error.localizedDescription,CCTVError.timedOut.localizedDescription) }
        XCTAssertEqual(count,1); XCTAssertLessThan(Date().timeIntervalSince(start),1)
    }
    func testLiveStartupDeadlineAndUnsupportedOrIncompleteFeeds() async throws {
        for mode in ["hang","html","offline","truncated"] {
            let feed = try await service(timeout:0.15).live(urlString:url(mode)), start = Date()
            do { for try await _ in feed.frames {}; XCTFail("Must reject \(mode)") }
            catch { XCTAssertTrue(error is CCTVError) }
            XCTAssertLessThan(Date().timeIntervalSince(start),1)
        }
    }
    func testCancellationKeepsReconnectCooldownAndEndsPromptly() async throws {
        let service = service(), url = url("hang"), feed = try await service.live(urlString:url)
        let consumer = Task { for try await _ in feed.frames {} }
        try await Task.sleep(for:.milliseconds(20)); let start = Date(); consumer.cancel()
        do { try await consumer.value } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start),0.5)
        let next = await service.nextRequestDate(urlString:url); XCTAssertGreaterThan(try XCTUnwrap(next).timeIntervalSinceNow,58)
        do { _ = try await service.live(urlString:url); XCTFail("Must not bypass reconnect limit") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.wait.localizedDescription) }
    }
    func testOnlyOneCameraCanStreamAndMemoryWarningStopsIt() async throws {
        let service = service(), first = try await service.live(urlString:url("hang"))
        let second = try await service.live(urlString:url("hang"))
        do { for try await _ in first.frames {}; XCTFail("New camera must cancel old connection") }
        catch { XCTAssertTrue(error is CancellationError) }
        await service.releaseMemory()
        do { for try await _ in second.frames {}; XCTFail("Memory warning must cancel video") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testVideoAndSnapshotURLsShareSameCameraCooldown() async throws {
        let service = service(), snapshot = url("still"), stream = url("video")
        let feed = try await service.live(urlString:stream,snapshotURLString:snapshot)
        feed.cancel()
        do { _ = try await service.snapshot(urlString:snapshot,streamURLString:stream); XCTFail("Cannot bypass cooldown using snapshot URL") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.wait.localizedDescription) }
        let other = self.service(), snapshot2 = url("still"), stream2 = url("video")
        _ = try await other.snapshot(urlString:snapshot2,streamURLString:stream2)
        do { _ = try await other.live(urlString:stream2,snapshotURLString:snapshot2); XCTFail("Cannot bypass cooldown using stream URL") }
        catch { XCTAssertEqual(error.localizedDescription,CCTVError.wait.localizedDescription) }
    }
    func testLiveRejectsInsecureAndCredentialURLs() async throws {
        let service = service()
        for url in ["http://camera.invalid/video","https://name:secret@camera.invalid/video"] {
            do { _ = try await service.live(urlString:url); XCTFail("Must reject unsafe URL") }
            catch { XCTAssertEqual(error.localizedDescription,CCTVError.invalidURL.localizedDescription) }
        }
    }
    #if !SWIFT_PACKAGE
    @MainActor private func waitForFrames(_ model: CCTVImageModel, count: Int = 2) async throws {
        let end = Date().addingTimeInterval(4)
        while model.receivedFrames < count, Date() < end { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(model.receivedFrames,count)
    }
    @MainActor func testLiveViewPauseAndDismissalStopUpdatesAndReleaseImage() async throws {
        let service = service(), stream = url("video"), model = CCTVImageModel(service:service)
        model.play(url:url("still"),streamURL:stream)
        try await waitForFrames(model)
        XCTAssertTrue(model.isLive); XCTAssertFalse(model.loading); XCTAssertNotNil(model.image)
        model.pause(); let count = model.receivedFrames
        try await Task.sleep(for:.milliseconds(750))
        XCTAssertEqual(model.receivedFrames,count); XCTAssertNotNil(model.image)
        XCTAssertFalse(model.isLive); XCTAssertFalse(model.playing); XCTAssertGreaterThan(model.cooldown,0)
        XCTAssertEqual(CameraLiveProtocol.ledger.count(stream),1)
        model.stop(); XCTAssertNil(model.image); XCTAssertNil(model.downloadedAt)
    }
    @MainActor func testLiveFramesBypassDecodedSnapshotCache() async throws {
        SnapshotDecoder.releaseMemory()
        let model = CCTVImageModel(service:service())
        model.play(url:url("still"),streamURL:url("video")); try await waitForFrames(model,count:3)
        let usage = SnapshotDecoder.cacheUsage(); XCTAssertEqual(usage.count,0); XCTAssertEqual(usage.bytes,0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(model.image?.cgImage).width,SnapshotDecoder.maximumPixelSize)
        model.stop()
    }
    @MainActor func testStillFeedFallsBackHonestlyWithoutRapidSnapshotPolling() async throws {
        let stream = url("still"), snapshot = url("still"), model = CCTVImageModel(service:service())
        model.play(url:snapshot,streamURL:stream); try await waitForFrames(model,count:1)
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(model.isLive); XCTAssertTrue(model.autoRefreshing); XCTAssertGreaterThan(model.cooldown,0)
        XCTAssertEqual(CameraLiveProtocol.ledger.count(stream),1); XCTAssertEqual(CameraLiveProtocol.ledger.count(snapshot),0)
        model.stop()
    }
    @MainActor func testSnapshotOnlyCameraAutoRefreshModeAndMemoryCleanup() async throws {
        let service = service(), model = CCTVImageModel(service:service)
        model.play(url:url("still"),streamURL:nil); try await waitForFrames(model,count:1)
        XCTAssertTrue(model.autoRefreshing); XCTAssertFalse(model.isLive); XCTAssertNotNil(model.image)
        model.stop(); XCTAssertNil(model.image); XCTAssertFalse(model.playing)
        let live = CCTVImageModel(service:service)
        live.play(url:url("still"),streamURL:url("video")); try await waitForFrames(live)
        await service.releaseMemory(); try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(live.playing); XCTAssertNil(live.image)
    }
    @MainActor func testFailedVideoUsesSnapshotFallbackButRespectsSameCameraInterval() async throws {
        let snapshot = url("still"), model = CCTVImageModel(service:service())
        model.play(url:snapshot,streamURL:url("offline"))
        let end = Date().addingTimeInterval(2)
        while !model.autoRefreshing, Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(model.autoRefreshing); XCTAssertGreaterThan(model.cooldown,0)
        XCTAssertTrue(model.error?.contains("503") == true); XCTAssertEqual(CameraLiveProtocol.ledger.count(snapshot),0)
        model.stop()
    }
    @MainActor func testDismissedLiveTaskCannotPublishOverAnotherCamera() async throws {
        let model = CCTVImageModel(service:service())
        model.play(url:url("still"),streamURL:url("hang"))
        try await Task.sleep(for:.milliseconds(20)); model.stop()
        model.play(url:url("still"),streamURL:url("video")); try await waitForFrames(model)
        XCTAssertTrue(model.isLive); XCTAssertNil(model.error)
        model.stop(); let frames = model.receivedFrames
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertEqual(model.receivedFrames,frames); XCTAssertNil(model.image); XCTAssertFalse(model.loading)
    }
    #endif
}
