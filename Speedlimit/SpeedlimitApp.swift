import SwiftUI

@main
struct SpeedlimitApp: App {
    @StateObject private var model = AppModel()
    init() { BackgroundDataRefresh.register() }
    var body: some Scene { WindowGroup { MapScreen(model:model) } }
}
