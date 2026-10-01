import Foundation
import CoreFoundation
import CryptoKit

enum GovernmentFeedKind: String, CaseIterable, Codable, Sendable {
    case police = "7320", freeway = "freeway_cctv", provincial = "thb_cctv"
    var title: String {
        switch self {
        case .police: return "National police cameras"
        case .freeway: return "Freeway CCTV"
        case .provincial: return "Provincial-road CCTV"
        }
    }
    var authority: String {
        switch self {
        case .police: return "內政部警政署"
        case .freeway: return "交通部高速公路局"
        case .provincial: return "交通部公路局"
        }
    }
    var url: URL {
        switch self {
        case .police: return URL(string:"https://data.gov.tw/api/v2/rest/dataset/7320")!
        case .freeway: return URL(string:"https://tisvcloud.freeway.gov.tw/history/motc20/CCTV.xml")!
        case .provincial: return URL(string:"https://cctv-maintain.thb.gov.tw/opendataCCTVs.xml")!
        }
    }
}

enum GovernmentUpdateError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self { case .rejected(let reason): return reason }
    }
}

struct ParsedGovernmentFeed: Sendable {
    let cameras: [CameraPoint]
    let updated: String
    let publishedCount: Int
    var conflictingCameraIDs: [String] = []
}

enum GovernmentFeedParser {
    static func secureGovernmentURL(_ value: String) -> URL? {
        guard let url = URL(string:value), url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".gov.tw"), url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func policeResource(_ data: Data) throws -> (url: URL, updated: String) {
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let result = object["result"] as? [String:Any],
              (result["datasetId"] as? NSNumber)?.intValue == 7320,
              let resources = result["distribution"] as? [[String:Any]],
              let url = resources.lazy.filter({ ($0["resourceFormat"] as? String)?.uppercased() == "CSV" })
                .compactMap({ secureGovernmentURL($0["resourceDownloadUrl"] as? String ?? "") }).first else {
            throw GovernmentUpdateError.rejected("The official catalog no longer lists a supported secure CSV. Previous data retained.")
        }
        return (url,result["modifiedDate"] as? String ?? "")
    }
    static func parse(_ kind: GovernmentFeedKind, data: Data, updated: String = "", minimumRecords: Int = 100) throws -> ParsedGovernmentFeed {
        guard data.count <= 8_000_000 else { throw GovernmentUpdateError.rejected("Official feed exceeds the safe download size.") }
        if kind != .police {
            guard data.range(of:Data("<!DOCTYPE".utf8)) == nil else { throw GovernmentUpdateError.rejected("CCTV XML entities are not supported.") }
            let delegate = CCTVInventoryParser(kind:kind)
            let parser = XMLParser(data:data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), !delegate.failed else { throw GovernmentUpdateError.rejected("Invalid official CCTV XML. Previous data retained.") }
            try validate(delegate.cameras.count,published:delegate.published,minimum:minimumRecords)
            return .init(cameras:delegate.cameras,updated:delegate.updated,publishedCount:delegate.published)
        }
        let big5 = String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        guard let text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:big5) else {
            throw GovernmentUpdateError.rejected("Unsupported official CSV text encoding.")
        }
        let table = try csv(text)
        guard let headers = table.first else { throw GovernmentUpdateError.rejected("Empty camera CSV.") }
        let names = headers.map { $0.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\u{FEFF}",with:"").lowercased() }
        let required = ["address","latitude","longitude","direct","limit"]
        guard required.allSatisfy(names.contains), Set(names).count == names.count else {
            throw GovernmentUpdateError.rejected("Camera columns changed. Previous data retained.")
        }
        let indices = Dictionary(uniqueKeysWithValues:names.enumerated().map { ($0.element,$0.offset) })
        var cameras: [CameraPoint] = [], published = 0
        for row in table.dropFirst() {
            try Task.checkCancellation()
            func value(_ name: String) -> String {
                guard let index = indices[name], row.indices.contains(index) else { return "" }
                return row[index].trimmingCharacters(in:.whitespacesAndNewlines)
            }
            if value("latitude") == "緯度" { continue }
            guard row.count == names.count else { throw GovernmentUpdateError.rejected("Truncated or malformed camera CSV.") }
            published += 1
            guard let coordinate = coordinate(lat:value("latitude"),lon:value("longitude")), !value("address").isEmpty else { continue }
            let road = value("address"), direction = value("direct")
            let section = road.contains("區間測速")
            let key = [road,String(coordinate.latitude),String(coordinate.longitude),direction].joined(separator:"\u{1F}")
            let id = "live:7320:"+SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
            let limit = Int(value("limit")).flatMap { (10...130).contains($0) ? $0:nil }
            cameras.append(.init(id:id,coordinate:coordinate,category:section ? .sectionSpeed:.speed,
                enforcementType:section ? "區間測速 · endpoint only":"測速",roadName:road,roadRef:Geo.roadRef(road),
                direction:direction,speedLimit:limit,sourceID:kind.rawValue,sourceAuthority:kind.authority,sourceUpdated:updated,
                confidence:"B",isAlertEnabled:false,roadLevel:"unknown",bearings:bearings(direction),
                qualityNote:"Official explicit coordinate; runtime validation pending",sectionID:nil,cctvURL:nil))
        }
        try validate(cameras.count,published:published,minimum:minimumRecords)
        return .init(cameras:cameras,updated:updated,publishedCount:published)
    }
    private static func validate(_ valid: Int, published: Int, minimum: Int) throws {
        guard valid >= max(1,minimum), published <= 30_000, Double(valid) >= Double(published)*0.9 else {
            throw GovernmentUpdateError.rejected("Official feed is empty, truncated, or has too many invalid coordinates. Previous data retained.")
        }
    }
    static func coordinate(lat: String, lon: String) -> Coordinate? {
        guard let latitude = Double(lat), let longitude = Double(lon),
              (21.8...26.5).contains(latitude), (118...122.5).contains(longitude) else { return nil }
        return .init(latitude,longitude)
    }
    private static let directionPattern = try? NSRegularExpression(pattern:"(?:向|往)(東北|東南|西北|西南|北|東|南|西)")
    static func bearings(_ direction: String) -> [Double] {
        let headings: [String:Double] = ["N":0,"NE":45,"E":90,"SE":135,"S":180,"SW":225,"W":270,"NW":315,
                                       "北":0,"東北":45,"東":90,"東南":135,"南":180,"西南":225,"西":270,"西北":315]
        if let value = headings[direction] { return [value] }
        if direction.contains("雙向") || direction.contains("双向") {
            if direction.contains("南北") || direction.contains("北南") { return [0,180] }
            if direction.contains("東西") || direction.contains("西東") { return [90,270] }
            return []
        }
        if let match = directionPattern?.firstMatch(in:direction,range:NSRange(direction.startIndex...,in:direction)),
           let range = Range(match.range(at:1),in:direction), let bearing = headings[String(direction[range])] { return [bearing] }
        if direction.contains("北上") { return [0] }
        if direction.contains("南下") { return [180] }
        return []
    }
    static func csv(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false
        var characters = text.makeIterator(), pending: Character?, index = 0
        func emitRow() throws {
            row.append(field); field = ""; closed = false
            if row.contains(where:{ !$0.isEmpty }) { rows.append(row) }
            row = []
            guard rows.count <= 30_002 else { throw GovernmentUpdateError.rejected("Too many camera records.") }
        }
        while let character = pending ?? characters.next() {
            pending = nil
            if index%4096 == 0 { try Task.checkCancellation() }
            if quoted {
                if character == "\"" {
                    let next = characters.next()
                    if next == "\"" { field.append("\"") }
                    else { quoted = false; closed = true; pending = next }
                } else { field.append(character) }
            } else if character == "\"", field.isEmpty, !closed { quoted = true }
            else if character == "," { row.append(field); field = ""; closed = false }
            else if character == "\n" || character == "\r" || character == "\r\n" {
                try emitRow()
            } else {
                guard !closed, character != "\"" else { throw GovernmentUpdateError.rejected("Malformed CSV quotation.") }
                field.append(character)
            }
            guard field.utf8.count <= 8192, row.count <= 64 else { throw GovernmentUpdateError.rejected("Oversized camera field.") }
            index += 1
        }
        guard !quoted else { throw GovernmentUpdateError.rejected("Unterminated CSV field.") }
        if !field.isEmpty || !row.isEmpty || closed { try emitRow() }
        return rows
    }
}

private final class CCTVInventoryParser: NSObject, XMLParserDelegate {
    let kind: GovernmentFeedKind
    var cameras: [CameraPoint] = []
    var updated = "", published = 0, failed = false
    private var row: [String:String]?
    private var text = ""
    private var ids = Set<String>()
    init(kind: GovernmentFeedKind) { self.kind = kind }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        text = ""
        if elementName == "CCTV" { row = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
        if text.utf8.count > 8192 { failed = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if elementName == "UpdateTime" { updated = value }
        guard var row else { return }
        if elementName != "CCTV" { row[elementName] = value; self.row = row; return }
        self.row = nil; published += 1
        guard published <= 30_000, !Task.isCancelled else { failed = true; parser.abortParsing(); return }
        let cameraID = row["CCTVID"] ?? ""
        let stream = GovernmentFeedParser.secureGovernmentURL(row["VideoStreamURL"] ?? "")
        guard !cameraID.isEmpty, ids.insert(cameraID).inserted,
              let coordinate = GovernmentFeedParser.coordinate(lat:row["PositionLat"] ?? "",lon:row["PositionLon"] ?? ""),
              let url = GovernmentFeedParser.secureGovernmentURL(row["VideoImageURL"] ?? "") ?? stream else { return }
        let name = row["SurveillanceDescription"].flatMap { $0.isEmpty ? nil:$0 } ?? row["RoadName"].flatMap { $0.isEmpty ? nil:$0 } ?? cameraID
        cameras.append(.init(id:(kind == .freeway ? "freeway:":"thb:")+cameraID,coordinate:coordinate,category:.cctv,
            enforcementType:"Traffic observation, not an enforcement camera",roadName:name,roadRef:Geo.roadRef(name),
            direction:row["RoadDirection"] ?? "",speedLimit:nil,sourceID:kind.rawValue,sourceAuthority:kind.authority,sourceUpdated:updated,
            confidence:"B",isAlertEnabled:false,roadLevel:"unknown",bearings:[],qualityNote:"Public official CCTV; video availability depends on the source. New connections and snapshots are limited to one per minute",sectionID:nil,cctvURL:url.absoluteString,cctvStreamURL:stream?.absoluteString))
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

extension CameraPoint {
    func validated(id: String? = nil, confidence: String, enabled: Bool, note: String, clearSpeedLimit: Bool = false) -> CameraPoint {
        .init(id:id ?? self.id,coordinate:coordinate,category:category,enforcementType:enforcementType,roadName:roadName,roadRef:roadRef,
            direction:direction,speedLimit:clearSpeedLimit ? nil:speedLimit,sourceID:sourceID,sourceAuthority:sourceAuthority,sourceUpdated:sourceUpdated,
            confidence:confidence,isAlertEnabled:enabled,roadLevel:roadLevel,bearings:bearings,qualityNote:note,sectionID:sectionID,cctvURL:cctvURL,cctvStreamURL:cctvStreamURL)
    }
}
