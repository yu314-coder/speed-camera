import SwiftUI

struct SpeedReferenceScreen: View {
    let load: () async throws -> [SpeedLimitReference]
    let close: (() -> Void)?
    @State private var query: String
    @State private var scope = SpeedReferenceScope.all
    @State private var entries: [SpeedLimitReference] = []
    @State private var loading = true
    @State private var error: String?
    @State private var loadGeneration = 0
    @State private var searching = false
    init(query: String = "", close: (() -> Void)? = nil, load: @escaping () async throws -> [SpeedLimitReference]) {
        _query = State(initialValue:query); self.close = close; self.load = load
    }
    private var filtered: [SpeedLimitReference] {
        let tokens = SpeedLimitReference.tokens(query)
        return entries.filter { $0.matches(tokens:tokens,scope:scope) }
    }
    var body: some View {
        List {
            Section {
                Label("Published rules · not a live GPS reading",systemImage:"doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                Text("Search a road or kilometre range. Direction, curves, side roads and vehicle exceptions matter. These tables do not establish your current road; posted signs take priority.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Area",selection:$scope) {
                    ForEach(SpeedReferenceScope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("speed.scope")
            }
            Section("\(filtered.count) published entries") {
                ForEach(filtered) { entry in
                    NavigationLink(value:entry) {
                        VStack(alignment:.leading,spacing:8) {
                            HStack(alignment:.top,spacing:12) {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(entry.roadName).font(.headline)
                                    Text(entry.segment).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength:4)
                                if let limit = entry.numericLimit {
                                    VStack(spacing:1) {
                                        Text(String(limit)).font(.title2.weight(.bold)).monospacedDigit()
                                        Text("km/h").font(.caption2)
                                    }.foregroundStyle(.primary).padding(8)
                                        .background(Color.teal.opacity(0.1),in:RoundedRectangle(cornerRadius:12))
                                }
                            }
                            if entry.numericLimit == nil {
                                Text(entry.limitText).font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                            }
                            Label(entry.conditions.isEmpty ? "View source & dates" : "Conditions apply · view details",systemImage:"info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical,6)
                    }.accessibilityIdentifier("speed.reference.\(entry.id)")
                }
            }
            if loading { ProgressView("Loading offline references…") }
            else if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { loading = true; self.error = nil; loadGeneration += 1 }
            }
            else if filtered.isEmpty {
                ContentUnavailableView("No published rule found",systemImage:"magnifyingglass",description:Text("This is partial coverage. Do not assume a default speed limit."))
            }
        }.listStyle(.insetGrouped)
            .navigationTitle("Speed Limits").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for:SpeedLimitReference.self) { SpeedReferenceDetail(entry:$0,close:close) }
            .toolbar { if let close { ToolbarItem(placement:.topBarTrailing) { Button("Done",action:close).accessibilityIdentifier("speed.close") } } }
            .searchable(text:$query,isPresented:$searching,placement:.navigationBarDrawer(displayMode:.always),prompt:"Road, direction or km (e.g. 台64)")
            .onSubmit(of:.search) { searching = false }
            .accessibilityIdentifier("speed.references")
            .task(id:loadGeneration) {
                guard loading else { return }
                do {
                    let entries = try await load()
                    guard !Task.isCancelled else { return }
                    self.entries = entries
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                loading = false
            }
    }
}

private struct SpeedReferenceDetail: View {
    let entry: SpeedLimitReference
    let close: (() -> Void)?
    var body: some View {
        List {
            Section("Published speed rule") {
                Text(entry.roadName).font(.headline)
                Text(entry.segment)
                Text(entry.limitText + (entry.numericLimit == nil ? "" : " km/h"))
                    .font(.title2.weight(.semibold)).foregroundStyle(.teal)
                if !entry.conditions.isEmpty { Text(entry.conditions).font(.subheadline) }
            }
            Section("Source & freshness") {
                Text(entry.authority)
                LabeledContent("Dataset",value:entry.sourceID).font(.caption)
                LabeledContent("Metadata updated",value:entry.sourceUpdated.isEmpty ? "Not supplied" : String(entry.sourceUpdated.prefix(10)))
                LabeledContent("Source checked (UTC)",value:String(entry.checkedAt.prefix(10)))
                if let url = URL(string:entry.sourceURL) { Link("Open official source",destination:url) }
                if entry.publicationStatus == "reviewed_web_snapshot_not_machine_feed" {
                    Text("Reviewed partial website snapshot. Some table pages could not be fetched; this is not a complete expressway inventory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Reference only. No surveyed boundaries are available for this entry, so it does not set a GPS speed limit or trigger camera alerts. A recent download does not mean the underlying rule was recently updated.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(entry.roadRef.isEmpty ? "Speed Rule" : entry.roadRef).navigationBarTitleDisplayMode(.inline)
            .toolbar { if let close { ToolbarItem(placement:.topBarTrailing) { Button("Done",action:close).accessibilityIdentifier("speed.close") } } }
    }
}

struct MapKeyScreen: View {
    private enum Destination: Hashable { case references }
    let counts: MapLayerCounts
    let loadReferences: () async throws -> [SpeedLimitReference]
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path:$path) {
            List {
                Section("Camera markers") {
                    ForEach(CameraCategory.allCases.filter { $0 != .sectionSpeed }) { category in
                        HStack(spacing:14) {
                            Image(systemName:category.symbol).foregroundStyle(.white).frame(width:34,height:34)
                                .background(Color(TaiwanMapView.Coordinator.color(category)),in:RoundedRectangle(cornerRadius:10))
                            VStack(alignment:.leading,spacing:3) {
                                Text(category.title).font(.subheadline.weight(.semibold))
                                Text(category == .cctv ? "Traffic observation, not enforcement" : "Tap for direction, limit and source")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Label("A number is a group of cameras. Single-type groups keep their category icon. Orange shield groups contain mixed enforcement types. Tap to zoom in.",systemImage:"square.stack.3d.up")
                        .font(.footnote)
                }
                Section("Section-speed coverage") {
                    Label("Blue dashes · verified corridor",systemImage:CameraCategory.sectionSpeed.symbol).foregroundStyle(.blue)
                    Label("Pale blue dashes · estimated display span",systemImage:"line.diagonal").foregroundStyle(.secondary)
                    Label("Gray section pin · endpoint only, no verified full span",systemImage:CameraCategory.sectionSpeed.symbol).foregroundStyle(.secondary)
                    Text("Estimated spans and unresolved endpoints never trigger alerts. We do not draw invented exits to fill gaps.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(counts.accessibilitySummary).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink(value:Destination.references) {
                        Label("Browse published speed limits",systemImage:"speedometer")
                    }.accessibilityIdentifier("map.speedReferences")
                }
            }.navigationTitle("Map Key").navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for:Destination.self) { _ in SpeedReferenceScreen(close:{ dismiss() },load:loadReferences) }
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(.teal)
    }
}
