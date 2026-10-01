import Foundation

struct SectionOverlayGroup {
    let zones: [SectionZone]
    var id: String { zones.map(\.id).sorted().joined(separator:"|") }
    var path: RoadPath { zones[0].path }
    var confidence: String { zones[0].confidence }
}

enum SectionOverlayPlan {
    static func groups(_ zones: [SectionZone]) -> [SectionOverlayGroup] {
        var groups: [[SectionZone]] = []
        for zone in zones.sorted(by:{ $0.id < $1.id }) {
            let index = groups.firstIndex { existing in
                let other = existing[0]
                guard other.name == zone.name, other.ref == zone.ref, other.confidence == zone.confidence,
                      abs(other.path.length-zone.path.length) < 120,
                      let a = other.path.coordinates.first, let b = other.path.coordinates.last,
                      let c = zone.path.coordinates.first, let d = zone.path.coordinates.last else { return false }
                // Opposite carriageways for the same full span share one visual stroke.
                // Independent alert paths/official coordinates remain unchanged.
                return Geo.distance(a,d) < 40 && Geo.distance(b,c) < 40
            }
            if let index { groups[index].append(zone) } else { groups.append([zone]) }
        }
        return groups.map { SectionOverlayGroup(zones:$0) }
    }
}
