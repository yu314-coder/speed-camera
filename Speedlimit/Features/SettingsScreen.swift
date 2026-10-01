import SwiftUI
import UIKit

struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var location: LocationService
    @ObservedObject private var notifications: NotificationService
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel) { self.model = model; location = model.location; notifications = model.notifications }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CameraCategory.allCases) { category in
                        Toggle(isOn:Binding(get:{ model.preferences.layers.contains(category) },set:{ enabled in
                            if enabled { model.preferences.layers.insert(category) } else { model.preferences.layers.remove(category) }
                        })) { Label(category.title,systemImage:category.symbol) }
                    }
                    Toggle("Show limited-confidence points",isOn:$model.preferences.showLimited)
                    Text("Includes pale-blue estimated spans. Gray section markers have no reliable full span. Estimates never trigger alerts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Apple traffic overlay",isOn:$model.preferences.traffic)
                } header: { Text("Map layers") } footer: {
                    Text("Numbered badges group cameras: single-type groups keep their color/icon, orange shields are mixed enforcement, and blue video badges are CCTV. Tap to zoom. Blue dashes are verified section-speed spans; pale blue is estimated and gray section pins are unresolved endpoints.")
                }
                Section {
                    Toggle("Driving camera monitoring",isOn:Binding(get:{ model.monitoring },set:{ value in
                        if value != model.monitoring { model.toggleMonitoring() }
                    }))
                    Toggle("Notification Center cards",isOn:$model.preferences.notifications)
                    Button("Enable notification permission") { Task { await notifications.request() } }
                    Text(notifications.status).font(.caption).foregroundStyle(.secondary)
                    ForEach(CameraCategory.allCases.filter { $0 != .cctv }) { category in
                        Toggle("Alert: \(category.title)",isOn:Binding(get:{ model.preferences.alertCategories.contains(category) },set:{ enabled in
                            if enabled { model.preferences.alertCategories.insert(category) } else { model.preferences.alertCategories.remove(category) }
                        }))
                    }
                } header: { Text("Alerts") } footer: {
                    Text("600 m warning, 250 m urgent warning, 120-second repeat suppression. Alerts require a confident same-road and forward-direction match. City-road alerts need an identifiable in-app route where official road geometry is unavailable. Map visibility and alert categories are independent.")
                }
                Section {
                    Toggle("Allow background drive monitoring",isOn:$model.preferences.backgroundMonitoring)
                    Button("Allow Always location") { location.requestAlways() }
                    Text(location.status).font(.caption).foregroundStyle(.secondary)
                    Text("Location permission: \(permissionText)").font(.caption)
                    Text(location.accuracyAuthorization == .fullAccuracy ? "Precise Location: on" : "Precise Location: off").font(.caption)
                    if let fix = location.fix {
                        TimelineView(.periodic(from:.now,by:1)) { context in
                            LabeledContent("Last system fix",value:"\(Int(min(1_000_000,max(0,context.date.timeIntervalSince(fix.timestamp))))) s ago · ±\(Int(min(1_000_000,fix.accuracy))) m")
                                .font(.caption).monospacedDigit()
                        }
                    } else { Text("No system location received yet").font(.caption) }
                    Button("Open iPhone Settings") {
                        if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: { Text("Location & background") } footer: {
                    Text("Enable While Using location first. Always access is optional and requested separately here. Active driving uses unfiltered GPS updates; delayed updates reconnect automatically with backoff. Guidance and alerts pause until a fresh fix arrives. Start monitoring or navigation before leaving the app; force-quitting stops monitoring. Phone heading turns the blue arrow, while GPS travel course controls road matching. Altitude alone cannot distinguish a flyover from the road underneath.")
                }
                Section("Data snapshot") {
                    LabeledContent("Built",value:String(model.summary.builtAt.prefix(10)))
                    if let date = model.summary.governmentUpdatedAt { LabeledContent("Government refresh",value:String(date.prefix(10))) }
                    LabeledContent("Enforcement points",value:String(model.summary.cameras))
                    LabeledContent("Public CCTV points",value:String(model.summary.cctv))
                    LabeledContent("Verified section corridors",value:String(model.summary.verifiedSections))
                    LabeledContent("Estimated display spans",value:String(model.summary.estimatedSections))
                    LabeledContent("Endpoints without a span",value:String(model.summary.unresolvedSectionEndpoints))
                    LabeledContent("Official road segments",value:String(model.summary.roads))
                    LabeledContent("Coordinate-backed speed segments",value:String(model.summary.speedRoads))
                    LabeledContent("Published speed reference entries",value:String(model.summary.speedReferences))
                    if let date = model.summary.speedReferencesCheckedAt { LabeledContent("Speed references checked (UTC)",value:String(date.prefix(10))) }
                    NavigationLink { SpeedReferenceScreen(load:model.speedReferences) } label: {
                        Label("Browse published speed limits",systemImage:"speedometer")
                    }
                    NavigationLink("Sources & coverage") { SourceList(summary:model.summary) }
                }
                Section {
                    Toggle("Automatically update camera data",isOn:$model.automaticDataUpdates)
                        .accessibilityIdentifier("data.autoUpdate")
                    Button("Check government data now") { model.refreshGovernmentData(force:true) }
                        .disabled(model.updatingGovernmentData || model.monitoring || model.navigation.isDriving)
                        .accessibilityIdentifier("data.checkUpdates")
                    if model.updatingGovernmentData { ProgressView("Checking official feeds…") }
                    if let checked = model.governmentUpdateReport.lastChecked {
                        LabeledContent("Last checked",value:checked.formatted(date:.abbreviated,time:.shortened)).font(.caption)
                    }
                    if let message = model.governmentUpdateMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.governmentUpdateReport.sources) { source in
                        VStack(alignment:.leading,spacing:3) {
                            Text(source.title).font(.caption.weight(.semibold))
                            Text("\(source.status) · \(source.records) downloaded records").font(.caption2).foregroundStyle(.secondary)
                            if let error = source.error { Text(error).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("Automatic government updates") } footer: {
                    Text("Checks the national police camera CSV and public freeway/provincial CCTV inventories daily when idle and online. iOS may also allow background refresh; its timing is not guaranteed. Failed sources retain their last working data. County-only enforcement and verified section geometry still use the audited bundled snapshot; new unverified endpoints never become invented alert corridors.")
                }
                Section("Important limits") {
                    Link("Estimated city-road shapes: OpenStreetMap contributors (ODbL)",destination:URL(string:"https://www.openstreetmap.org/copyright")!)
                    if let geometry = Bundle.main.url(forResource:"osm_section_display_shapes",withExtension:"json") {
                        ShareLink("Export derived road geometry (ODbL)",item:geometry)
                    }
                    Text("Official does not mean infallible. Suspect coordinates and inferred-only records do not trigger alerts. Several 台61 agencies publish only one endpoint; pale-blue spans are approximate published-range displays, not surveyed camera boundaries. Gray section markers have no complete span.")
                    Text("Camera data works offline. Apple’s basemap, search, new routes, traffic ETA and CCTV video need a connection. Open a CCTV camera for live video when its official source provides it; otherwise snapshots refresh once a minute. Playback stops when closed or backgrounded. Downloaded camera data is not a guarantee of complete or current enforcement coverage.")
                    Text("MapKit provides routes and instructions, not Apple Maps’ built-in turn-by-turn interface. This app keeps its own guidance in-app. Apple traffic ETA is an overall trip estimate; alternate-route estimates are not falsely labelled live-traffic times.")
                    Text("Other enforcement means multi-violation cameras, such as speed plus red-light, blocked intersections or pedestrian priority. See each camera’s official enforcement description. CCTV is traffic observation, not enforcement.")
                    Text("Obey posted signs. Configure routes only while safely stopped. This app is an aid, not a substitute for attention or road signs.")
                }.font(.footnote)
            }.navigationTitle("Layers & Settings")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(.teal)
    }
    private var permissionText: String {
        switch location.authorization {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using · active drive session only"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet requested"
        @unknown default: return "Unknown"
        }
    }
}

struct SourceList: View {
    let summary: DatasetSummary
    var body: some View {
        List {
            Section {
                Text("Traffic data: 內政部警政署、各縣市警察局、交通部高速公路局、交通部公路局. All coordinates come from published official files; there is no runtime geocoding or API-key requirement for CCTV.")
                Text("Provincial speed-sign downloads were blocked during this build. Taipei, freeway and partial expressway tables are searchable offline references, not new GPS-matched geometry. Vehicle, direction and curve exceptions remain intact. Unmatched roads show Unknown, never a fabricated limit.")
            }
            ForEach(summary.sources) { source in
                VStack(alignment:.leading,spacing:5) {
                    Text(source.name).font(.subheadline.weight(.semibold))
                    Text("\(source.id) · \(source.count) records · \(source.status)").font(.caption).foregroundStyle(.secondary)
                    Text("Metadata: \(source.updated)").font(.caption2).foregroundStyle(.secondary)
                    if let url = URL(string:source.url) { Link("Official source",destination:url).font(.caption) }
                }.padding(.vertical,3)
            }
        }.navigationTitle("Sources & Coverage")
    }
}
