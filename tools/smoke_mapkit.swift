import Foundation
import MapKit

@main
struct MapKitSmoke {
    @MainActor static func main() async throws {
        let query = MKLocalSearch.Request()
        query.naturalLanguageQuery = "台北車站"
        query.region = MKCoordinateRegion(center:.init(latitude:25.04,longitude:121.52),latitudinalMeters:20_000,longitudinalMeters:20_000)
        let search = MKLocalSearch(request:query)
        let response = try await search.start()
        guard let place = response.mapItems.first else { throw NSError(domain:"Smoke",code:1,userInfo:[NSLocalizedDescriptionKey:"No actual Apple search results"] ) }
        print("Live Apple search: \(response.mapItems.count) results; selected \(place.name ?? "Unknown")")
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:25.041,longitude:121.51)))
        request.destination = place; request.transportType = .automobile; request.requestsAlternateRoutes = true; request.departureDate = Date()
        let service = MKDirections(request:request)
        let directions = try await service.calculate()
        print("Live Apple routes: \(directions.routes.count)")
        for route in directions.routes {
            print("\(route.name): \(route.distance) m, route estimate \(route.expectedTravelTime) s, \(route.polyline.pointCount) vertices")
            for step in route.steps.prefix(6) { print("  \(step.instructions)") }
        }
        let eta = try await MKDirections(request:request).calculateETA()
        print("Live Apple traffic ETA: \(eta.expectedTravelTime) s, \(eta.distance) m (overall trip, not selected alternate)")
    }
}
