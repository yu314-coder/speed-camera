import Foundation

struct RoadMatcher: Sendable {
    private var previousRef = ""
    private var stableFixes = 0
    mutating func match(_ fix: LocationFix, roads: [RoadSegment], route: RoadPath? = nil,
                        routeRef: String = "", now: Date = Date()) -> MatchedRoadContext? {
        guard fix.canMatch, abs(now.timeIntervalSince(fix.timestamp)) <= 8, let course = fix.course else {
            stableFixes = 0; return nil
        }
        let routePosition = route?.project(fix.coordinate, bearing: course)
        let routeLocked = routePosition.map { $0.distance <= 25 && Geo.angle($0.bearing, course) < 40 } ?? false
        var candidates: [(RoadSegment, PathProjection, Double)] = []
        for road in roads {
            if routeLocked && !routeRef.isEmpty && road.ref != routeRef { continue }
            guard let p = road.path.project(fix.coordinate, bearing: course), p.distance <= 25,
                  Geo.angle(course, p.bearing) <= 35 else { continue }
            // GPS altitude cannot label a bridge/tunnel without surveyed road elevation.
            if let elevation = road.elevation, fix.verticalAccuracy >= 0, fix.verticalAccuracy < 8,
               abs(elevation - fix.altitude) > max(12, fix.verticalAccuracy * 2) { continue }
            candidates.append((road, p, p.distance + Geo.angle(course, p.bearing) * 0.3))
        }
        candidates.sort { $0.2 < $1.2 }
        guard let best = candidates.first else { previousRef = ""; stableFixes = 0; return nil }
        if let alternate = candidates.dropFirst().first(where: { $0.0.ref != best.0.ref }), alternate.2 - best.2 < 18 {
            stableFixes = 0; return nil
        }
        stableFixes = previousRef == best.0.ref ? stableFixes + 1 : 1
        previousRef = best.0.ref
        guard stableFixes >= 3, best.1.distance <= 15 else { return nil }
        return .init(segment: best.0, projection: best.1, routeLocked: routeLocked,
                     confidence: routeLocked && !routeRef.isEmpty ? "Route matched" : "GPS road match · elevation unknown")
    }
}

struct AlertEngine: Sendable {
    private var emitted: [String: (Date, NearbyAlert.Severity)] = [:]
    mutating func evaluate(fix: LocationFix, context: MatchedRoadContext?, cameras: [CameraPoint],
                           zones: [SectionZone], route: RoadPath?, now: Date = Date()) -> NearbyAlert? {
        guard fix.canMatch, abs(now.timeIntervalSince(fix.timestamp)) <= 8,
              let course = fix.course, let context else { return nil }
        let routePosition = route?.project(fix.coordinate, bearing: course)
        var eligible: [(CameraPoint, Double, Bool)] = []
        for camera in cameras where camera.isAlertEnabled && camera.category != .cctv {
            let sameRoad = !camera.roadRef.isEmpty ? camera.roadRef == context.segment.ref :
                (context.routeLocked && context.segment.sourceID == "apple_route" && !context.segment.ref.isEmpty &&
                 Geo.streetKey(camera.roadName) == context.segment.ref)
            guard sameRoad else { continue }
            if camera.roadLevel != "unknown", context.segment.level != "unknown", camera.roadLevel != context.segment.level { continue }
            if let section = camera.sectionID, let zone = zones.first(where: { $0.id == section && $0.isAlertEnabled }),
               let p = zone.path.project(fix.coordinate, bearing: course), p.distance <= 20,
               Geo.angle(p.bearing, course) <= 40, p.along > 15, p.along < zone.path.length - 15 {
                eligible.append((camera, zone.path.length - p.along, true)); continue
            }
            guard !camera.bearings.isEmpty, camera.bearings.contains(where: { Geo.angle($0, course) < 55 }) else { continue }
            var forward: Double
            if context.routeLocked, let route, let user = routePosition,
               let cameraProjection = route.project(camera.coordinate, nearAlong: user.along) {
                guard cameraProjection.distance <= 25, Geo.angle(cameraProjection.bearing, course) <= 55 else { continue }
                forward = cameraProjection.along - user.along
            } else {
                // Without a route, only the same connected local road geometry is eligible.
                guard let cameraProjection = context.segment.path.project(camera.coordinate), cameraProjection.distance <= 25,
                      Geo.angle(cameraProjection.bearing, course) <= 55 else { continue }
                forward = cameraProjection.along - context.projection.along
            }
            guard forward >= 0 && forward <= 600,
                  Geo.angle(Geo.bearing(fix.coordinate, camera.coordinate), course) < 70 else { continue }
            eligible.append((camera, forward, false))
        }
        eligible.sort { ($0.2 ? 0 : $0.1) < ($1.2 ? 0 : $1.1) }
        for (camera, distance, inSection) in eligible {
            let severity: NearbyAlert.Severity = inSection ? .inSection : distance <= 250 ? .critical : .warning
            if let old = emitted[camera.id], now.timeIntervalSince(old.0) < 120, severity.rawValue <= old.1.rawValue { continue }
            emitted[camera.id] = (now, severity)
            emitted = emitted.filter { now.timeIntervalSince($0.value.0) < 3600 }
            return NearbyAlert(camera: camera, distance: distance, severity: severity, inSection: inSection)
        }
        return nil
    }
}

struct NavigationProgress: Sendable {
    private(set) var along = 0.0
    private(set) var remaining = 0.0
    private(set) var offRouteFixes = 0
    private(set) var stepIndex = 0
    private var initialized = false
    mutating func update(fix: LocationFix, path: RoadPath, stepEnds: [Double]) -> PathProjection? {
        guard fix.accuracy >= 0, fix.accuracy <= 50, abs(Date().timeIntervalSince(fix.timestamp)) <= 10 else { return nil }
        var candidate = path.project(fix.coordinate, nearAlong: initialized ? along : nil, bearing: fix.course)
        if candidate == nil || (candidate?.distance ?? 0) > 100 { candidate = path.project(fix.coordinate,bearing:fix.course) }
        guard let p = candidate else { return nil }
        if p.distance > max(40, fix.accuracy * 1.5) { offRouteFixes += 1; return p }
        if let course = fix.course, fix.speed >= 3, Geo.angle(course, p.bearing) > 70 { offRouteFixes += 1; return p }
        offRouteFixes = 0
        along = p.along; remaining = max(0, path.length - along); initialized = true
        stepIndex = stepEnds.firstIndex(where: { $0 > along + 12 }) ?? max(0, stepEnds.count - 1)
        return p
    }
}
