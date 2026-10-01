import SwiftUI
import MapKit

struct MapScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var navigation: NavigationService
    private let location: LocationService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingMapKey = false
    init(model: AppModel) {
        self.model = model; navigation = model.navigation; location = model.location
    }
    var body: some View {
        ZStack {
            if scenePhase != .background {
            TaiwanMapView(cameras:model.cameras,zones:model.zones,dataRevision:model.mapRevision,
                routeOptions:navigation.routes,selectedRouteID:navigation.selectedID,routeRevision:navigation.revision,
                destination:navigation.coordinate,destinationTitle:navigation.destination?.name,navigating:navigation.isDriving,
                location:location,followRequest:model.followRequest,traffic:model.preferences.traffic,picking:model.pickingDestination,searching:model.searchFocused,initialRegion:model.mapRegion,
                onRegion:model.regionChanged,onPick:model.pick,onCamera:{ model.pickedCamera = $0 },onRoute:navigation.select)
                .equatable().ignoresSafeArea()
            } else { Color(uiColor:.systemBackground).ignoresSafeArea() }
            if model.searchFocused { Color(uiColor:.systemBackground).ignoresSafeArea() }
            VStack(spacing:10) {
                if navigation.isDriving || navigation.phase == .arrived { ManeuverCard(navigation:navigation,onStop:model.stopNavigation) }
                else { SearchCard(search:model.search,onFocus:model.setSearchFocused,focused:model.searchFocused,onPickMap:{ model.search.dismiss(); model.pickingDestination = true }) }
                if model.pickingDestination {
                    HStack {
                        Label("Tap a destination on the map",systemImage:"mappin.and.ellipse").font(.subheadline.weight(.medium))
                        Spacer(); Button("Cancel") { model.pickingDestination = false }
                    }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                }
                if let alert = model.latestAlert { AlertBanner(alert:alert,close:model.clearAlert) }
                if model.dataState == .loading {
                    ProgressView("Loading offline camera data…").font(.caption)
                        .padding(10).background(.regularMaterial,in:Capsule()).accessibilityIdentifier("data.loading")
                }
                if let error = model.dataError {
                    HStack {
                        Text(error).font(.footnote)
                        Spacer(minLength:8)
                        Button("Retry",action:model.reloadData).accessibilityIdentifier("data.retry")
                    }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                }
                if !model.searchFocused {
                    GPSStatusCard(location:location,stale:model.gpsStale && (model.monitoring || navigation.isDriving),permissionNeeded:model.currentFix == nil,onRetry:model.retryGPS)
                    if model.monitoring && model.preferences.notifications && location.hasPermission {
                        NotificationPermissionCard(notifications:model.notifications)
                    }
                }
                if !model.searchFocused { HStack(alignment:.top) {
                    if model.monitoring {
                        Label("Monitoring",systemImage:"shield.checkered").font(.caption.weight(.semibold))
                            .padding(.horizontal,12).padding(.vertical,8).background(.regularMaterial,in:Capsule())
                    }
                    Spacer()
                    if verticalSizeClass == .compact { HStack(spacing:8) { mapButtons } }
                    else { VStack(spacing:10) { mapButtons } }
                } }
                Spacer(minLength:0)
                if model.showingRoad { RoadCard(model:model,location:location) }
                if [.waitingForLocation,.loading,.preview,.failed].contains(navigation.phase) {
                    RoutePicker(navigation:navigation,waitingForGPS:model.startingNavigation,onStart:model.startNavigation,onCancel:model.stopNavigation,onRetry:model.retryRoute)
                } else if let zone = model.sectionZone {
                    HStack {
                        Image(systemName:CameraCategory.sectionSpeed.symbol)
                        VStack(alignment:.leading,spacing:2) {
                            Text("Section speed · \(zone.speedLimit.map(String.init) ?? "Unknown") km/h").font(.subheadline.weight(.semibold))
                            Text("\(distanceText(model.sectionRemaining ?? 0)) to end · \(zone.ref)").font(.caption)
                        }; Spacer()
                    }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
                } else if !navigation.isDriving && navigation.phase != .arrived && !model.showingRoad {
                    if !model.searchFocused {
                    Button { showingMapKey = true } label: {
                        Label("Map key",systemImage:"map").font(.caption.weight(.semibold))
                            .padding(.horizontal,12).padding(.vertical,9)
                            .background(Color(uiColor:.secondarySystemBackground),in:Capsule())
                    }
                        .accessibilityIdentifier("map.layerLegend")
                        .accessibilityValue(model.layerCounts.accessibilitySummary)
                    }
                }
            }
            .padding(.horizontal,16).padding(.top,8).padding(.bottom,8)
            .frame(maxWidth:640)
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        }
        .ignoresSafeArea(.keyboard,edges:.bottom)
        .overlay(alignment:.bottomTrailing) {
            if !model.searchFocused && model.layerCounts.hasOSMShapes {
                Link("© OpenStreetMap",destination:URL(string:"https://www.openstreetmap.org/copyright")!)
                    .font(.caption2).padding(4).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:4)).padding(.trailing,8)
            }
        }
        .tint(.teal)
        .sheet(isPresented:$model.showingSettings) { SettingsScreen(model:model) }
        .sheet(isPresented:$showingMapKey) { MapKeyScreen(counts:model.layerCounts,loadReferences:model.speedReferences) }
        .sheet(item:$model.pickedCamera) { CameraDetails(camera:$0) }
        .task { await model.start() }
        .onChange(of:navigation.phase) { _,_ in model.updateMonitoring() }
        .onChange(of:scenePhase) { _,phase in
            model.setMapActive(phase != .background)
            location.setForeground(phase != .background)
            if phase == .active { model.updateMonitoring(); Task { await model.notifications.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseMemory() }
        }
    }
    @ViewBuilder private var mapButtons: some View {
        MapButton(symbol:"location.north.line.fill",label:"Follow my location",action:model.recenter)
        MapButton(symbol:"mappin.and.ellipse",label:"Pick destination on map") {
            model.search.dismiss(); model.pickingDestination.toggle()
        }.accessibilityIdentifier("map.pick")
        MapButton(symbol:model.monitoring ? "shield.lefthalf.filled" : "shield",label:model.monitoring ? "Stop camera monitoring" : "Start camera monitoring",action:model.toggleMonitoring)
        MapButton(symbol:"speedometer",label:"Show current road details") { model.showingRoad.toggle() }
        MapButton(symbol:"slider.horizontal.3",label:"Layers and settings") { model.showingSettings = true }
            .accessibilityIdentifier("map.settings")
    }
}

struct MapButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:19,weight:.medium)).frame(width:46,height:46)
                .foregroundStyle(.teal).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:15))
                .overlay(RoundedRectangle(cornerRadius:15).strokeBorder(Color(uiColor:.separator).opacity(0.3),lineWidth:0.5))
        }.accessibilityLabel(label)
    }
}

struct SearchCard: View {
    @ObservedObject var search: SearchService
    var onFocus: (Bool) -> Void = { _ in }
    var focused = false
    var onPickMap: () -> Void = {}
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                NativeSearchField(search:search,onFocus:onFocus).frame(height:30)
                if search.isSearching { ProgressView().controlSize(.small) }
            }.padding(15)
            // Keep actions above suggestions so late autocomplete results cannot move a tap target.
            if focused {
                HStack {
                    Button("Choose on Map",action:onPickMap).accessibilityIdentifier("search.pickMap")
                    Spacer()
                    Button("Cancel",action:search.dismiss).accessibilityIdentifier("search.cancel")
                }.font(.subheadline.weight(.medium)).padding(.horizontal,15).padding(.bottom,12)
            }
            if !search.results.isEmpty || !search.suggestions.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing:0) {
                        ForEach(search.results) { result in
                            PlaceRow(title:result.title,subtitle:result.subtitle) { search.choose(result) }
                        }
                        ForEach(search.suggestions) { suggestion in
                            PlaceRow(title:suggestion.title,subtitle:suggestion.subtitle) { search.dismissKeyboard(); search.choose(suggestion) }
                        }
                    }
                }.frame(maxHeight:280)
            }
            if let error = search.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(12) }
        }
        .background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:16))
        .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(Color(uiColor:.separator).opacity(0.4),lineWidth:0.5))
        .onDisappear { search.setFocused(false); onFocus(false) }
    }
}

private struct PlaceRow: View {
    let title: String; let subtitle: String; let action: () -> Void
    var body: some View {
        Button(action:action) {
            HStack(spacing:12) {
                Image(systemName:"mappin.circle.fill").font(.title2).foregroundStyle(.teal)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }; Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal,14).padding(.vertical,12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct RoutePicker: View {
    @ObservedObject var navigation: NavigationService
    let waitingForGPS: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }
    var body: some View {
        VStack(alignment:.leading,spacing:compact ? 8 : 12) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:2) {
                    Text(navigation.destination?.name ?? "Destination").font(.headline).lineLimit(compact ? 1 : 2)
                    if !compact { Text("Driving · in-app guidance").font(.caption).foregroundStyle(.secondary) }
                }; Spacer()
                Button(action:onCancel) { Image(systemName:"xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                    .accessibilityLabel("Cancel route").accessibilityIdentifier("route.cancel")
            }
            if navigation.phase == .waitingForLocation {
                HStack {
                    ProgressView()
                    Text("Getting current location...").font(.subheadline).accessibilityIdentifier("route.waitingGPS")
                }.padding(.vertical,8)
                Text("Your destination is saved. You can still move the map or cancel.").font(.caption).foregroundStyle(.secondary)
            } else if navigation.phase == .loading {
                HStack { ProgressView(); Text("Finding driving routes…").font(.subheadline) }.padding(.vertical,8)
            } else if navigation.phase == .failed {
                Text(navigation.error ?? "Route unavailable").font(.subheadline).foregroundStyle(.secondary)
                Button("Retry from my location",action:onRetry).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("route.retry")
            } else {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        ForEach(navigation.routes) { option in
                            Button { navigation.select(option.id) } label: {
                                VStack(alignment:.leading,spacing:4) {
                                    Text("\(NavigationService.minutes(option.estimate)) min").font(.title3.weight(.bold)).monospacedDigit()
                                    Text(distanceText(option.distance)).font(.caption)
                                    if !compact { Text(option.name).font(.caption2).lineLimit(1) }
                                    Text("Route estimate").font(.caption2).foregroundStyle(.secondary)
                                }.frame(width:compact ? 110 : 130,alignment:.leading).padding(compact ? 8 : 12)
                                    .foregroundStyle(.primary).background(navigation.selectedID == option.id ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
                                    .overlay(RoundedRectangle(cornerRadius:14).stroke(navigation.selectedID == option.id ? Color.teal : .clear,lineWidth:2))
                            }.buttonStyle(.plain).accessibilityLabel("Route \(option.name), \(NavigationService.minutes(option.estimate)) minutes")
                        }
                    }
                }
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text(navigation.trafficLabel).font(.caption.weight(.medium))
                        if !compact {
                            Text("Traffic ETA is for Apple’s recommended trip, not every alternative.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }; Spacer()
                    Button(action:onStart) {
                        if waitingForGPS { ProgressView().padding(.vertical,5) }
                        else { Label("Start",systemImage:"location.fill").font(.headline).padding(.vertical,5) }
                    }
                        .buttonStyle(.borderedProminent).disabled(navigation.selected == nil || waitingForGPS)
                        .accessibilityIdentifier("route.start")
                }
                if let error = navigation.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.padding(compact ? 12 : 16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:24))
            .shadow(color:.black.opacity(0.12),radius:15,y:5)
    }
}

private struct GPSStatusCard: View {
    @ObservedObject var location: LocationService
    let stale: Bool
    let permissionNeeded: Bool
    let onRetry: () -> Void
    var body: some View {
        if location.authorization == .denied || location.authorization == .restricted {
            HStack {
                Text("Location is off. Map browsing and search still work.").font(.caption)
                Spacer(); Button("Settings",action:openSettings)
            }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).accessibilityIdentifier("gps.permissionDenied")
        } else if location.authorization == .notDetermined && permissionNeeded {
            HStack {
                Text("Enable location for your blue dot and camera alerts.").font(.caption)
                Spacer(); Button("Enable") { location.requestFreshLocation() }
            }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).accessibilityIdentifier("gps.enable")
        } else if location.isAcquiring {
            HStack(spacing:8) { ProgressView().controlSize(.small); Text("Acquiring GPS...").font(.caption) }
                .padding(10).background(.regularMaterial,in:Capsule())
        } else if let error = location.acquisitionError {
            HStack { Text(error).font(.caption); Spacer(); Button("Retry",action:onRetry) }
                .padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                .accessibilityIdentifier("gps.retry")
        } else if location.accuracyAuthorization == .reducedAccuracy {
            HStack {
                Text("Precise Location is needed for road-level alerts.").font(.caption)
                Spacer(); Button("Enable Precise") { location.requestPreciseLocation() }
            }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
        } else if stale {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("Location updates delayed · reconnecting").font(.caption.weight(.semibold))
                        .accessibilityIdentifier("gps.delayed")
                    Text("Guidance and camera alerts paused until a fresh fix arrives.").font(.caption2)
                }
                Spacer(); Button("Retry",action:onRetry)
            }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
        } else if location.signal == .weak {
            Text("GPS accuracy is low · camera alerts paused. Move to an open area.")
                .font(.caption).padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
        }
    }
    private func openSettings() {
        if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

private struct NotificationPermissionCard: View {
    @ObservedObject var notifications: NotificationService
    var body: some View {
        if !notifications.authorized {
            HStack {
                Text("Camera notifications are off").font(.caption); Spacer()
                Button(notifications.permission == .denied ? "Settings" : "Enable") {
                    if notifications.permission == .denied {
                        if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } else { Task { await notifications.request() } }
                }.disabled(notifications.isRequesting)
            }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
        }
    }
}

struct ManeuverCard: View {
    @ObservedObject var navigation: NavigationService
    let onStop: () -> Void
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:turnSymbol)
                .font(.title2).padding(8).foregroundStyle(.teal)
            VStack(alignment:.leading,spacing:5) {
                Text(navigation.phase == .arrived ? "Arrived" : (navigation.guidancePaused ? "Waiting for location" : distanceText(navigation.maneuverDistance))).font(.title2.weight(.bold)).monospacedDigit()
                    .accessibilityIdentifier("navigation.maneuver")
                Text(navigation.guidancePaused ? "Route saved. Guidance resumes with a fresh location." : navigation.instruction).font(.subheadline.weight(.medium)).lineLimit(3)
                if navigation.rerouting { Text("Rerouting…").font(.caption).foregroundStyle(.secondary) }
                else if navigation.isDriving && !navigation.guidancePaused { Text("\(distanceText(navigation.remainingDistance)) remaining · \(navigation.trafficLabel)").font(.caption).foregroundStyle(.secondary) }
                if let error = navigation.error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }; Spacer()
            Button("End",action:onStop).font(.subheadline.weight(.semibold)).accessibilityIdentifier("navigation.end")
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:22))
    }
    private var turnSymbol: String {
        if navigation.phase == .arrived { return "flag.checkered" }
        if navigation.guidancePaused { return "location.slash" }
        let text = navigation.instruction.lowercased()
        if text.contains("迴轉") || text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("圓環") || text.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        if text.contains("左") || text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("右") || text.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
}

struct RoadCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var location: LocationService
    @State private var showingReferences = false
    var body: some View {
        HStack(spacing:14) {
            Text(model.roadContext?.segment.speedLimit.map(String.init) ?? "—")
                .font(.system(size:28,weight:.bold,design:.rounded)).monospacedDigit().frame(width:58,height:58)
                .background(.white,in:Circle()).overlay(Circle().stroke(.red,lineWidth:4)).foregroundStyle(.black)
            VStack(alignment:.leading,spacing:4) {
                Text(model.roadContext?.segment.name ?? "Road not confidently matched").font(.subheadline.weight(.semibold))
                Text(model.roadContext?.segment.speedLimit == nil ? "Speed limit unknown · obey signs" : "Official road speed · km/h").font(.caption)
                Text(model.roadContext?.confidence ?? "Need fresh GPS and travel direction").font(.caption2).foregroundStyle(.secondary)
                if let source = model.summary.sources.first(where:{ $0.id == model.roadContext?.segment.sourceID }), !source.updated.isEmpty {
                    Text("Source metadata: \(String(source.updated.prefix(10)))").font(.caption2).foregroundStyle(.secondary)
                }
                if let fix = location.fix {
                    Text("GPS ±\(numericText(fix.accuracy)) m · altitude \(numericText(fix.altitude)) m (not road level)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Browse published limits") { showingReferences = true }.font(.caption.weight(.semibold))
                    .accessibilityIdentifier("road.speedReferences")
            }; Spacer()
            Button { model.showingRoad = false } label: { Image(systemName:"xmark") }.accessibilityLabel("Hide road details")
        }.padding(14).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:20))
            .accessibilityIdentifier("road.details")
            .sheet(isPresented:$showingReferences) {
                NavigationStack {
                    SpeedReferenceScreen(query:model.roadContext?.segment.ref ?? "",close:{ showingReferences = false },load:model.speedReferences)
                }.tint(.teal)
            }
    }
}

struct AlertBanner: View {
    let alert: NearbyAlert; let close: () -> Void
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:alert.camera.category.symbol).font(.title2).foregroundStyle(.orange)
            VStack(alignment:.leading,spacing:3) {
                Text(alert.title + " · " + distanceText(alert.distance)).font(.subheadline.weight(.bold))
                Text(alert.camera.roadName).font(.caption).lineLimit(2)
                Text(alert.camera.speedLimit.map { "\($0) km/h · \(alert.camera.direction)" } ?? alert.camera.direction).font(.caption)
            }; Spacer(); Button(action:close) { Image(systemName:"xmark") }.accessibilityLabel("Dismiss camera alert")
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }
}

func distanceText(_ distance: Double) -> String {
    guard distance.isFinite, abs(distance) <= 1_000_000_000 else { return "Unknown" }
    return distance >= 1000 ? String(format:"%.1f km",distance/1000) : "\(Int(max(0,distance).rounded())) m"
}

private func numericText(_ value: Double) -> String {
    guard value.isFinite, abs(value) <= 1_000_000_000 else { return "Unknown" }
    return String(Int(value.rounded()))
}
