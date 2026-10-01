import XCTest
#if !SWIFT_PACKAGE
import CoreLocation
import MapKit
import UIKit
import Combine
@testable import Speedlimit

@MainActor
final class SearchTypingTests: XCTestCase {
    func testPermissionToBeginEditingCannotHideMapBeforeActualFocus() {
        let service = SearchService(provider:{ _ in [] })
        var focused = false
        let field = NativeSearchField(search:service,onFocus:{ focused = $0 })
        let coordinator = field.makeCoordinator(), native = UISearchTextField()
        XCTAssertTrue(coordinator.textFieldShouldBeginEditing(native))
        XCTAssertFalse(focused)
        coordinator.textFieldDidBeginEditing(native); XCTAssertTrue(focused)
        coordinator.textFieldDidEndEditing(native); XCTAssertFalse(focused)
    }
    func testRapidTypingDoesNotPublishSwiftUIUpdatesPerCharacter() {
        let service = SearchService(provider:{ _ in [] })
        var publications = 0
        let subscription = service.objectWillChange.sink { publications += 1 }
        let start = Date()
        for index in 1...200 { service.edit("Taipei \(index)") }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(publications,0,"Keystrokes should stay in the native field, not invalidate SwiftUI")
        XCTAssertEqual(service.query,"Taipei 200")
        print("PERFORMANCE native search scheduling: \(elapsed*1000/200) ms/edit; no completion/network work measured")
        XCTAssertLessThan(elapsed,0.5)
        service.clear(); withExtendedLifetime(subscription) {}
    }
    func testClearNotifiesNativeFieldWithoutReleasingKeyboard() {
        let service = SearchService(provider:{ _ in [] })
        service.edit("Taipei")
        let revision = service.inputRevision, focus = service.focusRelease
        service.clear()
        XCTAssertEqual(service.query,""); XCTAssertEqual(service.inputRevision,revision+1)
        XCTAssertEqual(service.focusRelease,focus)
    }
}

@MainActor
final class TestLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var activityType: CLActivityType = .other
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var headingFilter: CLLocationDegrees = 0
    var headingOrientation: CLDeviceOrientation = .portrait
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var pausesLocationUpdatesAutomatically = true
    var permissionRequests = 0, alwaysRequests = 0, starts = 0, stops = 0, headingStarts = 0, headingStops = 0
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String, completion: ((Error?) -> Void)?) { completion?(nil) }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func startUpdatingHeading() { headingStarts += 1 }
    func stopUpdatingHeading() { headingStops += 1 }
}

@MainActor
final class GPSDestinationTests: XCTestCase {
    func gps(_ accuracy: Double = 5, age: TimeInterval = 0, speed: Double = 0, course: Double = -1) -> CLLocation {
        CLLocation(coordinate:.init(latitude:25.04,longitude:121.51),altitude:10,horizontalAccuracy:accuracy,
                   verticalAccuracy:5,course:course,courseAccuracy:5,speed:speed,speedAccuracy:1,timestamp:Date().addingTimeInterval(-age))
    }
    func place() -> MKMapItem { MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:25.06,longitude:121.51))) }
    func navigation() -> NavigationService {
        NavigationService(routeProvider: { fix,item in
            [.init(name:"GPS test",coordinates:[fix.coordinate,Coordinate(item.placemark.coordinate)],instructions:["Continue north"])]
        })
    }
    func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testPermissionIsInitializedAndGrantedRequestsAreIdempotent() {
        let manager = TestLocationManager()
        let service = LocationService(manager:manager,headingSupported:true)
        XCTAssertEqual(service.authorization,.authorizedWhenInUse)
        for _ in 0..<10 { service.requestPermission(); service.setForeground(true) }
        XCTAssertEqual(manager.permissionRequests,0); XCTAssertEqual(manager.starts,1); XCTAssertEqual(manager.headingStarts,1)
        service.setForeground(false); service.setForeground(false)
        XCTAssertEqual(manager.stops,1); XCTAssertEqual(manager.headingStops,1)
    }
    func testFreshGPSUsesContinuousBurstAndRestoresIdlePolicy() {
        let manager = TestLocationManager()
        let location = LocationService(manager:manager,headingSupported:false)
        location.requestFreshLocation(); location.requestFreshLocation()
        XCTAssertTrue(location.isAcquiring); XCTAssertEqual(manager.starts,1)
        XCTAssertEqual(manager.distanceFilter,kCLDistanceFilterNone); XCTAssertFalse(manager.pausesLocationUpdatesAutomatically)
        location.receiveLocations([gps()])
        XCTAssertFalse(location.isAcquiring); XCTAssertNil(location.acquisitionError)
        XCTAssertEqual(manager.distanceFilter,8); XCTAssertTrue(manager.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(manager.starts,1)
    }
    func testWeakAndCachedGPSCannotCompleteAcquisition() {
        let location = LocationService(manager:TestLocationManager(),headingSupported:false)
        location.requestFreshLocation(); location.receiveLocations([gps(500)])
        XCTAssertTrue(location.isAcquiring)
        location.receiveLocations([gps(5,age:30)]); XCTAssertTrue(location.isAcquiring)
        location.receiveLocations([gps()]); XCTAssertFalse(location.isAcquiring)
    }
    func testFreshRequestResumesAutomaticallyPausedUpdates() {
        let manager = TestLocationManager()
        let service = LocationService(manager:manager,headingSupported:false)
        service.requestPermission(); XCTAssertEqual(manager.starts,1)
        service.locationManagerDidPauseLocationUpdates(CLLocationManager())
        service.requestFreshLocation(); XCTAssertEqual(manager.starts,2)
        service.receiveLocations([gps()]); XCTAssertFalse(service.isAcquiring)
    }
    func testPermissionPromptIsNotRepeatedWhileAwaitingConsent() {
        let manager = TestLocationManager(); manager.authorizationStatus = .notDetermined
        let location = LocationService(manager:manager,headingSupported:false)
        location.requestFreshLocation(); location.requestPermission(); location.requestFreshLocation()
        XCTAssertEqual(manager.permissionRequests,1); XCTAssertEqual(manager.starts,0)
        manager.authorizationStatus = .authorizedWhenInUse; location.authorizationChanged()
        XCTAssertTrue(location.isAcquiring); XCTAssertEqual(manager.starts,1)
        location.cancelFreshLocation()
        manager.authorizationStatus = .notDetermined; location.authorizationChanged(); location.requestPermission()
        XCTAssertEqual(manager.permissionRequests,2)
    }
    func testGPSDeadlineStartsAfterPermissionConsentNotWhileDialogIsOpen() async throws {
        let manager = TestLocationManager(); manager.authorizationStatus = .notDetermined
        let location = LocationService(manager:manager,acquisitionTimeout:.milliseconds(30),headingSupported:false)
        location.requestFreshLocation()
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertTrue(location.isAcquiring); XCTAssertNil(location.acquisitionError)
        manager.authorizationStatus = .authorizedWhenInUse; location.authorizationChanged()
        try await waitUntil { !location.isAcquiring }
        XCTAssertNotNil(location.acquisitionError)
    }
    func testLaunchAndMonitoringDoNotStackAlwaysPermissionPrompts() async throws {
        let manager = TestLocationManager(); manager.authorizationStatus = .notDetermined
        let location = LocationService(manager:manager,headingSupported:false), model = AppModel(location:location)
        model.preferences.notifications = false
        await model.start(); try await waitUntil { model.dataState == .ready }
        XCTAssertEqual(manager.permissionRequests,0)
        model.toggleMonitoring(); XCTAssertEqual(manager.permissionRequests,1); XCTAssertEqual(manager.alwaysRequests,0)
        manager.authorizationStatus = .authorizedWhenInUse; location.authorizationChanged()
        XCTAssertEqual(manager.alwaysRequests,0)
        location.requestAlways(); location.requestAlways(); XCTAssertEqual(manager.alwaysRequests,1)
        model.toggleMonitoring()
    }
    func testSearchFocusSuspendsViewportQueriesAndResumesLatestRegion() async throws {
        let model = AppModel(location:LocationService(manager:TestLocationManager(),headingSupported:false))
        await model.start(); try await waitUntil { !model.cameras.isEmpty }
        let revision = model.mapRevision
        model.setSearchFocused(true)
        model.regionChanged(.init(center:.init(latitude:23.5,longitude:120.5),span:.init(latitudeDelta:0.1,longitudeDelta:0.1)))
        try await Task.sleep(for:.milliseconds(300)); XCTAssertEqual(model.mapRevision,revision)
        model.setSearchFocused(false); try await waitUntil { model.mapRevision > revision }
    }
    func testSettingsLayerMutationActuallyRemovesAndRestoresCCTV() async throws {
        let model = AppModel(location:LocationService(manager:TestLocationManager(),headingSupported:false))
        model.preferences.layers = Set(CameraCategory.allCases)
        await model.start(); try await waitUntil { model.cameras.contains { $0.category == .cctv } }
        model.preferences.layers.remove(.cctv)
        try await waitUntil { !model.cameras.contains { $0.category == .cctv } }
        model.preferences.layers.insert(.cctv)
        try await waitUntil { model.cameras.contains { $0.category == .cctv } }
    }
    func testDeniedGPSFailsImmediatelyWithoutPromptOrBackgroundUpdates() {
        let manager = TestLocationManager(); manager.authorizationStatus = .denied
        let location = LocationService(manager:manager,headingSupported:false)
        var failed = false; location.onAcquisitionFailure = { _ in failed = true }
        location.requestFreshLocation()
        XCTAssertTrue(failed); XCTAssertFalse(location.isAcquiring); XCTAssertEqual(manager.permissionRequests,0)
        XCTAssertEqual(manager.starts,0); XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
    }
    func testAcquisitionTimeoutClearsSpinnerAndCanRetry() async throws {
        let manager = TestLocationManager()
        let service = LocationService(manager:manager,acquisitionTimeout:.milliseconds(30),headingSupported:false)
        service.requestFreshLocation(); try await waitUntil { !service.isAcquiring }
        XCTAssertNotNil(service.acquisitionError); XCTAssertEqual(manager.distanceFilter,8)
        service.requestFreshLocation(); service.receiveLocations([gps()])
        XCTAssertFalse(service.isAcquiring); XCTAssertNil(service.acquisitionError)
    }
    func testCancelledAcquisitionDoesNotPublishLateTimeout() async throws {
        let location = LocationService(manager:TestLocationManager(),acquisitionTimeout:.milliseconds(30),headingSupported:false)
        var failures = 0; location.onAcquisitionFailure = { _ in failures += 1 }
        location.requestFreshLocation(); location.cancelFreshLocation()
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertFalse(location.isAcquiring); XCTAssertNil(location.acquisitionError); XCTAssertEqual(failures,0)
    }
    func testGPSBatchUsesNewestFixAndDoesNotInventStationaryCourse() {
        let location = LocationService(manager:TestLocationManager(),headingSupported:false)
        location.receiveLocations([gps(),gps(5,age:2)])
        XCTAssertLessThan(abs(location.fix!.timestamp.timeIntervalSinceNow),1); XCTAssertNil(location.fix?.course)
        let time = location.fix!.timestamp
        location.receiveLocations([gps(5,age:3)]); XCTAssertEqual(location.fix?.timestamp,time)
        location.receiveLocations([gps(5,speed:20,course:180)]); XCTAssertEqual(location.fix?.course,180)
    }
    func testPhoneRotationChangesCompassWithoutChangingTravelDirection() {
        let location = LocationService(manager:TestLocationManager(),headingSupported:false)
        location.receiveLocations([gps(5,speed:20,course:180)])
        location.receiveHeading(degrees:0,accuracy:5); location.receiveHeading(degrees:90,accuracy:5)
        XCTAssertGreaterThan(location.heading!,40); XCTAssertEqual(location.fix?.course,180)
        let heading = location.heading
        location.receiveHeading(degrees:.nan,accuracy:5); location.receiveHeading(degrees:180,accuracy:-1)
        XCTAssertEqual(location.heading,heading)
    }
    func testLandscapeCompassUsesDeviceOrientationNotScreenCaseName() {
        XCTAssertEqual(LocationService.compassOrientation(for:.landscapeLeft),.landscapeRight)
        XCTAssertEqual(LocationService.compassOrientation(for:.landscapeRight),.landscapeLeft)
        XCTAssertEqual(LocationService.compassOrientation(for:.portrait),.portrait)
        XCTAssertEqual(LocationService.compassOrientation(for:.portraitUpsideDown),.portraitUpsideDown)
        XCTAssertEqual(LocationService.compassOrientation(for:.unknown),.portrait)
    }
    func testBlueArrowRotatesRelativeToMapAndHidesInvalidHeading() {
        let dot = UserDotView(annotation:nil,reuseIdentifier:"gps")
        let arrow = dot.layer.sublayers!.first!
        dot.update(heading:90,mapHeading:30)
        let rotation = atan2(arrow.affineTransform().b,arrow.affineTransform().a)
        XCTAssertEqual(rotation,.pi/3,accuracy:0.001); XCTAssertFalse(arrow.isHidden)
        dot.update(heading:.nan,mapHeading:0); XCTAssertTrue(arrow.isHidden)
    }
    func testAcquisitionDoesNotEnableBackgroundOutsideDrivingSession() {
        let manager = TestLocationManager()
        let service = LocationService(manager:manager,headingSupported:false)
        service.requestFreshLocation(); service.setDriving(false,allowBackground:true); service.setForeground(false)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates); XCTAssertEqual(manager.stops,1)
        service.cancelFreshLocation()
    }
    func testDestinationWaitsForGPSAndResumesOnlyOnce() async throws {
        var calls = 0
        let nav = NavigationService(routeProvider:{ fix,item in
            calls += 1; return [.init(name:"GPS",coordinates:[fix.coordinate,Coordinate(item.placemark.coordinate)],instructions:[])]
        })
        nav.pick(place(),from:nil,waitForLocation:true)
        XCTAssertEqual(nav.phase,.waitingForLocation); XCTAssertNotNil(nav.destination)
        XCTAssertFalse(nav.resumePendingRoute(from:.init(coordinate:.init(25.04,121.51),accuracy:500)))
        let fix = LocationFix(coordinate:.init(25.04,121.51))
        XCTAssertTrue(nav.resumePendingRoute(from:fix)); XCTAssertFalse(nav.resumePendingRoute(from:fix))
        try await waitUntil { nav.phase == .preview }; XCTAssertEqual(calls,1)
    }
    func testAppDestinationAutomaticallyAcquiresAndUsesFreshStationaryGPS() async throws {
        let manager = TestLocationManager()
        let service = LocationService(manager:manager,headingSupported:false), nav = navigation()
        let model = AppModel(location:service,navigation:nav)
        model.pick(place()); XCTAssertEqual(nav.phase,.waitingForLocation); XCTAssertTrue(service.isAcquiring)
        service.receiveLocations([gps()]); try await waitUntil { nav.phase == .preview }
        XCTAssertFalse(service.isAcquiring); XCTAssertEqual(nav.routes.count,1)
        model.stopNavigation()
    }
    func testCancelledDestinationCannotResumeOnLaterGPS() async throws {
        let location = LocationService(manager:TestLocationManager(),headingSupported:false), nav = navigation()
        let model = AppModel(location:location,navigation:nav)
        model.pick(place()); model.stopNavigation(); location.receiveLocations([gps()])
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertEqual(nav.phase,.idle); XCTAssertNil(nav.destination); XCTAssertFalse(location.isAcquiring)
    }
    func testGPSFailureRetainsDestinationForRetry() async throws {
        let location = LocationService(manager:TestLocationManager(),acquisitionTimeout:.milliseconds(30),headingSupported:false), nav = navigation()
        let model = AppModel(location:location,navigation:nav)
        model.pick(place()); try await waitUntil { nav.phase == .failed }
        XCTAssertNotNil(nav.destination); XCTAssertNotNil(nav.error)
        model.retryRoute(); XCTAssertEqual(nav.phase,.waitingForLocation)
        location.receiveLocations([gps()]); try await waitUntil { nav.phase == .preview }; model.stopNavigation()
    }
    func testLateGPSClearsOldSignalErrorWithoutResurrectingTimedOutRoute() async throws {
        let location = LocationService(manager:TestLocationManager(),acquisitionTimeout:.milliseconds(30),headingSupported:false), nav = navigation()
        let model = AppModel(location:location,navigation:nav)
        model.pick(place()); try await waitUntil { nav.phase == .failed }
        XCTAssertNotNil(location.acquisitionError)
        location.receiveLocations([gps()]); XCTAssertNil(location.acquisitionError)
        XCTAssertEqual(nav.phase,.failed); XCTAssertTrue(nav.routes.isEmpty)
        model.retryRoute(); try await waitUntil { nav.phase == .preview }; model.stopNavigation()
    }
    func testStartWaitsForFreshGPSAndTimeoutIsRecoverable() async throws {
        let location = LocationService(manager:TestLocationManager(),acquisitionTimeout:.milliseconds(30),headingSupported:false), nav = navigation()
        let model = AppModel(location:location,navigation:nav)
        location.receiveLocations([gps(5,age:7)]); model.pick(place())
        try await waitUntil { nav.phase == .preview }
        // Direct route preview can exist with no live service fix.
        let empty = LocationService(manager:TestLocationManager(),acquisitionTimeout:.milliseconds(30),headingSupported:false)
        let other = AppModel(location:empty,navigation:nav); other.startNavigation()
        XCTAssertTrue(other.startingNavigation)
        try await waitUntil { !other.startingNavigation }
        XCTAssertEqual(nav.phase,.preview); XCTAssertNotNil(nav.error)
        other.preferences.notifications = false; other.startNavigation(); empty.receiveLocations([gps()])
        XCTAssertEqual(nav.phase,.navigating); XCTAssertFalse(other.startingNavigation); other.stopNavigation()
    }
    func testSameRouteSelectionDoesNotInvalidateMap() async throws {
        let nav = navigation(); nav.pick(place(),from:.init(coordinate:.init(25.04,121.51)))
        try await waitUntil { nav.phase == .preview }
        let revision = nav.revision; nav.select(try XCTUnwrap(nav.selectedID))
        XCTAssertEqual(nav.revision,revision); nav.stop()
    }
    func testRouteOverlayIdentityIsRetainedWhenSwitchingAlternatives() {
        let location = LocationService(manager:TestLocationManager(),headingSupported:false)
        let a = RouteOption(name:"A",coordinates:[.init(25,121),.init(25.1,121)],instructions:[])
        let b = RouteOption(name:"B",coordinates:[.init(25,121),.init(25.1,121.1)],instructions:[])
        func parent(_ id: UUID) -> TaiwanMapView {
            .init(cameras:[],zones:[],dataRevision:0,routeOptions:[a,b],selectedRouteID:id,routeRevision:0,
                  destination:.init(25.1,121),destinationTitle:"Test",navigating:true,location:location,followRequest:0,
                  traffic:false,picking:false,onRegion:{ _ in },onPick:{ _ in },onCamera:{ _ in },onRoute:{ _ in })
        }
        let map = MKMapView(frame:.zero), coordinator = parent(a.id).makeCoordinator()
        coordinator.map = map; coordinator.updateRoutes(); XCTAssertEqual(map.overlays.count,2)
        coordinator.parent = parent(b.id); coordinator.updateRoutes()
        XCTAssertEqual(map.overlays.count,2); XCTAssertTrue(map.overlays.contains { $0 === a.polyline })
        XCTAssertTrue(map.overlays.contains { $0 === b.polyline }); XCTAssertEqual(b.polyline.title,"selected-route")
        coordinator.cancel()
    }
}
#endif
