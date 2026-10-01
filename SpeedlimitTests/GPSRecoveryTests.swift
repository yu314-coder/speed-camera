import XCTest
#if !SWIFT_PACKAGE
import CoreLocation
import MapKit
@testable import Speedlimit

@MainActor
final class GPSRecoveryTests: XCTestCase {
    func gps(age: TimeInterval = 0, accuracy: Double = 5, speed: Double = 0) -> CLLocation {
        CLLocation(coordinate:.init(latitude:25.04,longitude:121.51),altitude:10,horizontalAccuracy:accuracy,
                   verticalAccuracy:5,course:speed >= 3 ? 0 : -1,courseAccuracy:5,speed:speed,speedAccuracy:1,
                   timestamp:Date().addingTimeInterval(-age))
    }
    func place() -> MKMapItem { MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:25.06,longitude:121.51))) }
    func route() -> RouteOption { .init(name:"GPS",coordinates:[.init(25.04,121.51),.init(25.06,121.51)],instructions:["Continue north"]) }
    func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testDrivingDoesNotFilterStationaryOrShortMovementUpdates() {
        let manager = TestLocationManager()
        let active = LocationService(manager:manager,headingSupported:false)
        active.setDriving(true,allowBackground:false)
        XCTAssertEqual(manager.distanceFilter,kCLDistanceFilterNone)
        XCTAssertFalse(manager.pausesLocationUpdatesAutomatically)
        active.setDriving(false,allowBackground:false)
        XCTAssertEqual(manager.distanceFilter,8); XCTAssertTrue(manager.pausesLocationUpdatesAutomatically)
    }
    func testRetryReallyRestartsAnAlreadyRunningStreamExactlyOnce() {
        let manager = TestLocationManager()
        let active = LocationService(manager:manager,headingSupported:false)
        active.requestPermission(); XCTAssertEqual(manager.starts,1)
        active.requestFreshLocation(); active.requestFreshLocation()
        XCTAssertEqual(manager.starts,2); XCTAssertEqual(manager.stops,1)
        active.receiveLocations([gps()]); XCTAssertFalse(active.isAcquiring)
        XCTAssertEqual(active.signal,.live); XCTAssertEqual(manager.starts,2)
    }
    func testStallRecoveryHasBoundedExponentialBackoffAndResetsOnFreshFix() {
        let manager = TestLocationManager()
        let active = LocationService(manager:manager,headingSupported:false)
        active.setDriving(true,allowBackground:false)
        let fix = gps(); active.receiveLocations([fix])
        var losses = 0; active.onSignalLost = { losses += 1 }
        let now = fix.timestamp
        active.checkSignal(at:now.addingTimeInterval(8.1))
        XCTAssertEqual(active.signal,.stale); XCTAssertEqual(losses,1)
        active.checkSignal(at:now.addingTimeInterval(11)); XCTAssertEqual(manager.starts,2)
        for _ in 0..<100 { active.checkSignal(at:now.addingTimeInterval(20)) }
        XCTAssertEqual(manager.starts,2); XCTAssertEqual(losses,1)
        active.checkSignal(at:now.addingTimeInterval(32)); XCTAssertEqual(manager.starts,3)
        active.checkSignal(at:now.addingTimeInterval(73)); XCTAssertEqual(manager.starts,4)
        active.checkSignal(at:now.addingTimeInterval(120)); XCTAssertEqual(manager.starts,4)
        active.checkSignal(at:now.addingTimeInterval(134)); XCTAssertEqual(manager.starts,5)
        XCTAssertEqual(active.fix?.timestamp,fix.timestamp,"Recovery must not re-date a cached position")
        active.receiveLocations([gps()]); XCTAssertEqual(active.signal,.live); XCTAssertEqual(active.recoveryAttempts,0)
        active.setDriving(false,allowBackground:false)
    }
    func testCachedDuplicateAndFutureFixCannotHealAStaleStream() {
        let service = LocationService(manager:TestLocationManager(),headingSupported:false)
        service.setDriving(true,allowBackground:false)
        let fix = gps(); service.receiveLocations([fix])
        var deliveries = 0; service.onFix = { _ in deliveries += 1 }
        service.checkSignal(at:fix.timestamp.addingTimeInterval(9))
        service.receiveLocations([fix,gps(age:-5)])
        XCTAssertEqual(service.signal,.stale); XCTAssertEqual(deliveries,0)
        XCTAssertEqual(service.fix?.timestamp,fix.timestamp)
        service.setDriving(false,allowBackground:false)
    }
    func testFreshStationaryFixesStayLiveWithoutInventingCourse() {
        let service = LocationService(manager:TestLocationManager(),headingSupported:false)
        service.setDriving(true,allowBackground:false)
        for _ in 0..<100 { service.receiveLocations([gps()]); service.checkSignal() }
        XCTAssertEqual(service.signal,.live); XCTAssertNil(service.fix?.course)
        XCTAssertEqual(service.recoveryAttempts,0)
        service.setDriving(false,allowBackground:false)
    }
    func testPauseDuringDrivingAutomaticallyRecoversWithoutRetry() {
        let manager = TestLocationManager(), service = LocationService(manager:manager,headingSupported:false)
        service.setDriving(true,allowBackground:false)
        let fix = gps(); service.receiveLocations([fix])
        service.locationManagerDidPauseLocationUpdates(CLLocationManager())
        service.checkSignal(at:fix.timestamp.addingTimeInterval(11))
        XCTAssertEqual(manager.starts,2); XCTAssertEqual(manager.stops,1)
        service.receiveLocations([gps()]); XCTAssertEqual(service.signal,.live)
        service.setDriving(false,allowBackground:false)
    }
    func testBackgroundWithoutAnActiveSessionNeverRestartsGPS() {
        let manager = TestLocationManager(), service = LocationService(manager:manager,headingSupported:false)
        service.requestPermission(); service.setForeground(false)
        service.checkSignal(at:Date().addingTimeInterval(300))
        XCTAssertEqual(manager.starts,1); XCTAssertEqual(manager.stops,1)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates); XCTAssertEqual(service.signal,.suspended)
    }
    func testActiveBackgroundSessionKeepsWatchdogOnlyWithBuiltCapability() {
        let manager = TestLocationManager(), service = LocationService(manager:manager,headingSupported:false)
        service.setDriving(true,allowBackground:true); service.setForeground(false)
        service.checkSignal(at:Date().addingTimeInterval(15))
        XCTAssertEqual(manager.allowsBackgroundLocationUpdates,service.backgroundCapable)
        XCTAssertEqual(manager.starts,service.backgroundCapable ? 2 : 1)
        service.setDriving(false,allowBackground:false)
    }
    func testDeniedPermissionStopsWatchdogAndDoesNotReprompt() {
        let manager = TestLocationManager(), service = LocationService(manager:manager,headingSupported:false)
        service.setDriving(true,allowBackground:true)
        manager.authorizationStatus = .denied; service.authorizationChanged()
        for _ in 0..<100 { service.checkSignal(at:Date().addingTimeInterval(300)) }
        XCTAssertEqual(manager.starts,1); XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
        XCTAssertEqual(manager.permissionRequests,0)
        service.receiveLocations([gps()]); XCTAssertNil(service.fix)
    }
    func testForegroundReturnRecoversStaleAlreadyRunningBackgroundSession() {
        let manager = TestLocationManager(), service = LocationService(manager:manager,headingSupported:false)
        service.setDriving(true,allowBackground:true); service.setForeground(false)
        let starts = manager.starts
        service.setForeground(true)
        XCTAssertEqual(manager.starts,starts+1)
        service.setForeground(true); XCTAssertEqual(manager.starts,starts+1)
        service.setDriving(false,allowBackground:false)
    }
    func testTransientLocationUnknownDoesNotCauseRestartStorm() {
        let manager = TestLocationManager(), service = LocationService(manager:manager,headingSupported:false)
        service.setDriving(true,allowBackground:false); service.receiveLocations([gps()])
        for _ in 0..<100 { service.locationManager(CLLocationManager(),didFailWithError:CLError(.locationUnknown)) }
        XCTAssertEqual(manager.starts,1); XCTAssertEqual(service.signal,.live)
        service.setDriving(false,allowBackground:false)
    }
    func testWatchdogExpiresGPSWithoutAnotherDelegateCallback() async throws {
        let service = LocationService(manager:TestLocationManager(),headingSupported:false,watchdogInterval:.milliseconds(20))
        service.setDriving(true,allowBackground:false); service.receiveLocations([gps(age:7.95)])
        try await waitUntil { service.signal == .stale }
        service.setDriving(false,allowBackground:false)
    }
    func testWatchdogDoesNotRetainItsOwner() {
        var service: LocationService? = LocationService(manager:TestLocationManager(),headingSupported:false)
        weak var reference = service
        service?.setDriving(true,allowBackground:false); service = nil
        XCTAssertNil(reference)
    }
    func testStaleAndWeakGPSPauseGuidanceButPreserveTheRoute() async throws {
        let nav = NavigationService(routeProvider:{ _,_ in [self.route()] })
        let fix = LocationFix(coordinate:.init(25.04,121.51),speed:0,course:nil)
        nav.pick(place(),from:fix); try await waitUntil { nav.phase == .preview }
        XCTAssertTrue(nav.start(fix:fix)); let id = nav.selectedID, distance = nav.maneuverDistance
        nav.pauseForLocation()
        XCTAssertTrue(nav.guidancePaused); XCTAssertTrue(nav.isDriving); XCTAssertEqual(nav.selectedID,id)
        nav.update(.init(coordinate:.init(25.05,121.51),timestamp:Date().addingTimeInterval(-9)))
        XCTAssertTrue(nav.guidancePaused); XCTAssertEqual(nav.maneuverDistance,distance)
        nav.update(.init(coordinate:.init(25.05,121.51),accuracy:80))
        XCTAssertTrue(nav.guidancePaused); XCTAssertEqual(nav.maneuverDistance,distance)
        nav.update(.init(coordinate:.init(25.05,121.51),speed:0,course:nil))
        XCTAssertFalse(nav.guidancePaused); XCTAssertLessThan(nav.maneuverDistance,distance)
        nav.stop()
    }
    func testModeAndPreferenceChangesCannotCancelGPSExpiry() async throws {
        let model = AppModel(location:LocationService(manager:TestLocationManager(),headingSupported:false))
        model.receive(.init(coordinate:.init(25.04,121.51),timestamp:Date().addingTimeInterval(-7.85)))
        model.updateMonitoring(); model.preferences.traffic.toggle(); model.updateMonitoring()
        try await waitUntil { model.gpsStale }
        XCTAssertNil(model.latestAlert); XCTAssertNil(model.roadContext)
    }
    func testReplayedFixCannotExtendAppFreshnessDeadline() async throws {
        let model = AppModel(location:LocationService(manager:TestLocationManager(),headingSupported:false))
        let fix = LocationFix(coordinate:.init(25.04,121.51),timestamp:Date().addingTimeInterval(-7.85))
        model.receive(fix)
        for _ in 0..<100 { model.receive(fix) }
        try await waitUntil { model.gpsStale }
        model.receive(fix); XCTAssertTrue(model.gpsStale)
        model.receive(.init(coordinate:.init(25.04,121.51),timestamp:Date().addingTimeInterval(5)))
        XCTAssertTrue(model.gpsStale)
    }
    func testAppExpiryPausesManeuverAndFreshGPSResumesIt() async throws {
        let service = LocationService(manager:TestLocationManager(),headingSupported:false)
        let nav = NavigationService(routeProvider:{ _,_ in [self.route()] })
        let model = AppModel(location:service,navigation:nav); model.preferences.notifications = false
        service.receiveLocations([gps(age:7.8)])
        model.pick(place()); try await waitUntil { nav.phase == .preview }; model.startNavigation()
        XCTAssertTrue(nav.isDriving)
        try await waitUntil { model.gpsStale }
        XCTAssertTrue(nav.guidancePaused)
        let id = nav.selectedID
        service.receiveLocations([gps()]); XCTAssertFalse(model.gpsStale); XCTAssertFalse(nav.guidancePaused)
        XCTAssertEqual(nav.selectedID,id); model.stopNavigation()
    }
    func testStartRejectsNineSecondOldGPS() async throws {
        let nav = NavigationService(routeProvider:{ _,_ in [self.route()] })
        nav.pick(place(),from:.init(coordinate:.init(25.04,121.51)))
        try await waitUntil { nav.phase == .preview }
        XCTAssertFalse(nav.start(fix:.init(coordinate:.init(25.04,121.51),timestamp:Date().addingTimeInterval(-9))))
        XCTAssertEqual(nav.phase,.preview); nav.stop()
    }
    func testNavigationCannotCenterOnAnUninitializedOrStaleBlueDot() {
        XCTAssertNil(TaiwanMapView.navigationCenter(mapLocation:nil,fallback:nil))
        XCTAssertNil(TaiwanMapView.navigationCenter(mapLocation:gps(age:20),fallback:nil))
        XCTAssertNil(TaiwanMapView.navigationCenter(mapLocation:gps(accuracy:500),fallback:nil))
        XCTAssertNil(TaiwanMapView.navigationCenter(mapLocation:gps(age:-5),fallback:nil))
        let fresh = gps()
        XCTAssertEqual(TaiwanMapView.navigationCenter(mapLocation:fresh,fallback:nil),Coordinate(fresh.coordinate))
    }
    func testNavigationCenterCanUseOnlyAFreshValidatedServiceFix() {
        let fix = LocationFix(coordinate:.init(25.04,121.51))
        XCTAssertEqual(TaiwanMapView.navigationCenter(mapLocation:gps(age:20),fallback:fix),fix.coordinate)
        XCTAssertNil(TaiwanMapView.navigationCenter(mapLocation:nil,fallback:.init(coordinate:fix.coordinate,timestamp:Date().addingTimeInterval(-9))))
    }
}
#endif
