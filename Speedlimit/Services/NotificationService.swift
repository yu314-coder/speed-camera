import Foundation
import UserNotifications
import Combine

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorized = false
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isRequesting = false
    @Published private(set) var status = "Notifications not enabled"
    private let center = UNUserNotificationCenter.current()
    override init() {
        super.init(); center.delegate = self
        let category = UNNotificationCategory(identifier:"CAMERA_ALERT",actions:[],intentIdentifiers:[],options:.customDismissAction)
        center.setNotificationCategories([category])
        Task { await refresh() }
    }
    func refresh() async {
        let settings = await center.notificationSettings()
        permission = settings.authorizationStatus
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        status = authorized ? "Notification Center cards enabled" : "Enable notifications in iPhone Settings"
    }
    func request() async {
        guard !isRequesting else { return }
        isRequesting = true; defer { isRequesting = false }
        do { _ = try await center.requestAuthorization(options:[.alert,.sound,.badge]); await refresh() }
        catch { status = error.localizedDescription }
    }
    func post(_ alert: NearbyAlert) async {
        guard authorized, alert.camera.coordinate.valid, let meters = alert.distanceMeters else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.camera.roadName
        content.body = alert.message
        content.sound = .default
        content.categoryIdentifier = "CAMERA_ALERT"
        content.threadIdentifier = "taiwan-driving-cameras"
        content.interruptionLevel = .active
        content.userInfo = ["cameraID":alert.camera.id,"type":alert.camera.category.title,"road":alert.camera.roadName,
            "distance":meters,"limit":alert.camera.speedLimit ?? 0,"direction":alert.camera.direction,
            "source":alert.camera.sourceAuthority,"updated":alert.camera.sourceUpdated,
            "latitude":alert.camera.coordinate.latitude,"longitude":alert.camera.coordinate.longitude]
        do {
            try await center.add(UNNotificationRequest(identifier:alert.id,content:content,trigger:nil))
            status = "Last alert: \(alert.camera.roadName)"
        } catch { status = "Notification failed: \(error.localizedDescription)" }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner,.list,.sound]
    }
}
