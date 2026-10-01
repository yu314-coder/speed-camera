import Foundation

enum Geo {
    private static func nameCache() -> NSCache<NSString,NSString> {
        let cache = NSCache<NSString,NSString>(); cache.countLimit = 512; cache.totalCostLimit = 64 * 1024
        return cache
    }
    private static let streetCache = nameCache()
    private static let streetNameCache = nameCache()
    private static let roadRefCache = nameCache()
    private static let roadPatterns = ["國道\\s*([0-9一二三四五六七八九十]+)(甲|乙)?", "台\\s*([0-9]+)(甲|乙|丙|丁)?"]
        .map { try? NSRegularExpression(pattern:$0) }
    private static let englishRoadPattern = try? NSRegularExpression(pattern:"(?:national\\s+(?:highway|freeway)|freeway|expressway|provincial\\s+highway)\\s*(?:no\\.?\\s*)?([0-9]+)")
    private static let districtPattern = try? NSRegularExpression(pattern:"^(?:[\\p{Han}]{2,3}(?:縣|市))?(?:[\\p{Han}]{1,4}(?:市|區|鄉|鎮))?")
    private static let streetPatterns = [
        try? NSRegularExpression(pattern:"[\\p{Han}]{2,10}?(?:大道|大橋|路|街|橋)"),
        try? NSRegularExpression(pattern:"(?:onto|on|towards?)\\s+([A-Za-z0-9 .'-]+?\\b(?:Rd|Road|St|Street|Ave|Avenue|Blvd|Boulevard|Bridge))\\b",options:.caseInsensitive),
        try? NSRegularExpression(pattern:"^[A-Za-z0-9 .'-]+?\\b(?:Rd|Road|St|Street|Ave|Avenue|Blvd|Boulevard|Bridge)\\b",options:.caseInsensitive)
    ]
    private static let englishShortNames = [("road","rd"),("street","st"),("boulevard","blvd"),("avenue","ave"),("north","n"),("south","s"),("east","e"),("west","w")]
        .map { (try? NSRegularExpression(pattern:"\\b"+$0.0+"\\b"),$0.1) }
    private static func cached(_ text: String, in cache: NSCache<NSString,NSString>, compute: () -> String) -> String {
        // Unusually long source text is parsed but never retained in these small caches.
        guard text.utf8.count <= 2048 else { return compute() }
        if let value = cache.object(forKey:text as NSString) { return value as String }
        let value = compute()
        cache.setObject(value as NSString,forKey:text as NSString,cost:text.utf8.count+value.utf8.count)
        return value
    }
    static func releaseCachedNames() {
        streetCache.removeAllObjects(); streetNameCache.removeAllObjects(); roadRefCache.removeAllObjects()
    }
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let scale = cos((a.latitude + b.latitude) * .pi / 360)
        return hypot((b.longitude - a.longitude) * 111_320 * scale, (b.latitude - a.latitude) * 111_320)
    }
    static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let angle = atan2((b.longitude - a.longitude) * cos(a.latitude * .pi / 180), b.latitude - a.latitude) * 180 / .pi
        return (angle + 360).truncatingRemainder(dividingBy: 360)
    }
    static func angle(_ a: Double, _ b: Double) -> Double {
        guard a.isFinite, b.isFinite else { return .infinity }
        let value = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(value, 360 - value)
    }
    static func roadRef(_ text: String) -> String {
        cached(text,in:roadRefCache) { parseRoadRef(text) }
    }
    private static func parseRoadRef(_ text: String) -> String {
        let input = text.replacingOccurrences(of: "臺", with: "台")
        for (index,pattern) in roadPatterns.enumerated() {
            guard let regex = pattern,
                  let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let numberRange = Range(match.range(at: 1), in: input) else { continue }
            var number = String(input[numberRange])
            number = ["一":"1", "二":"2", "三":"3", "四":"4", "五":"5", "六":"6", "七":"7", "八":"8", "九":"9", "十":"10"][number] ?? number
            let suffix = Range(match.range(at: 2), in: input).map { String(input[$0]) } ?? ""
            return (index == 0 ? "國道" : "台") + number + suffix
        }
        let english = input.lowercased()
        if let regex = englishRoadPattern,
           let match = regex.firstMatch(in:english,range:NSRange(english.startIndex...,in:english)),
           let range = Range(match.range(at:1),in:english), let whole = Range(match.range,in:english) {
            let ref = String(english[whole])
            return (ref.contains("expressway") || ref.contains("provincial") ? "台" : "國道") + english[range]
        }
        return ""
    }
    static func streetKey(_ text: String) -> String {
        cached(text,in:streetCache) { parseStreetKey(text) }
    }
    private static func parseStreetKey(_ text: String) -> String {
        let name = streetName(text)
        guard !name.isEmpty else { return "" }
        let suffixes = [("大道","blvd"),("大橋","bridge"),("路","rd"),("街","st"),("橋","bridge")]
        var root = name, suffix = "", direction = ""
        if let match = suffixes.first(where:{ root.hasSuffix($0.0) }) {
            root.removeLast(match.0.count); suffix = match.1
            if let last = root.last, let d = [Character("北"):"n",Character("東"):"e",Character("南"):"s",Character("西"):"w"][last] {
                root.removeLast(); direction = d
            }
            root = root.applyingTransform(.toLatin,reverse:false) ?? root
        } else {
            root = root.lowercased()
            for (regex,short) in englishShortNames {
                root = regex?.stringByReplacingMatches(in:root,range:NSRange(root.startIndex...,in:root),withTemplate:short) ?? root
            }
        }
        let key = (root+direction+suffix).folding(options:.diacriticInsensitive,locale:Locale(identifier:"en_US_POSIX"))
            .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return key
    }
    static func streetName(_ text: String) -> String {
        cached(text,in:streetNameCache) { parseStreetName(text) }
    }
    private static func parseStreetName(_ text: String) -> String {
        var input = text
        for action in ["向右轉", "向左轉", "繼續行駛", "繼續", "靠右", "靠左", "沿著", "沿", "轉入", "進入", "前往", "往"] {
            input = input.replacingOccurrences(of:action,with:" ")
        }
        input = input.trimmingCharacters(in:.whitespaces)
        input = districtPattern?.stringByReplacingMatches(in:input,range:NSRange(input.startIndex...,in:input),withTemplate:"") ?? input
        for (index,pattern) in streetPatterns.enumerated() {
            if let regex = pattern,
               let match = regex.firstMatch(in:input,range:NSRange(input.startIndex...,in:input)),
               let range = Range(index == 1 ? match.range(at:1):match.range,in:input) {
                return String(input[range]).trimmingCharacters(in:.whitespaces)
            }
        }
        return ""
    }
}

struct PathProjection: Sendable {
    let distance: Double
    let along: Double
    let bearing: Double
    let index: Int
    let coordinate: Coordinate
}

struct RoadPath: Sendable {
    let coordinates: [Coordinate]
    let cumulative: [Double]
    private struct Edge: Sendable {
        let latitudeDelta: Double
        let longitudeDelta: Double
        let length: Double
        let bearing: Double
    }
    private let edges: [Edge]
    private struct EdgeBounds: Sendable {
        let south: Double
        let north: Double
        let west: Double
        let east: Double
        func lowerDistance(to point: Coordinate, scale: Double) -> Double {
            let dx = max(0,max(west-point.longitude,point.longitude-east)) * scale
            let dy = max(0,max(south-point.latitude,point.latitude-north))
            return hypot(dx,dy) * 111_320
        }
    }
    private static let blockSize = 64
    private let edgeBounds: [EdgeBounds]
    var projectionIndexByteCount: Int { edgeBounds.count * MemoryLayout<EdgeBounds>.stride }
    var length: Double { cumulative.last ?? 0 }
    var estimatedByteCount: Int {
        coordinates.count * MemoryLayout<Coordinate>.stride + cumulative.count * MemoryLayout<Double>.stride
            + edges.count * MemoryLayout<Edge>.stride + projectionIndexByteCount
    }
    init(_ coordinates: [Coordinate]) {
        let coordinates = coordinates.allSatisfy(\.valid) ? coordinates : []
        self.coordinates = coordinates
        var lengths = [0.0]
        lengths.reserveCapacity(coordinates.count)
        var edges: [Edge] = []
        edges.reserveCapacity(max(0,coordinates.count-1))
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let length = Geo.distance(a,b)
            edges.append(.init(latitudeDelta:b.latitude-a.latitude,longitudeDelta:b.longitude-a.longitude,
                               length:length,bearing:Geo.bearing(a,b)))
            lengths.append((lengths.last ?? 0) + length)
        }
        cumulative = coordinates.isEmpty ? [] : lengths
        self.edges = edges
        var bounds: [EdgeBounds] = []
        if edges.count >= 256 {
            bounds.reserveCapacity((edges.count+Self.blockSize-1)/Self.blockSize)
            for start in stride(from:0,to:edges.count,by:Self.blockSize) {
                var south = coordinates[start].latitude, north = south
                var west = coordinates[start].longitude, east = west
                for point in coordinates[(start+1)...min(start+Self.blockSize,edges.count)] {
                    south = min(south,point.latitude); north = max(north,point.latitude)
                    west = min(west,point.longitude); east = max(east,point.longitude)
                }
                bounds.append(.init(south:south,north:north,west:west,east:east))
            }
        }
        edgeBounds = bounds
    }
    func project(_ p: Coordinate, nearAlong: Double? = nil, bearing: Double? = nil) -> PathProjection? {
        guard coordinates.count >= 2, p.valid, nearAlong?.isFinite != false, bearing?.isFinite != false else { return nil }
        var best: PathProjection?
        var bestScore = Double.infinity
        let scale = cos(p.latitude * .pi / 180)
        var start = 0, end = edges.count
        if let nearAlong {
            func lowerBound(_ value: Double) -> Int {
                var lo = 0, hi = cumulative.count
                while lo < hi { let mid = (lo+hi)/2; if cumulative[mid] < value { lo = mid+1 } else { hi = mid } }
                return lo
            }
            start = max(0,lowerBound(nearAlong-1800)-1)
            end = min(edges.count,lowerBound(nearAlong+1800)+1)
        }
        guard start < end else { return nil }
        func scan(_ lower: Int, _ upper: Int) {
            for i in lower..<upper {
                let edge = edges[i]
                let a = coordinates[i]
                let dx = edge.longitudeDelta * scale, dy = edge.latitudeDelta
                let wx = (p.longitude - a.longitude) * scale, wy = p.latitude - a.latitude
                let denominator = dx * dx + dy * dy
                guard denominator > 0 else { continue }
                let t = max(0, min(1, (dx * wx + dy * wy) / denominator))
                let q = Coordinate(a.latitude + t * edge.latitudeDelta, a.longitude + t * edge.longitudeDelta)
                let distance = hypot((p.longitude-q.longitude)*scale, p.latitude-q.latitude) * 111_320
                let heading = edge.bearing
                let score = distance + (bearing.map { Geo.angle($0, heading) * 0.25 } ?? 0)
                if score < bestScore || (score == bestScore && i < (best?.index ?? Int.max)) {
                    bestScore = score
                    best = .init(distance: distance, along: cumulative[i] + t * edge.length,
                                 bearing: heading, index: i, coordinate: q)
                }
            }
        }
        guard !edgeBounds.isEmpty, end-start > Self.blockSize*2 else { scan(start,end); return best }
        let first = start/Self.blockSize, last = (end-1)/Self.blockSize
        var nearest = first, nearestDistance = Double.infinity
        for block in first...last {
            let distance = edgeBounds[block].lowerDistance(to:p,scale:scale)
            if distance < nearestDistance { nearest = block; nearestDistance = distance }
        }
        scan(max(start,nearest*Self.blockSize),min(end,(nearest+1)*Self.blockSize))
        // Bounds prune only impossible winners; exact projection and earliest-edge ties remain unchanged.
        for block in first...last where block != nearest {
            if edgeBounds[block].lowerDistance(to:p,scale:scale) <= bestScore+0.0000001 {
                scan(max(start,block*Self.blockSize),min(end,(block+1)*Self.blockSize))
            }
        }
        return best
    }
}
