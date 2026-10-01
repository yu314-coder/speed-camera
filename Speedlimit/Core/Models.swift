import Foundation
import CoreLocation

struct Coordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    var cl: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var valid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
    init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    init(_ value: CLLocationCoordinate2D) { self.init(value.latitude, value.longitude) }
}

enum CameraCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case speed, redLight = "red_light", sectionSpeed = "section_speed"
    case multiViolation = "multi_violation", cctv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "Speed cameras"
        case .redLight: return "Red-light cameras"
        case .sectionSpeed: return "Section speed"
        case .multiViolation: return "Other enforcement"
        case .cctv: return "Traffic CCTV"
        }
    }
    var symbol: String {
        switch self {
        case .speed: return "camera.fill"
        case .redLight: return "light.beacon.max.fill"
        case .sectionSpeed: return "point.topleft.down.to.point.bottomright.curvepath"
        case .multiViolation: return "exclamationmark.shield.fill"
        case .cctv: return "video.fill"
        }
    }
}

struct CameraPoint: Identifiable, Sendable, Equatable {
    let id: String
    let coordinate: Coordinate
    let category: CameraCategory
    let enforcementType: String
    let roadName: String
    let roadRef: String
    let direction: String
    let speedLimit: Int?
    let sourceID: String
    let sourceAuthority: String
    let sourceUpdated: String
    let confidence: String
    let isAlertEnabled: Bool
    let roadLevel: String
    let bearings: [Double]
    let qualityNote: String
    let sectionID: String?
    let cctvURL: String?
    var cctvStreamURL: String? = nil
    var confidenceTitle: String {
        if category == .cctv { return "Official · traffic observation" }
        if category == .sectionSpeed, confidence == "A", !isAlertEnabled { return "Official · section endpoint" }
        return isAlertEnabled ? "Official · alert eligible" : "Limited · hidden from alerts"
    }
    var sectionCoverageTitle: String {
        guard sectionID != nil else { return "Endpoint only · full span unverified" }
        if confidence == "A" { return "Verified corridor · blue dashed line" }
        if qualityNote.contains("display") { return "Estimated span · pale blue dashes · no alerts" }
        return "Official endpoints · road path unavailable"
    }
}

struct RoadSegment: Identifiable, Sendable {
    let id: String
    let name: String
    let ref: String
    let direction: String
    let speedLimit: Int?
    let path: RoadPath
    let level: String
    let elevation: Double?
    let sourceID: String
}

struct SectionZone: Identifiable, Sendable {
    let id: String
    let name: String
    let ref: String
    let speedLimit: Int?
    let path: RoadPath
    let length: Double
    let isAlertEnabled: Bool
    let confidence: String
}

struct SourceInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let updated: String
    let status: String
    let count: Int
    let url: String
}

enum SpeedReferenceScope: String, CaseIterable, Identifiable {
    case all = "All", taipei = "Taipei", freeway = "Freeways", expressway = "Expressways"
    var id: String { rawValue }
    func includes(_ source: String) -> Bool {
        switch self {
        case .all: return true
        case .taipei: return source == "121671"
        case .freeway: return source == "40476"
        case .expressway: return source == "thb_expressway_limits"
        }
    }
}

struct SpeedLimitReference: Identifiable, Sendable, Hashable {
    let id: String
    let roadName: String
    let roadRef: String
    let segment: String
    let limitText: String
    let numericLimit: Int?
    let conditions: String
    let sourceID: String
    let authority: String
    let sourceUpdated: String
    let sourceURL: String
    let checkedAt: String
    let publicationStatus: String
    private let searchKey: String
    init(id: String, roadName: String, roadRef: String, segment: String, limitText: String,
         numericLimit: Int?, conditions: String, sourceID: String, authority: String,
         sourceUpdated: String, sourceURL: String, checkedAt: String, publicationStatus: String) {
        self.id = id; self.roadName = roadName; self.roadRef = roadRef; self.segment = segment
        self.limitText = limitText; self.numericLimit = numericLimit; self.conditions = conditions
        self.sourceID = sourceID; self.authority = authority; self.sourceUpdated = sourceUpdated
        self.sourceURL = sourceURL; self.checkedAt = checkedAt; self.publicationStatus = publicationStatus
        searchKey = Self.normalized([roadName,roadRef,segment,limitText,conditions].joined(separator:" "))
    }
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of:"臺",with:"台").folding(options:[.caseInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }
    static func tokens(_ query: String) -> [String] {
        normalized(query).split(whereSeparator:\.isWhitespace).map(String.init)
    }
    func matches(tokens: [String], scope: SpeedReferenceScope) -> Bool {
        scope.includes(sourceID) && tokens.allSatisfy { searchKey.contains($0) }
    }
}

struct MapLayerCounts {
    var cctv = 0
    var corridors = 0
    var endpoints = 0
    var hasOSMShapes = false
    init(cameras: [CameraPoint] = [], zones: [SectionZone] = []) {
        for camera in cameras {
            if camera.category == .cctv { cctv += 1 }
            if camera.category == .sectionSpeed && camera.sectionID == nil { endpoints += 1 }
        }
        corridors = zones.count; hasOSMShapes = zones.contains { $0.confidence == "B" }
    }
    var accessibilitySummary: String {
        "\(cctv) CCTV markers, \(corridors) section corridors loaded, \(endpoints) endpoints without a verified span"
    }
}

struct DatasetSummary: Sendable {
    var builtAt = "Unknown"
    var governmentUpdatedAt: String?
    var cameras = 0
    var cctv = 0
    var sections = 0
    var verifiedSections = 0
    var estimatedSections = 0
    var unresolvedSectionEndpoints = 0
    var roads = 0
    var speedRoads = 0
    var speedReferences = 0
    var speedReferencesCheckedAt: String?
    var sources: [SourceInfo] = []
}

struct LocationFix: Sendable {
    let coordinate: Coordinate
    let timestamp: Date
    let accuracy: Double
    let speed: Double
    let course: Double?
    let altitude: Double
    let verticalAccuracy: Double
    init(coordinate: Coordinate, timestamp: Date = Date(), accuracy: Double = 5,
         speed: Double = 10, course: Double? = 0, altitude: Double = 0, verticalAccuracy: Double = -1) {
        self.coordinate = coordinate; self.timestamp = timestamp; self.accuracy = accuracy
        self.speed = speed; self.course = course; self.altitude = altitude; self.verticalAccuracy = verticalAccuracy
    }
    var canMatch: Bool {
        coordinate.valid && accuracy.isFinite && accuracy >= 0 && accuracy <= 25 && speed.isFinite && speed >= 3 &&
        course.map { $0.isFinite && $0 >= 0 && $0 < 360 } == true
    }
    func usableForRouting(maxAge: TimeInterval = 20) -> Bool {
        coordinate.valid && accuracy.isFinite && accuracy >= 0 && accuracy <= 100 &&
        isFresh(maxAge:maxAge)
    }
    func isFresh(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -1 && age <= maxAge
    }
}

struct MatchedRoadContext: Sendable {
    let segment: RoadSegment
    let projection: PathProjection
    let routeLocked: Bool
    let confidence: String
}

struct NearbyAlert: Identifiable, Sendable {
    enum Severity: Int, Sendable { case warning, critical, inSection }
    let camera: CameraPoint
    let distance: Double
    let severity: Severity
    let inSection: Bool
    var id: String { camera.id + ":" + String(severity.rawValue) }
    var distanceMeters: Int? {
        guard distance.isFinite, distance >= 0, distance <= 1_000_000_000 else { return nil }
        return Int(distance.rounded())
    }
    var title: String {
        inSection ? "Section speed zone" : (severity == .critical ? "Camera ahead" : "Approaching camera")
    }
    var message: String {
        let limit = camera.speedLimit.map { " · \($0) km/h" } ?? " · obey posted limit"
        let meters = distanceMeters.map(String.init) ?? "Unknown"
        return "\(camera.category.title) · \(meters) m\n\(camera.roadName)\(limit)\n\(camera.direction.isEmpty ? "Direction not supplied" : camera.direction)"
    }
}

struct MapBounds: Equatable, Sendable {
    var south: Double; var north: Double; var west: Double; var east: Double
    init(center: Coordinate, radius: Double) {
        let latitudeDelta = radius / 111_320
        let longitudeDelta = latitudeDelta / max(0.2, cos(center.latitude * .pi / 180))
        south = center.latitude - latitudeDelta; north = center.latitude + latitudeDelta
        west = center.longitude - longitudeDelta; east = center.longitude + longitudeDelta
    }
    init(south: Double, north: Double, west: Double, east: Double) {
        self.south = south; self.north = north; self.west = west; self.east = east
    }
    var valid: Bool { south.isFinite && north.isFinite && east.isFinite && west.isFinite && south <= north && west <= east }
    func contains(_ other: MapBounds) -> Bool { south <= other.south && north >= other.north && west <= other.west && east >= other.east }
    func expanded() -> MapBounds {
        let lat = (north-south)*0.25, lon = (east-west)*0.25
        return .init(south:south-lat,north:north+lat,west:west-lon,east:east+lon)
    }
}
