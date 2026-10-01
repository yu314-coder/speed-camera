import Foundation
import BackgroundTasks

@MainActor
enum BackgroundDataRefresh {
    static let identifier = "tw.speedlimit.app.refresh"
    static let drivingKey = "government.activeDrive.v1"
    static func register() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier,using:.main) { task in
            let operation = Task { @MainActor in
                schedule()
                guard GovernmentDataUpdater.isEnabled, !UserDefaults.standard.bool(forKey:drivingKey) else {
                    task.setTaskCompleted(success:true); return
                }
                let report = await GovernmentDataUpdater.shared.refresh()
                task.setTaskCompleted(success:!Task.isCancelled && !report.hasFailures)
            }
            task.expirationHandler = { operation.cancel() }
        }
        schedule()
    }
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier)
        guard GovernmentDataUpdater.isEnabled,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        let request = BGAppRefreshTaskRequest(identifier:identifier)
        request.earliestBeginDate = Date().addingTimeInterval(86_400)
        try? BGTaskScheduler.shared.submit(request)
    }
}
