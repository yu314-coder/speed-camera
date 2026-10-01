import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var activityType: CLActivityType { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var headingFilter: CLLocationDegrees { get set }
    var headingOrientation: CLDeviceOrientation { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String, completion: ((Error?) -> Void)?)
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startUpdatingHeading()
    func stopUpdatingHeading()
}

extension CLLocationManager: LocationManaging {}

enum LocationSignal: Equatable { case waiting, live, weak, stale, suspended }

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var fix: LocationFix?
    @Published private(set) var heading: Double?
    @Published private(set) var status = "Enable location to start"
    @Published private(set) var isAcquiring = false
    @Published private(set) var acquisitionError: String?
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    @Published private(set) var signal: LocationSignal = .waiting
    private let manager: LocationManaging
    private let acquisitionTimeout: Duration
    private let headingSupported: Bool
    private let acquisitionDeadline = LoadingDeadline()
    private var permissionRequested = false
    private var alwaysRequested = false
    private var acquisitionTimerStarted = false
    private var locationRunning = false
    private var locationPaused = false
    private var headingRunning = false
    private var previous: CLLocation?
    private var isDriving = false
    private var backgroundRequested = false
    private var foreground = true
    private var orientationObserver: AnyCancellable?
    private var watchdog: Task<Void,Never>?
    private let watchdogInterval: Duration
    private var streamStarted = Date.distantPast
    private var lastRecovery = Date.distantPast
    private(set) var recoveryAttempts = 0
    var onFix: ((LocationFix) -> Void)?
    var onSignalLost: (() -> Void)?
    var onAcquisitionFailure: ((String) -> Void)?
    var hasPermission: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }
    var backgroundCapable: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }
    init(manager: LocationManaging? = nil, acquisitionTimeout: Duration = .seconds(12), headingSupported: Bool = CLLocationManager.headingAvailable(), watchdogInterval: Duration = .seconds(2)) {
        self.manager = manager ?? CLLocationManager()
        self.acquisitionTimeout = acquisitionTimeout; self.headingSupported = headingSupported
        self.watchdogInterval = watchdogInterval
        super.init()
        self.manager.delegate = self
        authorization = self.manager.authorizationStatus
        accuracyAuthorization = self.manager.accuracyAuthorization
        self.manager.activityType = .automotiveNavigation
        self.manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager.distanceFilter = 8
        self.manager.headingFilter = 3
        orientationObserver = NotificationCenter.default.publisher(for:UIDevice.orientationDidChangeNotification)
            .debounce(for:.milliseconds(100),scheduler:RunLoop.main)
            .receive(on:RunLoop.main).sink { [weak self] _ in self?.updateOrientation() }
    }
    private func updateOrientation() {
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where:{ $0.activationState == .foregroundActive })?.interfaceOrientation ?? .portrait
        let value = Self.compassOrientation(for:orientation)
        if manager.headingOrientation != value { manager.headingOrientation = value }
    }
    static func compassOrientation(for orientation: UIInterfaceOrientation) -> CLDeviceOrientation {
        // UIKit's landscape screen names are opposite to the physical device names.
        switch orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
    func requestPermission() {
        if hasPermission { configure(); return }
        guard authorization == .notDetermined else {
            status = "Location is off. Enable it in Settings."; return
        }
        guard !permissionRequested else { return }
        permissionRequested = true; manager.requestWhenInUseAuthorization()
    }
    func requestFreshLocation() {
        guard !isAcquiring else { return }
        acquisitionError = nil
        guard authorization != .denied && authorization != .restricted else {
            failAcquisition("Location is off. Enable location for Speedlimit in Settings, then retry."); return
        }
        isAcquiring = true; status = hasPermission ? "Getting current location..." : "Waiting for location permission..."
        let wasRunning = locationRunning
        requestPermission(); configure()
        // Merely calling start on an already-running manager does not reset a stalled stream.
        if wasRunning && locationRunning { restartStream(at:Date(),resetBackoff:true) }
    }
    func cancelFreshLocation() {
        acquisitionDeadline.cancel(); acquisitionTimerStarted = false; isAcquiring = false; acquisitionError = nil; configure()
    }
    private func failAcquisition(_ message: String) {
        acquisitionDeadline.cancel(); acquisitionTimerStarted = false; isAcquiring = false; acquisitionError = message
        configure(); status = message; onAcquisitionFailure?(message)
    }
    func requestAlways() {
        backgroundRequested = true
        if authorization == .authorizedWhenInUse, !alwaysRequested {
            alwaysRequested = true; manager.requestAlwaysAuthorization()
        }
        else if authorization == .notDetermined { requestPermission() }
        configure()
    }
    func requestPreciseLocation() {
        guard hasPermission, accuracyAuthorization == .reducedAccuracy else { return }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey:"RoadMatching") { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorizationChanged()
                if let error { self.acquisitionError = "Precise Location unavailable: \(error.localizedDescription). Enable it in Settings." }
                else if self.accuracyAuthorization == .fullAccuracy { self.requestFreshLocation() }
            }
        }
    }
    func setDriving(_ active: Bool, allowBackground: Bool) {
        guard isDriving != active || backgroundRequested != allowBackground else { return }
        isDriving = active; backgroundRequested = allowBackground
        configure()
        if active && locationPaused { restartStream(at:Date(),resetBackoff:true) }
    }
    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value; let wasRunning = locationRunning; configure()
        if value, wasRunning, locationRunning, fix?.isFresh(maxAge:8) != true {
            restartStream(at:Date(),resetBackoff:true)
        }
    }
    private func configure() {
        if isAcquiring, hasPermission, !acquisitionTimerStarted {
            acquisitionTimerStarted = true
            _ = acquisitionDeadline.begin(after:acquisitionTimeout) { [weak self] in
                self?.failAcquisition("No usable GPS fix yet. Move to an open area, check location settings, then retry.")
            }
        }
        // Setting this without the built target's location capability raises an ObjC exception.
        let background = backgroundCapable && isDriving && backgroundRequested && hasPermission
        manager.allowsBackgroundLocationUpdates = background
        manager.showsBackgroundLocationIndicator = background
        manager.desiredAccuracy = isDriving || isAcquiring ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        // Filtering short movements conflicts with the freshness deadline, e.g. at traffic lights.
        manager.distanceFilter = isAcquiring || isDriving ? kCLDistanceFilterNone : 8
        manager.pausesLocationUpdatesAutomatically = !isDriving && !isAcquiring
        let shouldRun = hasPermission && (foreground || background)
        if shouldRun != locationRunning {
            locationRunning = shouldRun; locationPaused = false
            if shouldRun {
                streamStarted = Date(); recoveryAttempts = 0; lastRecovery = .distantPast
                manager.startUpdatingLocation()
            } else { manager.stopUpdatingLocation(); setSignal(.suspended) }
        }
        let shouldHead = shouldRun && foreground && headingSupported
        if shouldHead != headingRunning {
            headingRunning = shouldHead
            if shouldHead { updateOrientation(); manager.startUpdatingHeading() } else { manager.stopUpdatingHeading() }
        }
        if shouldRun && acquisitionError == nil {
            status = isAcquiring ? "Getting current location..." : (background ? "Drive monitoring active · background location enabled" : "Location active")
        }
        updateWatchdog()
    }
    private func updateWatchdog() {
        let shouldWatch = locationRunning && (isDriving || isAcquiring)
        if !shouldWatch { watchdog?.cancel(); watchdog = nil; return }
        guard watchdog == nil else { return }
        let interval = watchdogInterval
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:interval) } catch { return }
                guard let self else { return }
                self.checkSignal()
            }
        }
        checkSignal()
    }
    func checkSignal(at now: Date = Date()) {
        guard locationRunning, isDriving || isAcquiring else { return }
        if let fix, fix.isFresh(maxAge:8,now:now) {
            setSignal(fix.accuracy > 25 ? .weak : .live); return
        }
        // Allow initial acquisition time; after that, never re-date the last known position.
        if now.timeIntervalSince(streamStarted) >= 8 || fix != nil {
            setSignal(.stale)
            let message = "Location updates delayed · reconnecting automatically"
            if !isAcquiring && status != message { status = message }
        } else { setSignal(.waiting) }
        let delay = min(60,10 * pow(2,Double(min(recoveryAttempts,3))))
        let lastActivity = max(max(streamStarted,lastRecovery),fix?.timestamp ?? .distantPast)
        if now.timeIntervalSince(lastActivity) >= delay {
            restartStream(at:now,resetBackoff:false)
        }
    }
    private func restartStream(at now: Date, resetBackoff: Bool) {
        guard locationRunning, hasPermission else { return }
        if resetBackoff { recoveryAttempts = 0 }
        lastRecovery = now; recoveryAttempts += 1; locationPaused = false; previous = nil
        manager.stopUpdatingLocation(); manager.startUpdatingLocation()
    }
    private func setSignal(_ value: LocationSignal) {
        guard signal != value else { return }
        signal = value
        if value == .stale || value == .suspended { onSignalLost?() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged()
    }
    func authorizationChanged() {
        let old = authorization
        authorization = manager.authorizationStatus; accuracyAuthorization = manager.accuracyAuthorization
        if authorization != .notDetermined { permissionRequested = false }
        if old != authorization { alwaysRequested = false }
        if authorization == .denied || authorization == .restricted {
            if isAcquiring { failAcquisition("Location is off. Enable location for Speedlimit in Settings, then retry.") }
            else { configure(); status = "Location is off. Enable it in Settings." }
        } else { configure() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        receiveLocations(locations)
    }
    func receiveLocations(_ locations: [CLLocation]) {
        guard hasPermission else { return }
        let now = Date()
        guard let location = locations.filter({ Coordinate($0.coordinate).valid && $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy >= 0 &&
            now.timeIntervalSince($0.timestamp) >= -1 && now.timeIntervalSince($0.timestamp) < 10 }).max(by:{ $0.timestamp < $1.timestamp }) else { return }
        guard fix.map({ location.timestamp > $0.timestamp }) ?? true else { return }
        var course: Double?
        if location.speed.isFinite, location.speed >= 3, location.course.isFinite, location.course >= 0, location.course < 360,
           location.courseAccuracy >= 0, location.courseAccuracy <= 30 {
            course = location.course
        } else if location.speed.isFinite, location.speed >= 3, let previous,
                  location.timestamp.timeIntervalSince(previous.timestamp) > 0, location.timestamp.timeIntervalSince(previous.timestamp) <= 8,
                  location.distance(from: previous) > max(12,location.horizontalAccuracy + previous.horizontalAccuracy) {
            course = Geo.bearing(Coordinate(previous.coordinate),Coordinate(location.coordinate))
        }
        if previous.map({ location.distance(from:$0) >= 12 }) ?? true { previous = location }
        let value = LocationFix(coordinate:Coordinate(location.coordinate),timestamp:location.timestamp,accuracy:location.horizontalAccuracy,
            speed:location.speed.isFinite ? max(0,location.speed) : 0,course:course,altitude:location.altitude,verticalAccuracy:location.verticalAccuracy)
        if value.usableForRouting(maxAge:5), isAcquiring || acquisitionError != nil {
            acquisitionDeadline.cancel(); acquisitionTimerStarted = false; isAcquiring = false; acquisitionError = nil; configure()
        }
        fix = value
        if value.isFresh(maxAge:8,now:now) {
            recoveryAttempts = 0; lastRecovery = .distantPast
            setSignal(value.accuracy > 25 ? .weak : .live)
        } else { setSignal(.stale) }
        onFix?(value)
        status = signal == .stale ? "Location updates delayed · reconnecting automatically" :
            (value.accuracy > 25 ? "Weak GPS · alerts paused" : "Location active")
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        receiveHeading(degrees:value,accuracy:newHeading.headingAccuracy)
    }
    func receiveHeading(degrees value: Double, accuracy: Double) {
        guard accuracy.isFinite, accuracy >= 0 else { return }
        guard value.isFinite, value >= 0, value < 360 else { return }
        if let old = heading {
            let delta = (value-old+540).truncatingRemainder(dividingBy:360)-180
            let smoothed = (old+delta*0.55+360).truncatingRemainder(dividingBy:360)
            if Geo.angle(smoothed,old) >= 2 { heading = smoothed }
        } else { heading = value }
    }
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        locationPaused = true
        if isDriving || isAcquiring { checkSignal() }
    }
    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) { locationPaused = false }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError, error.code == .locationUnknown { checkSignal(); return }
        if isAcquiring { failAcquisition(error.localizedDescription) }
        else { status = error.localizedDescription }
    }
    deinit { watchdog?.cancel() }
}
