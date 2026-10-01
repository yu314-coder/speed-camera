import Foundation

struct CameraVideoFrame: Sendable {
    let snapshot: CameraSnapshot
    let isContinuous: Bool
}

struct CCTVLiveFeed: Sendable {
    let frames: AsyncThrowingStream<CameraVideoFrame,Error>
    private let download: CCTVStreamDownload
    init(url: URL, configuration: URLSessionConfiguration, timeout: TimeInterval) {
        let channel = AsyncThrowingStream<CameraVideoFrame,Error>.makeStream(bufferingPolicy:.bufferingNewest(1))
        frames = channel.stream
        download = CCTVStreamDownload(continuation:channel.continuation,configuration:configuration,timeout:timeout)
        channel.continuation.onTermination = { [weak download] _ in download?.cancel() }
        download.start(url)
    }
    func cancel() { download.cancel() }
}

// One selected camera connection, bounded JPEG state and a one-frame queue. No per-frame URL requests.
final class CCTVStreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<CameraVideoFrame,Error>.Continuation
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var parser = JPEGFrameParser(continuous:true)
    private var png = Data()
    private var completed = false, isMultipart = false, isPNG = false, receivedFrame = false
    private var responseCount = 0
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var lastPublished = -Double.infinity
    init(continuation: AsyncThrowingStream<CameraVideoFrame,Error>.Continuation,
         configuration: URLSessionConfiguration, timeout: TimeInterval) {
        self.continuation = continuation; self.configuration = configuration; self.timeout = timeout
    }
    func start(_ url: URL) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
        self.session = session
        let timer = DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        timer.schedule(deadline:.now()+timeout,repeating:min(1,timeout/4),leeway:.milliseconds(10))
        timer.setEventHandler { [weak self] in self?.checkDeadline() }
        self.timer = timer
        var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData)
        request.setValue("multipart/x-mixed-replace, image/jpeg, image/png",forHTTPHeaderField:"Accept")
        let task = session.dataTask(with:request)
        lock.unlock()
        timer.resume(); task.resume()
    }
    func cancel() { finish(CancellationError()) }
    private func checkDeadline() {
        lock.lock()
        let stale = !completed && ProcessInfo.processInfo.systemUptime-lastFrame >= timeout
        lock.unlock()
        if stale { finish(CCTVError.timedOut) }
    }
    private func finish(_ error: Error? = nil) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let session = self.session, timer = self.timer
        self.session = nil; self.timer = nil; parser = .init(continuous:true); png = Data()
        lock.unlock()
        timer?.cancel(); session?.invalidateAndCancel()
        if let error { continuation.finish(throwing:error) } else { continuation.finish() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.url?.scheme == "https" else { completionHandler(.cancel); finish(CCTVError.invalidURL); return }
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(CCTVError.unavailable); return }
        guard (200..<300).contains(http.statusCode) else { completionHandler(.cancel); finish(CCTVError.http(http.statusCode)); return }
        let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
        guard ["multipart/x-mixed-replace","image/jpeg","image/jpg","image/png","application/octet-stream"].contains(mime) else {
            completionHandler(.cancel); finish(CCTVError.unsupportedFormat); return
        }
        let multipart = mime == "multipart/x-mixed-replace"
        guard multipart || response.expectedContentLength <= JPEGFrameParser.maximumBytes else {
            completionHandler(.cancel); finish(CCTVError.imageTooLarge); return
        }
        lock.lock()
        responseCount += 1
        // CFNetwork may remove multipart boundaries and call this delegate once per JPEG part.
        // Never close on the first image: a second response confirms the native multipart stream.
        isMultipart = isMultipart || multipart || responseCount > 1
        isPNG = mime == "image/png"
        if responseCount > 1 { parser = .init(continuous:true); png = Data() }
        let stopped = completed
        lock.unlock()
        completionHandler(stopped ? .cancel:.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var output: CameraVideoFrame?, error: Error?
        lock.lock()
        guard !completed else { lock.unlock(); return }
        do {
            var latest: Data?
            if isPNG {
                guard png.count+data.count <= JPEGFrameParser.maximumBytes else { throw CCTVError.imageTooLarge }
                png.append(data)
                if png.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]),
                   png.suffix(12).elementsEqual([0,0,0,0,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82]) {
                    latest = png; png = Data(); receivedFrame = true; lastFrame = ProcessInfo.processInfo.systemUptime
                }
            } else {
                var frame = try parser.append(data)
                while let bytes = frame {
                    latest = bytes; lastFrame = ProcessInfo.processInfo.systemUptime; receivedFrame = true
                    if !isMultipart { break }
                    frame = try parser.append(Data())
                }
            }
            // Drop superseded frames before decoding or publishing SwiftUI state (at most 2 fps).
            if let latest, lastFrame-lastPublished >= 0.5 {
                lastPublished = lastFrame
                output = .init(snapshot:.init(data:latest,downloadedAt:Date()),isContinuous:isMultipart)
            }
        } catch let failure { error = failure }
        lock.unlock()
        if let output { continuation.yield(output) }
        if let error { finish(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish((error as? URLError)?.code == .timedOut ? CCTVError.timedOut:error); return }
        lock.lock()
        let stopped = completed, validPNG = isPNG && png.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])
        let bytes = validPNG ? png:nil, received = receivedFrame
        lock.unlock()
        guard !stopped else { return }
        if let bytes { continuation.yield(.init(snapshot:.init(data:bytes,downloadedAt:Date()),isContinuous:false)) }
        finish(validPNG || received ? nil:CCTVError.unavailable)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? CCTVService.publicURL(url.absoluteString)) != nil else {
            completionHandler(nil); finish(CCTVError.invalidURL); return
        }
        completionHandler(request)
    }
}
