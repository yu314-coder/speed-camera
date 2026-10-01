import Foundation
import SQLite3

enum TrafficStoreError: LocalizedError {
    case missingDatabase, sqlite(String)
    var errorDescription: String? {
        switch self {
        case .missingDatabase: return "The bundled Taiwan database is missing. Rebuild the project with its Resources folder."
        case .sqlite(let message): return "Traffic database: \(message)"
        }
    }
}

actor TrafficStore {
    private var database: OpaquePointer?
    private var roadCache = BoundedCache<String,[RoadSegment]>(capacity:6,costLimit:2_000_000)
    private var geometryCache = BoundedCache<String,RoadPath>(capacity:192,costLimit:2_000_000)
    private var statements: [String:(handle:OpaquePointer,used:UInt64)] = [:]
    private var statementClock: UInt64 = 0
    private let jsonDecoder = JSONDecoder()
    private let hasStreamColumn: Bool
    private let hasSpeedReferences: Bool
    private static let compassHeadings: [String:Double] = ["N":0,"NE":45,"E":90,"SE":135,"S":180,"SW":225,"W":270,"NW":315]
    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open snapshot"
            sqlite3_close(handle); throw TrafficStoreError.sqlite(message)
        }
        do {
            try Self.validate(handle)
        } catch { sqlite3_close(handle); throw error }
        sqlite3_busy_timeout(handle,200)
        sqlite3_exec(handle,"PRAGMA cache_size=-1024; PRAGMA mmap_size=0",nil,nil,nil)
        hasStreamColumn = Self.hasCCTVStreams(in:handle)
        var referenceProbe: OpaquePointer?
        hasSpeedReferences = sqlite3_prepare_v2(handle,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='speed_limit_references'",-1,&referenceProbe,nil) == SQLITE_OK
            && sqlite3_step(referenceProbe) == SQLITE_ROW
        sqlite3_finalize(referenceProbe)
        database = handle
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement.handle) }
        sqlite3_close(database)
    }
    static func hasCCTVStreams(in handle: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        return sqlite3_prepare_v2(handle,"SELECT 1 FROM pragma_table_info('camera_points') WHERE name='cctv_stream_endpoint' LIMIT 1",-1,&statement,nil) == SQLITE_OK
            && sqlite3_step(statement) == SQLITE_ROW
    }
    private static func validate(_ handle: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle,"PRAGMA user_version",-1,&statement,nil) == SQLITE_OK else {
            throw TrafficStoreError.sqlite("Snapshot is unreadable or corrupt. Please reinstall a verified build.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement,0) == 1 else {
            throw TrafficStoreError.sqlite("Unsupported snapshot version. Please update the app.")
        }
        // Prepare the required columns before publishing a ready store; no full-table scan at launch.
        for sql in ["SELECT id,lat,lon,bearings_json,location_confidence,is_alert_enabled FROM camera_points LIMIT 0",
                    "SELECT geometry_json,road_ref,direction,speed_limit_kph FROM road_segments LIMIT 0",
                    "SELECT geometry_json,length_m,is_alert_enabled FROM section_zones LIMIT 0",
                    "SELECT key,value FROM build_metadata LIMIT 0",
                    "SELECT dataset_id,url,status FROM source_manifest LIMIT 0",
                    "SELECT min_lon,max_lon,min_lat,max_lat FROM camera_rtree LIMIT 0",
                    "SELECT min_lon,max_lon,min_lat,max_lat FROM road_rtree LIMIT 0",
                    "SELECT min_lon,max_lon,min_lat,max_lat FROM section_rtree LIMIT 0"] {
            var probe: OpaquePointer?
            let status = sqlite3_prepare_v2(handle,sql,-1,&probe,nil)
            sqlite3_finalize(probe)
            guard status == SQLITE_OK else { throw TrafficStoreError.sqlite("Snapshot schema is incomplete. Please reinstall a verified build.") }
        }
    }
    static func bundledURL() throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "tw_traffic", withExtension: "db") else { throw TrafficStoreError.missingDatabase }
        return url
    }
    func enforcementCameras() throws -> [CameraPoint] {
        try cameraRows(from:"FROM camera_points c WHERE c.camera_category!='cctv' ORDER BY c.id",values:[])
    }
    func roadReferences() throws -> Set<String> {
        var refs = Set<String>()
        try query("SELECT DISTINCT road_ref FROM road_segments WHERE road_ref!=''") { refs.insert(text($0,0)) }
        return refs
    }
    func speedReferences() throws -> [SpeedLimitReference] {
        guard hasSpeedReferences else { return [] }
        var result: [SpeedLimitReference] = []
        try query("""
        SELECT id,road_name,road_ref,segment_description,speed_limit_text,speed_limit_kph,conditions,
               source_dataset_id,source_authority,source_updated_at,source_url,fetched_at_utc,publication_status
        FROM speed_limit_references ORDER BY source_dataset_id,road_name,segment_description LIMIT 2000
        """) { s in
            result.append(.init(id:text(s,0),roadName:text(s,1),roadRef:text(s,2),segment:text(s,3),limitText:text(s,4),
                numericLimit:optionalInt(s,5),conditions:text(s,6),sourceID:text(s,7),authority:text(s,8),sourceUpdated:text(s,9),
                sourceURL:text(s,10),checkedAt:text(s,11),publicationStatus:text(s,12)))
        }
        return result
    }
    func cameraSourceCounts() throws -> [String:Int] {
        var counts: [String:Int] = [:]
        try query("SELECT source_dataset_id,COUNT(*) FROM camera_points GROUP BY source_dataset_id") {
            counts[text($0,0)] = Int(sqlite3_column_int($0,1))
        }
        return counts
    }
    private func query(_ sql: String, values: [Double] = [], row: (OpaquePointer) throws -> Void) throws {
        try Task.checkCancellation()
        let budget = QueryBudget()
        sqlite3_progress_handler(database,1000,{ pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<QueryBudget>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ProcessInfo.processInfo.systemUptime > budget.expires ? 1 : 0
        },Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(database,0,nil,nil); withExtendedLifetime(budget) {} }
        statementClock &+= 1
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached.handle }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                sqlite3_finalize(prepared)
                throw TrafficStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            statement = prepared
            if statements.count >= 32, let oldest = statements.min(by:{ $0.value.used < $1.value.used })?.key,
               let evicted = statements.removeValue(forKey:oldest) { sqlite3_finalize(evicted.handle) }
        }
        statements[sql] = (statement,statementClock)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_double(statement, Int32(index+1), value) }
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw TrafficStoreError.sqlite(String(cString: sqlite3_errmsg(database))) }
            try row(statement)
        }
    }
    private func text(_ s: OpaquePointer, _ index: Int32) -> String {
        guard sqlite3_column_bytes(s,index) <= 256_000 else { return "" }
        return sqlite3_column_text(s, index).map { String(cString: $0) } ?? ""
    }
    private func optionalInt(_ s: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(s, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, index))
    }
    private func path(_ statement: OpaquePointer, column: Int32, key: String) -> RoadPath {
        if let cached = geometryCache.value(for:key) { return cached }
        let count = Int(sqlite3_column_bytes(statement,column))
        guard count > 0, count <= 256_000, let bytes = sqlite3_column_text(statement,column),
              let pairs = try? jsonDecoder.decode([[Double]].self, from: Data(bytes:bytes,count:count)),
              pairs.count >= 2, pairs.count <= 8192, pairs.allSatisfy({ $0.count == 2 }) else { return RoadPath([]) }
        let path = RoadPath(pairs.map { Coordinate($0[1],$0[0]) })
        if path.coordinates.count >= 2 { geometryCache.insert(path,for:key,cost:path.estimatedByteCount+key.utf8.count) }
        return path
    }
    func releaseMemory() {
        roadCache.removeAll(); geometryCache.removeAll()
        for statement in statements.values { sqlite3_finalize(statement.handle) }
        statements.removeAll(keepingCapacity:false)
        sqlite3_db_release_memory(database)
    }
    struct CacheUsage: Sendable {
        let roadBytes: Int
        let geometryBytes: Int
        let statements: Int
    }
    func cacheUsage() -> CacheUsage {
        .init(roadBytes:roadCache.totalCost,geometryBytes:geometryCache.totalCost,statements:statements.count)
    }
    private func bindings(_ b: MapBounds) -> [Double] { [b.west, b.east, b.south, b.north] }

    func cameras(in bounds: MapBounds, categories: Set<CameraCategory>, limit: Int = 800) throws -> [CameraPoint] {
        guard bounds.valid, !categories.isEmpty else { return [] }
        let filter = categories.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
        return try cameraRows(from:"""
        FROM camera_rtree r JOIN camera_points c ON c.rowid=r.rowid
        WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=?
        AND c.camera_category IN (\(filter)) ORDER BY c.is_alert_enabled DESC,c.id LIMIT \(max(1,min(1200,limit)))
        """, values:bindings(bounds))
    }

    func mapCameras(in bounds: MapBounds, categories: Set<CameraCategory>, showLimited: Bool, limit: Int = 600) throws -> [CameraPoint] {
        guard bounds.valid, !categories.isEmpty else { return [] }
        let budget = max(200,min(600,limit))
        let confidenceFilter = showLimited ? "" : "AND (c.location_confidence='A' OR c.camera_category='cctv')"
        var result: [CameraPoint] = []
        // Section exits are not alert triggers, but must still be visible alongside their entries.
        if categories.contains(.sectionSpeed) {
            result = try cameraRows(from:"""
            FROM camera_rtree r JOIN camera_points c ON c.rowid=r.rowid
            WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=?
            AND c.camera_category='section_speed' \(confidenceFilter) ORDER BY c.id LIMIT 200
            """,values:bindings(bounds))
        }
        let other = CameraCategory.allCases.filter { categories.contains($0) && $0 != .sectionSpeed }
        let weights = other.map { $0 == .speed || $0 == .cctv ? 3 : 1 }
        let totalWeight = max(1,weights.reduce(0,+)), remaining = budget-result.count
        for (index,category) in other.enumerated() {
            let quota = max(1,remaining * weights[index] / totalWeight)
            // Pick the first point in each spatial cell before the second, not one crowded road first.
            result += try cameraRows(from:"""
            FROM (
                SELECT camera_rowid FROM (
                    SELECT c.rowid AS camera_rowid,c.id AS camera_id,ROW_NUMBER() OVER (
                        PARTITION BY CAST((c.lat-?)/MAX(?,0.000001)*8 AS INTEGER),
                                     CAST((c.lon-?)/MAX(?,0.000001)*12 AS INTEGER) ORDER BY c.id
                    ) AS map_rank
                    FROM camera_rtree r JOIN camera_points c ON c.rowid=r.rowid
                    WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=?
                    AND c.camera_category='\(category.rawValue)' \(confidenceFilter)
                ) ranked ORDER BY map_rank,camera_id LIMIT \(quota)
            ) chosen JOIN camera_points c ON c.rowid=chosen.camera_rowid
            """,values:[bounds.south,bounds.north-bounds.south,bounds.west,bounds.east-bounds.west]+bindings(bounds))
        }
        return result.sorted { $0.id < $1.id }
    }

    private func cameraRows(from clause: String, values: [Double]) throws -> [CameraPoint] {
        var result: [CameraPoint] = []
        try query("""
        SELECT c.id,c.lat,c.lon,c.camera_category,c.enforcement_type,c.road_name,c.road_ref,c.direction,
        c.speed_limit_kph,c.source_dataset_id,c.source_authority,c.source_updated_at,c.location_confidence,
        c.is_alert_enabled,c.road_level_hint,c.bearings_json,c.quality_note,c.section_id,c.cctv_endpoint,
        \(hasStreamColumn ? "c.cctv_stream_endpoint":"NULL")
        \(clause)
        """,values:values) { s in
            guard let category = CameraCategory(rawValue: text(s,3)) else { return }
            let coordinate = Coordinate(sqlite3_column_double(s,1),sqlite3_column_double(s,2))
            guard coordinate.valid else { return }
            let section = text(s,17), cctv = text(s,18), stream = text(s,19)
            result.append(.init(id: text(s,0), coordinate: coordinate,
                category: category, enforcementType: text(s,4), roadName: text(s,5), roadRef: text(s,6), direction: text(s,7),
                speedLimit: optionalInt(s,8),sourceID: text(s,9), sourceAuthority: text(s,10), sourceUpdated: text(s,11),
                confidence: text(s,12),isAlertEnabled: sqlite3_column_int(s,13) != 0,roadLevel: text(s,14),
                bearings: ((try? jsonDecoder.decode([Double].self,from: Data(text(s,15).utf8))) ?? []).filter { $0.isFinite && $0 >= 0 && $0 < 360 }, qualityNote: text(s,16),
                sectionID: section.isEmpty ? nil : section,cctvURL: cctv.isEmpty ? nil : cctv,
                cctvStreamURL:stream.isEmpty ? nil:stream))
        }
        return result
    }

    func roads(near coordinate: Coordinate) throws -> [RoadSegment] {
        try Task.checkCancellation()
        guard coordinate.valid else { return [] }
        let key = "\(Int(floor(coordinate.latitude * 50))):\(Int(floor(coordinate.longitude * 50)))"
        if let cached = roadCache.value(for:key) { return cached }
        var result: [RoadSegment] = []
        let bounds = MapBounds(center: coordinate,radius: 5000)
        try query("""
        SELECT s.id,s.road_name,s.road_ref,s.direction,s.speed_limit_kph,s.geometry_json,s.road_level_hint,s.source_dataset_id
        FROM road_rtree r JOIN road_segments s ON s.rowid=r.rowid
        WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=? LIMIT 700
        """,values: bindings(bounds)) { s in
            var geometry = path(s,column:5,key:"road:"+text(s,0))
            guard geometry.coordinates.count >= 2 else { return }
            if let direction = Self.compassHeadings[text(s,3)], let first = geometry.coordinates.first, let last = geometry.coordinates.last,
               Geo.angle(Geo.bearing(first,last), direction) > 90 { geometry = RoadPath(geometry.coordinates.reversed()) }
            result.append(.init(id: text(s,0),name: text(s,1),ref: text(s,2),direction: text(s,3),speedLimit: optionalInt(s,4),
                path: geometry,level: text(s,6),elevation: nil,sourceID: text(s,7)))
        }
        let cost = result.reduce(MemoryLayout<RoadSegment>.stride*result.count) { total, road in
            total+road.path.estimatedByteCount+road.id.utf8.count+road.name.utf8.count+road.ref.utf8.count
                + road.direction.utf8.count+road.level.utf8.count+road.sourceID.utf8.count
        }
        roadCache.insert(result,for:key,cost:cost)
        return result
    }

    func sections(in bounds: MapBounds, showLimited: Bool = true) throws -> [SectionZone] {
        guard bounds.valid else { return [] }
        var result: [SectionZone] = []
        try query("""
        SELECT s.id,s.road_name,s.road_ref,s.speed_limit_kph,s.geometry_json,s.length_m,s.is_alert_enabled,s.location_confidence
        FROM section_rtree r JOIN section_zones s ON s.rowid=r.rowid
        WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=?
        \(showLimited ? "" : "AND s.location_confidence='A'") ORDER BY s.id LIMIT 200
        """,values: bindings(bounds)) { s in
            let geometry = path(s,column:4,key:"section:"+text(s,0)), length = sqlite3_column_double(s,5)
            guard geometry.coordinates.count >= 2, length.isFinite, length > 0 else { return }
            result.append(.init(id: text(s,0),name: text(s,1),ref: text(s,2),speedLimit: optionalInt(s,3),path: geometry,
                length:length,isAlertEnabled: sqlite3_column_int(s,6) != 0,confidence: text(s,7)))
        }
        return result
    }

    func summary() throws -> DatasetSummary {
        var summary = DatasetSummary()
        try query("SELECT value FROM build_metadata WHERE key='built_at'") { summary.builtAt = text($0,0) }
        try query("SELECT value FROM build_metadata WHERE key='government_refreshed_at'") { summary.governmentUpdatedAt = text($0,0) }
        try query("SELECT camera_category,COUNT(*) FROM camera_points GROUP BY camera_category") { s in
            let count = Int(sqlite3_column_int(s,1))
            if text(s,0) == "cctv" { summary.cctv += count } else { summary.cameras += count }
        }
        try query("SELECT COUNT(*) FROM section_zones") { summary.sections = Int(sqlite3_column_int($0,0)) }
        try query("SELECT SUM(location_confidence='A'),SUM(location_confidence!='A') FROM section_zones") {
            summary.verifiedSections = Int(sqlite3_column_int($0,0)); summary.estimatedSections = Int(sqlite3_column_int($0,1))
        }
        try query("SELECT COUNT(*) FROM camera_points WHERE camera_category='section_speed' AND section_id IS NULL") {
            summary.unresolvedSectionEndpoints = Int(sqlite3_column_int($0,0))
        }
        try query("SELECT COUNT(*) FROM road_segments") { summary.roads = Int(sqlite3_column_int($0,0)) }
        try query("SELECT COUNT(*) FROM road_segments WHERE speed_limit_kph IS NOT NULL") { summary.speedRoads = Int(sqlite3_column_int($0,0)) }
        if hasSpeedReferences {
            try query("SELECT COUNT(*) FROM speed_limit_references") { summary.speedReferences = Int(sqlite3_column_int($0,0)) }
            try query("SELECT value FROM build_metadata WHERE key='speed_references_checked_at'") { summary.speedReferencesCheckedAt = text($0,0) }
        }
        try query("SELECT dataset_id,dataset_name,metadata_updated_at,status,record_count,url FROM source_manifest ORDER BY dataset_id") { s in
            summary.sources.append(.init(id:text(s,0),name:text(s,1),updated:text(s,2),status:text(s,3),count:Int(sqlite3_column_int(s,4)),url:text(s,5)))
        }
        return summary
    }
}

private final class QueryBudget {
    let expires = ProcessInfo.processInfo.systemUptime + 1
}
