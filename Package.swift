// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpeedlimitCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SpeedlimitCore", targets: ["SpeedlimitCore"])],
    targets: [
        .target(name: "SpeedlimitCore", path: "Speedlimit",
                exclude: ["Assets.xcassets", "Info.plist", "PrivacyInfo.xcprivacy", "SpeedlimitApp.swift", "Features", "Core/AppModel.swift",
                          "Services/LocationService.swift", "Services/NavigationService.swift", "Services/SearchService.swift",
                          "Services/NotificationService.swift", "Services/SnapshotDecoder.swift", "Services/BackgroundDataRefresh.swift"],
                sources: ["Core/Models.swift", "Core/Geometry.swift", "Core/Matching.swift", "Core/LoadingSafety.swift", "Services/TrafficStore.swift", "Services/CCTVService.swift", "Services/CCTVLiveStream.swift", "Services/JPEGFrameParser.swift", "Services/GovernmentFeed.swift", "Services/GovernmentDataUpdater.swift"],
                resources: [.copy("Resources/tw_traffic.db"),.copy("Resources/osm_section_display_shapes.json")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SpeedlimitHostTests", dependencies: ["SpeedlimitCore"], path: "SpeedlimitTests")
    ]
)
