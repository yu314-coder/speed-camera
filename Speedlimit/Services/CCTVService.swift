import Foundation

enum CCTVError: LocalizedError {
    case wait, unavailable, invalidURL, imageTooLarge, timedOut, http(Int), unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .wait: return "Please wait 60 seconds between requests to this public camera."
        case .unavailable: return "The public camera did not return a complete image. Its feed may be offline."
        case .invalidURL: return "No secure public image endpoint is available for this camera."
        case .imageTooLarge: return "The public image exceeds the safe download or image-size limit."
        case .timedOut: return "The public camera timed out. Map camera locations remain available offline."
        case .http(let code): return "The public camera server returned HTTP \(code). Its feed may be temporarily unavailable."
        case .unsupportedFormat: return "This public endpoint returned a webpage or unsupported image format, not a camera image."
        }
    }
}

struct CameraSnapshot: Sendable { let data: Data; let downloadedAt: Date }

actor CCTVService {
    static let shared = CCTVService()
    private var cache = BoundedCache<String,CameraSnapshot>(capacity:3,costLimit:4_000_000)
    private var attempts = BoundedCache<String,Date>(capacity:256)
    private var generation = 0
    private let configuration: URLSessionConfiguration?
    private let timeout: TimeInterval
    private var activeLive: CCTVLiveFeed?
    init(configuration: URLSessionConfiguration? = nil, timeout: TimeInterval = 20) {
        self.configuration = configuration; self.timeout = max(0.01,min(20,timeout))
    }
    func releaseMemory() { generation &+= 1; cache.removeAll(); activeLive?.cancel(); activeLive = nil }
    func cachedByteCount() -> Int { cache.totalCost }
    nonisolated static func publicURL(_ string: String) throws -> URL {
        guard var components = URLComponents(string:string), components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw CCTVError.invalidURL }
        // Thirty published southern-freeway URLs misspell this parameter; retain the published camera ID.
        if host == "cctvs.freeway.gov.tw", components.path == "/live-view/mjpg/video.cgi",
           var items = components.queryItems, !items.contains(where:{ $0.name == "camera" }),
           let index = items.firstIndex(where:{ $0.name == "cacame" && Int($0.value ?? "") != nil }) {
            items[index].name = "camera"; components.queryItems = items
        }
        guard let url = components.url else { throw CCTVError.invalidURL }
        return url
    }
    func nextRequestDate(urlString: String) -> Date? {
        guard let url = try? Self.publicURL(urlString) else { return nil }
        return attempts.value(for:url.absoluteString)?.addingTimeInterval(60)
    }
    func live(urlString: String, snapshotURLString: String? = nil) throws -> CCTVLiveFeed {
        try Task.checkCancellation()
        let url = try Self.publicURL(urlString), now = Date(), keys = requestKeys(url,related:snapshotURLString)
        for key in keys {
            if let attempt = attempts.value(for:key), now.timeIntervalSince(attempt) < 60 { throw CCTVError.wait }
        }
        for key in keys { attempts.insert(now,for:key) }
        activeLive?.cancel()
        let config = configuration?.copy() as? URLSessionConfiguration ?? .ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 3_600
        config.urlCache = nil
        let feed = CCTVLiveFeed(url:url,configuration:config,timeout:timeout)
        activeLive = feed
        return feed
    }
    private func requestKeys(_ url: URL, related: String?) -> Set<String> {
        var keys: Set<String> = [url.absoluteString]
        if let related, let alternate = try? Self.publicURL(related) { keys.insert(alternate.absoluteString) }
        return keys
    }
    func snapshot(urlString: String, streamURLString: String? = nil) async throws -> CameraSnapshot {
        let now = Date()
        try Task.checkCancellation()
        let url = try Self.publicURL(urlString), key = url.absoluteString, keys = requestKeys(url,related:streamURLString)
        if let cached = cache.value(for:key), now.timeIntervalSince(cached.downloadedAt) < 60 { return cached }
        for key in keys {
            if let attempt = attempts.value(for:key), now.timeIntervalSince(attempt) < 60 { throw CCTVError.wait }
        }
        for key in keys { attempts.insert(now,for:key) }
        let token = generation
        let config = configuration?.copy() as? URLSessionConfiguration ?? .ephemeral
        config.timeoutIntervalForRequest = min(15,timeout); config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        do {
            let snapshot = try await CCTVDownload(configuration:config,timeout:timeout).download(url)
            try Task.checkCancellation()
            if generation == token { cache.insert(snapshot,for:key,cost:snapshot.data.count) }
            return snapshot
        } catch {
            if Task.isCancelled {
                // A published snapshot/video pair shares its cooldown, even after dismissal.
                if streamURLString == nil, attempts.value(for:key) == now { attempts.removeValue(for:key) }
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut { throw CCTVError.timedOut }
            throw error
        }
    }
}

// URLSession delivers chunks on a serial worker queue, not one asynchronous operation per byte.
private final class CCTVDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CameraSnapshot,Error>?
    private var result: Result<CameraSnapshot,Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var parser = JPEGFrameParser()
    private var png = Data()
    private var isPNG = false
    init(configuration: URLSessionConfiguration, timeout: TimeInterval) {
        self.configuration = configuration; self.timeout = timeout
    }
    func download(_ url: URL) async throws -> CameraSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in start(url,continuation:continuation) }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func start(_ url: URL, continuation: CheckedContinuation<CameraSnapshot,Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with:result); return }
        self.continuation = continuation
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        let session = URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
        self.session = session
        var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData)
        request.setValue("image/jpeg, image/png, multipart/x-mixed-replace, */*;q=0.5",forHTTPHeaderField:"Accept")
        let task = session.dataTask(with:request); self.task = task
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(CCTVError.timedOut)) }
        self.deadline = deadline
        lock.unlock()
        task.resume()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout,execute:deadline)
    }
    private func finish(_ result: Result<CameraSnapshot,Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, session = self.session, task = self.task, deadline = self.deadline
        self.continuation = nil; self.session = nil; self.task = nil; self.deadline = nil
        lock.unlock()
        deadline?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with:result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.url?.scheme == "https" else { completionHandler(.cancel); finish(.failure(CCTVError.invalidURL)); return }
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(CCTVError.unavailable)); return }
        guard (200..<300).contains(http.statusCode) else { completionHandler(.cancel); finish(.failure(CCTVError.http(http.statusCode))); return }
        guard response.expectedContentLength <= JPEGFrameParser.maximumBytes else {
            completionHandler(.cancel); finish(.failure(CCTVError.imageTooLarge)); return
        }
        let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
        guard ["image/jpeg","image/jpg","image/png","multipart/x-mixed-replace","application/octet-stream"].contains(mime) else {
            completionHandler(.cancel); finish(.failure(CCTVError.unsupportedFormat)); return
        }
        isPNG = mime == "image/png"
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            if isPNG {
                guard png.count+data.count <= JPEGFrameParser.maximumBytes else { throw CCTVError.imageTooLarge }
                png.append(data)
            } else if let frame = try parser.append(data) {
                finish(.success(.init(data:frame,downloadedAt:Date())))
            }
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if isPNG, png.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) {
            finish(.success(.init(data:png,downloadedAt:Date())))
        } else { finish(.failure(CCTVError.unavailable)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); finish(.failure(CCTVError.invalidURL)); return }
        completionHandler(request)
    }
}
