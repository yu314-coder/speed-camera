import Foundation
import SQLite3
import CryptoKit
import Darwin

struct GovernmentSourceStatus: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var checkedAt: Date?
    var refreshedAt: Date?
    var records = 0
    var status = "Bundled snapshot"
    var error: String?
    var etag: String?
    var lastModified: String?
    var digest: String?
    var resourceURL: String?
    var parserVersion: Int?
}

struct GovernmentUpdateReport: Codable, Sendable {
    var sources: [GovernmentSourceStatus] = []
    var snapshotChanged = false
    var lastChecked: Date? { sources.compactMap(\.checkedAt).max() }
    var hasFailures: Bool { sources.contains { $0.error != nil } }
}

enum TrafficDatabaseFiles {
    static var directory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TrafficData",isDirectory:true)
    }
    static func activeURL(bundle: URL, directory: URL = directory) -> URL {
        let cached = directory.appendingPathComponent("current.db")
        guard FileManager.default.fileExists(atPath:cached.path),
              (try? TrafficStore(url:cached)) != nil,
              let built = metadata(bundle,key:"built_at"), metadata(cached,key:"base_snapshot_built_at") == built,
              let base = metadata(bundle,key:"snapshot_revision") ?? metadata(bundle,key:"built_at"),
              (metadata(cached,key:"base_snapshot_revision") ?? metadata(cached,key:"base_snapshot_built_at")) == base else { return bundle }
        return cached
    }
    static func metadata(_ url: URL, key: String) -> String? {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db,"SELECT value FROM build_metadata WHERE key=?",-1,&statement,nil) == SQLITE_OK else { return nil }
        bind(key,to:statement,at:1)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement,0) else { return nil }
        return String(cString:text)
    }
    static func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement,index); return }
        _ = value.withCString { sqlite3_bind_text(statement,index,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
    }
    static func publish(base: URL, bundle: URL, directory: URL, feeds: [(GovernmentFeedKind,ParsedGovernmentFeed)], now: Date) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at:directory,withIntermediateDirectories:true)
        let staged = directory.appendingPathComponent("staged-\(UUID().uuidString).db")
        defer { try? manager.removeItem(at:staged) }
        try manager.copyItem(at:base,to:staged)
        var db: OpaquePointer?
        guard sqlite3_open_v2(staged.path,&db,SQLITE_OPEN_READWRITE,nil) == SQLITE_OK else {
            sqlite3_close(db); throw GovernmentUpdateError.rejected("Cannot prepare a local data update.")
        }
        do {
            try execute(db,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; BEGIN IMMEDIATE")
            let hasStreams = TrafficStore.hasCCTVStreams(in:db)
            if !hasStreams { try execute(db,"ALTER TABLE camera_points ADD COLUMN cctv_stream_endpoint TEXT") }
            for (kind,feed) in feeds {
                try Task.checkCancellation()
                try replaceSource(db,kind:kind,feed:feed,now:now)
            }
            try setMetadata(db,key:"base_snapshot_built_at",value:metadata(bundle,key:"built_at") ?? "")
            try setMetadata(db,key:"base_snapshot_revision",value:metadata(bundle,key:"snapshot_revision") ?? metadata(bundle,key:"built_at") ?? "")
            try setMetadata(db,key:"government_refreshed_at",value:ISO8601DateFormatter().string(from:now))
            try execute(db,"COMMIT")
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(db,"PRAGMA quick_check",-1,&check,nil) == SQLITE_OK else {
                throw GovernmentUpdateError.rejected("Updated data failed its integrity check.")
            }
            let valid = sqlite3_step(check) == SQLITE_ROW && sqlite3_column_text(check,0).map { String(cString:$0) == "ok" } == true
            sqlite3_finalize(check)
            guard valid else { throw GovernmentUpdateError.rejected("Updated data failed its integrity check.") }
            sqlite3_close(db); db = nil
            _ = try TrafficStore(url:staged)
            try Task.checkCancellation()
            let current = directory.appendingPathComponent("current.db")
            // Same-directory rename is atomic; existing readers keep their old, complete snapshot.
            guard rename(staged.path,current.path) == 0 else { throw GovernmentUpdateError.rejected("Cannot activate the updated snapshot. Previous data retained.") }
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var saved = current; try? saved.setResourceValues(values)
        } catch { sqlite3_exec(db,"ROLLBACK",nil,nil,nil); sqlite3_close(db); throw error }
    }
    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else {
            throw GovernmentUpdateError.rejected("Local data update failed: \(String(cString:sqlite3_errmsg(db)))")
        }
    }
    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement); throw GovernmentUpdateError.rejected("Cannot prepare data update statements.")
        }
        return statement
    }
    private static func step(_ db: OpaquePointer?, _ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw GovernmentUpdateError.rejected("Local data update failed: \(String(cString:sqlite3_errmsg(db)))") }
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
    }
    private static func setMetadata(_ db: OpaquePointer?, key: String, value: String) throws {
        let statement = try prepare(db,"INSERT OR REPLACE INTO build_metadata(key,value) VALUES (?,?)")
        defer { sqlite3_finalize(statement) }
        bind(key,to:statement,at:1); bind(value,to:statement,at:2); try step(db,statement)
    }
    private static func replaceSource(_ db: OpaquePointer?, kind: GovernmentFeedKind, feed: ParsedGovernmentFeed, now: Date) throws {
        let deleteIndex = try prepare(db,"DELETE FROM camera_rtree WHERE rowid IN (SELECT rowid FROM camera_points WHERE source_dataset_id=?)")
        let deletePoints = try prepare(db,"DELETE FROM camera_points WHERE source_dataset_id=?")
        let insert = try prepare(db,"""
            INSERT INTO camera_points(id,lat,lon,camera_category,enforcement_type,road_name,road_ref,direction,speed_limit_kph,
                source_dataset_id,source_authority,source_updated_at,is_live_cctv,cctv_endpoint,position_source,
                location_confidence,is_alert_enabled,road_level_hint,bearings_json,quality_note,section_id,cctv_stream_endpoint)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        let index = try prepare(db,"INSERT INTO camera_rtree VALUES (?,?,?,?,?)")
        let manifest = try prepare(db,"INSERT OR REPLACE INTO source_manifest VALUES (?,?,?,?,?,?,?,?)")
        defer { for statement in [deleteIndex,deletePoints,insert,index,manifest] { sqlite3_finalize(statement) } }
        bind(kind.rawValue,to:deleteIndex,at:1); try step(db,deleteIndex)
        bind(kind.rawValue,to:deletePoints,at:1); try step(db,deletePoints)
        if !feed.conflictingCameraIDs.isEmpty {
            let conflict = try prepare(db,"UPDATE camera_points SET is_alert_enabled=0,location_confidence='B',speed_limit_kph=NULL,quality_note='Conflicting official speed limits during automatic refresh; alerts disabled' WHERE id=?")
            defer { sqlite3_finalize(conflict) }
            for id in feed.conflictingCameraIDs { bind(id,to:conflict,at:1); try step(db,conflict) }
        }
        let encoder = JSONEncoder()
        for camera in feed.cameras {
            try Task.checkCancellation()
            let strings: [(Int32,String?)] = [(1,camera.id),(4,camera.category.rawValue),(5,camera.enforcementType),(6,camera.roadName),
                (7,camera.roadRef),(8,camera.direction),(10,camera.sourceID),(11,camera.sourceAuthority),(12,camera.sourceUpdated),
                (14,camera.cctvURL),(15,"explicit_official_coordinate"),(16,camera.confidence),(18,camera.roadLevel),
                (19,String(data:try encoder.encode(camera.bearings),encoding:.utf8)),(20,camera.qualityNote),(21,camera.sectionID),(22,camera.cctvStreamURL)]
            for (column,value) in strings { bind(value,to:insert,at:column) }
            sqlite3_bind_double(insert,2,camera.coordinate.latitude); sqlite3_bind_double(insert,3,camera.coordinate.longitude)
            if let limit = camera.speedLimit { sqlite3_bind_int(insert,9,Int32(limit)) } else { sqlite3_bind_null(insert,9) }
            sqlite3_bind_int(insert,13,camera.category == .cctv ? 1:0); sqlite3_bind_int(insert,17,camera.isAlertEnabled ? 1:0)
            try step(db,insert)
            sqlite3_bind_int64(index,1,sqlite3_last_insert_rowid(db))
            for column: Int32 in [2,3] { sqlite3_bind_double(index,column,camera.coordinate.longitude) }
            for column: Int32 in [4,5] { sqlite3_bind_double(index,column,camera.coordinate.latitude) }
            try step(db,index)
        }
        let stamp = ISO8601DateFormatter().string(from:now)
        for (column,value) in [kind.rawValue,kind.title,kind.authority,feed.updated,stamp,String(feed.cameras.count),"auto_refreshed",kind == .police ? "https://data.gov.tw/dataset/7320":kind.url.absoluteString].enumerated() {
            bind(value,to:manifest,at:Int32(column+1))
        }
        try step(db,manifest)
    }
}

actor GovernmentDataUpdater {
    struct Response: Sendable { let data: Data; let etag: String?; let lastModified: String?; let notModified: Bool }
    typealias Downloader = @Sendable (URL,String?,String?) async throws -> Response
    static let shared = GovernmentDataUpdater()
    static let enabledKey = "government.autoUpdates.v1"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey:enabledKey) as? Bool ?? true }
    private let directory: URL
    private let bundle: URL?
    private let downloader: Downloader
    private let minimumRecords: Int
    private var busy = false
    init(directory: URL = TrafficDatabaseFiles.directory, bundle: URL? = nil, minimumRecords: Int = 100, downloader: Downloader? = nil) {
        self.directory = directory; self.bundle = bundle; self.minimumRecords = minimumRecords
        self.downloader = downloader ?? { url,etag,modified in
            try await GovernmentFeedDownload().download(url,etag:etag,modified:modified)
        }
    }
    func status() -> GovernmentUpdateReport {
        let url = directory.appendingPathComponent("refresh-status.json")
        guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size < 64_000,
              let data = try? Data(contentsOf:url), let report = try? JSONDecoder().decode(GovernmentUpdateReport.self,from:data) else {
            return .init(sources:GovernmentFeedKind.allCases.map { .init(id:$0.rawValue,title:$0.title) })
        }
        return report
    }
    func refresh(force: Bool = false, now: Date = Date()) async -> GovernmentUpdateReport {
        guard !busy else { return status() }
        busy = true; defer { busy = false }
        var report = status(); report.snapshotChanged = false
        guard let bundle = try? bundle ?? TrafficStore.bundledURL() else { return report }
        let base = TrafficDatabaseFiles.activeURL(bundle:bundle,directory:directory)
        let cached = base != bundle
        var feeds: [(GovernmentFeedKind,ParsedGovernmentFeed)] = []
        do {
            let store = try TrafficStore(url:base)
            let baselineCounts = try await store.cameraSourceCounts()
            for kind in GovernmentFeedKind.allCases {
                try Task.checkCancellation()
                let slot = report.sources.firstIndex { $0.id == kind.rawValue } ?? report.sources.count
                if slot == report.sources.count { report.sources.append(.init(id:kind.rawValue,title:kind.title)) }
                var state = report.sources[slot]
                // Older caches discarded VideoStreamURL; refetch once even when the XML hash is unchanged.
                let needsStreamUpgrade = kind != .police && state.parserVersion != 2
                let interval: TimeInterval = state.error == nil ? 86_400:21_600
                if !force, (!needsStreamUpgrade || state.error != nil), cached, let date = state.checkedAt, now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < interval { continue }
                state.checkedAt = now
                do {
                    var url = kind.url, updated = ""
                    if kind == .police {
                        let metadata = try await downloader(url,nil,nil)
                        (url,updated) = try GovernmentFeedParser.policeResource(metadata.data)
                    }
                    let sameURL = cached && !needsStreamUpgrade && state.resourceURL == url.absoluteString
                    let response = try await downloader(url,sameURL ? state.etag:nil,sameURL ? state.lastModified:nil)
                    if response.notModified {
                        guard sameURL, state.digest != nil else { throw GovernmentUpdateError.rejected("Unexpected empty update response.") }
                        state.status = "Up to date"; state.error = nil; report.sources[slot] = state; continue
                    }
                    let digest = SHA256.hash(data:response.data).map { String(format:"%02x",$0) }.joined()
                    if cached, !needsStreamUpgrade, state.digest == digest {
                        state.status = "Up to date"; state.error = nil; report.sources[slot] = state; continue
                    }
                    let parsed = try GovernmentFeedParser.parse(kind,data:response.data,updated:updated,minimumRecords:minimumRecords)
                    let expected = max(state.records,baselineCounts[kind.rawValue] ?? 0)
                    guard parsed.cameras.count >= Int(Double(expected)*0.8) else {
                        throw GovernmentUpdateError.rejected("Unexpected loss of over 20% of this feed. Previous data retained.")
                    }
                    let validated = try await validate(parsed,kind:kind,store:store)
                    guard validated.cameras.count >= max(1,Int(Double(expected)*0.8)) else {
                        throw GovernmentUpdateError.rejected("Too many locations failed validation. Previous data retained.")
                    }
                    feeds.append((kind,validated))
                    state.digest = digest; state.etag = response.etag; state.lastModified = response.lastModified; state.resourceURL = url.absoluteString
                    state.parserVersion = kind == .police ? 1:2
                    state.refreshedAt = now; state.records = validated.cameras.count; state.status = "Updated"; state.error = nil
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    state.status = "Previous data retained"; state.error = error.localizedDescription
                }
                report.sources[slot] = state
            }
            try Task.checkCancellation()
            if !feeds.isEmpty {
                try TrafficDatabaseFiles.publish(base:base,bundle:bundle,directory:directory,feeds:feeds,now:now)
                report.snapshotChanged = true
            }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(report).write(to:directory.appendingPathComponent("refresh-status.json"),options:.atomic)
        } catch {
            // Never persist validators for data that was cancelled or failed to commit.
            if !Task.isCancelled {
                var previous = status()
                for index in previous.sources.indices {
                    previous.sources[index].checkedAt = now; previous.sources[index].status = "Previous data retained"
                    previous.sources[index].error = error.localizedDescription
                }
                try? JSONEncoder().encode(previous).write(to:directory.appendingPathComponent("refresh-status.json"),options:.atomic)
                return previous
            }
            return status()
        }
        return report
    }
    private func validate(_ feed: ParsedGovernmentFeed, kind: GovernmentFeedKind, store: TrafficStore) async throws -> ParsedGovernmentFeed {
        let old = kind == .police ? try await store.enforcementCameras():[]
        let refs = kind == .police ? try await store.roadReferences():[]
        func key(_ camera: CameraPoint) -> String {
            [String(Int((camera.coordinate.latitude*10_000).rounded())),String(Int((camera.coordinate.longitude*10_000).rounded())),
             camera.category.rawValue,camera.direction,camera.roadRef].joined(separator:"|")
        }
        let existing = Dictionary(old.map { (key($0),$0) },uniquingKeysWith:{ first,_ in first })
        var points: [String:CameraPoint] = [:], conflicts = Set<String>(), crossSourceConflicts = Set<String>()
        for camera in feed.cameras {
            try Task.checkCancellation()
            let identity = key(camera)
            var point = camera
            if kind == .police {
                if let prior = existing[identity], prior.sourceID != kind.rawValue {
                    // Preserve separately audited county/section records rather than duplicate them.
                    if let limit = prior.speedLimit, let incoming = camera.speedLimit, limit != incoming { crossSourceConflicts.insert(prior.id) }
                    continue
                }
                if let prior = existing[identity], prior.coordinate == camera.coordinate, prior.roadName == camera.roadName,
                   prior.speedLimit == camera.speedLimit, prior.sourceID == kind.rawValue {
                    point = camera.validated(id:prior.id,confidence:prior.confidence,enabled:prior.isAlertEnabled,note:prior.qualityNote)
                } else {
                    if !camera.roadRef.isEmpty, refs.contains(camera.roadRef) {
                        let roads = try await store.roads(near:camera.coordinate).filter { $0.ref == camera.roadRef }
                        let distance = roads.compactMap { $0.path.project(camera.coordinate)?.distance }.min() ?? .infinity
                        guard distance <= 100 else { continue }
                        if camera.category != .sectionSpeed {
                            point = camera.validated(confidence:camera.bearings.isEmpty ? "B":"A",enabled:!camera.bearings.isEmpty,
                                note:"Official coordinate and direction; named-road validation within 100 m; elevation unknown")
                        }
                    } else if camera.category != .sectionSpeed, !camera.bearings.isEmpty, !Geo.streetName(camera.roadName).isEmpty {
                        point = camera.validated(confidence:"A",enabled:true,note:"Official coordinate and direction; city alerts require matching Apple route; elevation unknown")
                    }
                }
            }
            if let duplicate = points[identity] {
                if duplicate.speedLimit != point.speedLimit {
                    conflicts.insert(identity)
                } else if duplicate.isAlertEnabled { point = duplicate }
            }
            if conflicts.contains(identity) { point = point.validated(confidence:"B",enabled:false,note:"Conflicting official speed limits; alerts disabled",clearSpeedLimit:true) }
            points[identity] = point
        }
        return .init(cameras:points.values.sorted { $0.id < $1.id },updated:feed.updated,publishedCount:feed.publishedCount,conflictingCameraIDs:crossSourceConflicts.sorted())
    }
}

private final class GovernmentFeedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GovernmentDataUpdater.Response,Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var cancelled = false
    private var data = Data()
    private var response: HTTPURLResponse?
    func download(_ url: URL, etag: String?, modified: String?) async throws -> GovernmentDataUpdater.Response {
        try Task.checkCancellation()
        guard GovernmentFeedParser.secureGovernmentURL(url.absoluteString) != nil else { throw GovernmentUpdateError.rejected("Untrusted government feed URL.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing:CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20; config.urlCache = nil
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
                let session = URLSession(configuration:config,delegate:self,delegateQueue:queue); self.session = session
                var request = URLRequest(url:url)
                request.setValue(etag,forHTTPHeaderField:"If-None-Match"); request.setValue(modified,forHTTPHeaderField:"If-Modified-Since")
                let task = session.dataTask(with:request); self.task = task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<GovernmentDataUpdater.Response,Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation, session = session
        self.continuation = nil; self.session = nil; task = nil; data = Data()
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with:result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let permitted = request.url.flatMap { GovernmentFeedParser.secureGovernmentURL($0.absoluteString) } != nil
        completionHandler(permitted ? request:nil)
        if !permitted { finish(.failure(GovernmentUpdateError.rejected("The source redirected outside secure government hosts."))) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, [200,304].contains(http.statusCode), response.expectedContentLength <= 8_000_000 else {
            completionHandler(.cancel); finish(.failure(GovernmentUpdateError.rejected("Official feed is unavailable or oversized. Previous data retained."))); return
        }
        lock.lock(); self.response = http; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if data.count+chunk.count > 8_000_000 {
            lock.unlock(); finish(.failure(GovernmentUpdateError.rejected("Official feed exceeds 8 MB."))); return
        }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result = GovernmentDataUpdater.Response(data:data,etag:response?.value(forHTTPHeaderField:"ETag"),lastModified:response?.value(forHTTPHeaderField:"Last-Modified"),notModified:response?.statusCode == 304)
        lock.unlock(); finish(.success(result))
    }
}
