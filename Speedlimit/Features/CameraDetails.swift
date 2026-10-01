import SwiftUI
import UIKit

struct CameraDetails: View {
    let camera: CameraPoint
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack(spacing:14) {
                        Image(systemName:camera.category.symbol).font(.largeTitle).foregroundStyle(.blue)
                        VStack(alignment:.leading,spacing:4) {
                            Text(camera.category.title).font(.title2.bold())
                            Text(camera.confidenceTitle).font(.caption.weight(.medium))
                                .foregroundStyle(camera.confidence == "A" || camera.category == .cctv ? .blue : .orange)
                        }
                    }
                    Text(camera.roadName).font(.headline)
                    if camera.category == .cctv {
                        if let url = camera.cctvURL ?? camera.cctvStreamURL { CCTVImage(url:url,streamURL:camera.cctvStreamURL) }
                        else { Label("No public image endpoint supplied",systemImage:"video.slash").font(.subheadline) }
                    } else {
                        if !camera.enforcementType.isEmpty { LabeledContent("Enforcement",value:camera.enforcementType) }
                        LabeledContent("Published limit",value:camera.speedLimit.map { "\($0) km/h" } ?? "Not supplied / vehicle-dependent")
                    }
                    if camera.category == .sectionSpeed {
                        Text(camera.sectionCoverageTitle).font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                            .accessibilityIdentifier("section.coverage")
                    }
                    if !camera.direction.isEmpty { LabeledContent("Direction",value:camera.direction) }
                    Text(camera.qualityNote).font(.footnote).foregroundStyle(.secondary)
                    Divider()
                    Text("Source: \(camera.sourceAuthority) · \(camera.sourceID)").font(.caption)
                    Text("Metadata updated: \(camera.sourceUpdated)").font(.caption).foregroundStyle(.secondary)
                    Text(String(format:"Official coordinates: %.6f, %.6f",camera.coordinate.latitude,camera.coordinate.longitude)).font(.caption).monospaced()
                    if let source = URL(string:"https://data.gov.tw/dataset/\(camera.sourceID)"), Int(camera.sourceID) != nil {
                        Link("View official dataset",destination:source)
                    }
                    Text("Posted signs take precedence. Missing data does not mean no camera.").font(.footnote).foregroundStyle(.secondary)
                }.padding(22)
            }.navigationTitle("Camera Details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Close") { dismiss() } } }
        }.presentationDetents(camera.category == .cctv ? [.large] : [.medium,.large]).tint(.blue)
    }
}

@MainActor
final class CCTVImageModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var downloadedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var cooldown = 0
    @Published private(set) var playing = false
    @Published private(set) var isLive = false
    @Published private(set) var autoRefreshing = false
    @Published private(set) var receivedFrames = 0
    private let service: CCTVService
    private var task: Task<Void,Never>?
    private var clock: Task<Void,Never>?
    private var generation = 0
    private var url: String?
    private var streamURL: String?
    private var lastRequestURL: String?
    init(service: CCTVService = .shared) { self.service = service }
    func stop(releaseImage: Bool = true) {
        generation += 1; task?.cancel(); task = nil; clock?.cancel(); clock = nil; loading = false
        playing = false; isLive = false; autoRefreshing = false
        if releaseImage { image = nil; downloadedAt = nil }
    }
    func load(url: String) {
        guard !loading else { return }
        stop(releaseImage:false)
        if self.url != url { image = nil; downloadedAt = nil; cooldown = 0 }
        self.url = url; lastRequestURL = url; loading = true; error = nil
        let token = generation, service = service
        task = Task { [weak self] in
            do {
                let snapshot = try await service.snapshot(urlString:url)
                let decoded = try await Task.detached(priority:.userInitiated) { try SnapshotDecoder.decode(snapshot,url:url) }.value
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.image = decoded; self.downloadedAt = snapshot.downloadedAt
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.error = error.localizedDescription
            }
            let next = await service.nextRequestDate(urlString:url)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.loading = false; self.task = nil; self.startCooldown(next,token:token)
        }
    }
    func pause() {
        stop(releaseImage:false)
        guard let lastRequestURL else { return }
        let token = generation, service = service
        task = Task { [weak self] in
            let next = await service.nextRequestDate(urlString:lastRequestURL)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.task = nil; self.startCooldown(next,token:token)
        }
    }
    func play(url: String, streamURL: String?) {
        if playing, self.url == url, self.streamURL == streamURL { return }
        stop(releaseImage:false)
        if self.url != url { image = nil; downloadedAt = nil; receivedFrames = 0; cooldown = 0 }
        self.url = url; self.streamURL = streamURL; playing = true; loading = true; error = nil
        let token = generation, service = service
        task = Task { [weak self] in
            var next: Date?
            if let streamURL {
                do {
                    next = await service.nextRequestDate(urlString:streamURL)
                    if let snapshotNext = await service.nextRequestDate(urlString:url), snapshotNext > (next ?? .distantPast) { next = snapshotNext }
                    if let next, next.timeIntervalSinceNow > 0 {
                        self?.loading = false; self?.startCooldown(next,token:token)
                        try await Task.sleep(for:.seconds(max(0,next.timeIntervalSinceNow)))
                    }
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
                    self?.loading = true; self?.lastRequestURL = streamURL
                    let feed = try await service.live(urlString:streamURL,snapshotURLString:url)
                    defer { feed.cancel() }
                    var continuous = false
                    for try await frame in feed.frames {
                        let decoded = try await Self.decode(frame.snapshot.data)
                        guard !Task.isCancelled, self?.generation == token else { return }
                        self?.image = decoded; self?.downloadedAt = frame.snapshot.downloadedAt
                        self?.receivedFrames += 1; self?.loading = false; self?.isLive = frame.isContinuous
                        self?.error = nil; continuous = frame.isContinuous
                    }
                    if continuous { self?.error = "The live connection ended. Switching to minute-by-minute snapshots." }
                } catch {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    if error is CancellationError { self?.stop(); return }
                    self?.error = "Live video unavailable: \(error.localizedDescription) Trying published snapshots instead."
                }
                next = await service.nextRequestDate(urlString:streamURL)
            }
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.isLive = false; self?.autoRefreshing = true
            // Still-image sources remain honest snapshots, never fast polling disguised as video.
            while !Task.isCancelled {
                do {
                    if let next, next.timeIntervalSinceNow > 0 {
                        self?.loading = false; self?.startCooldown(next,token:token)
                        try await Task.sleep(for:.seconds(max(0,next.timeIntervalSinceNow)))
                    }
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
                    self?.loading = true; self?.lastRequestURL = url
                    let snapshot = try await service.snapshot(urlString:url,streamURLString:streamURL)
                    let decoded = try await Self.decode(snapshot.data)
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.image = decoded; self?.downloadedAt = snapshot.downloadedAt
                    self?.receivedFrames += 1; self?.error = nil
                } catch {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.error = error.localizedDescription
                }
                next = await service.nextRequestDate(urlString:url) ?? Date().addingTimeInterval(60)
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.loading = false
            }
        }
    }
    private nonisolated static func decode(_ data: Data) async throws -> UIImage {
        let task = Task.detached(priority:.userInitiated) { try SnapshotDecoder.decode(data) }
        return try await withTaskCancellationHandler {
            let image = try await task.value; try Task.checkCancellation(); return image
        } onCancel: { task.cancel() }
    }
    private func startCooldown(_ next: Date?, token: Int) {
        clock?.cancel()
        cooldown = next.map { Int(ceil(max(0,$0.timeIntervalSinceNow))) } ?? 0
        guard cooldown > 0, let next else { clock = nil; return }
        // Stop the clock when ready or dismissed; an idle camera sheet has no perpetual timer.
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self, self.generation == token else { return }
                self.cooldown = Int(ceil(max(0,next.timeIntervalSinceNow)))
                if self.cooldown == 0 { self.clock = nil; return }
            }
        }
    }
    deinit { task?.cancel(); clock?.cancel() }
}

struct CCTVImage: View {
    let url: String
    var streamURL: String? = nil
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CCTVImageModel()
    @State private var requestedPlayback = true
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ZStack {
                RoundedRectangle(cornerRadius:14).fill(.secondary.opacity(0.1))
                if let image = model.image {
                    Image(uiImage:image).resizable().scaledToFit().accessibilityLabel(model.isLive ? "Public CCTV live video":"Public CCTV snapshot")
                        .accessibilityIdentifier("cctv.image")
                } else {
                    Image(systemName:"video.slash").font(.largeTitle).foregroundStyle(.secondary)
                }
            }.aspectRatio(16/9,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:14))
            HStack(spacing:7) {
                Circle().fill(model.isLive ? Color.green:Color.secondary).frame(width:7,height:7)
                Text(model.isLive ? "LIVE" : model.autoRefreshing ? "AUTO-REFRESH SNAPSHOTS" : model.playing ? "CONNECTING" : "PAUSED")
                    .font(.caption.weight(.semibold)).accessibilityIdentifier("cctv.status")
                    .accessibilityValue("\(model.receivedFrames) frames received")
                Spacer()
                Button(model.playing ? "Pause" : model.cooldown > 0 ? "Resume in \(model.cooldown)s" : streamURL == nil ? "Resume snapshots":"Play live") {
                    if model.playing { requestedPlayback = false; model.pause() }
                    else { requestedPlayback = true; model.play(url:url,streamURL:streamURL) }
                }.disabled(!model.playing && model.cooldown > 0).accessibilityIdentifier("cctv.playback")
            }
            if model.loading { ProgressView(streamURL == nil ? "Loading public camera image...":"Connecting to public camera...").accessibilityIdentifier("cctv.loading") }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("cctv.error") }
            if let downloadedAt = model.downloadedAt {
                Text("\(model.isLive ? "Frame":"Snapshot") received \(downloadedAt.formatted(date:.omitted,time:.standard)) · source may be delayed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.isLive, model.playing, model.cooldown > 0 {
                Text("\(model.autoRefreshing ? "Next snapshot":"Reconnect") in \(model.cooldown)s").font(.caption).foregroundStyle(.secondary)
            }
            Text("Public traffic observation · no API key · not an enforcement camera. Video uses one continuous connection while open; still images and reconnects are at least one minute apart. Playback stops in the background. View only while safely stopped.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { if requestedPlayback { model.play(url:url,streamURL:streamURL) } }.onDisappear { model.stop() }
            .onChange(of:url) { _,_ in model.stop(); if requestedPlayback { model.play(url:url,streamURL:streamURL) } }
            .onChange(of:streamURL) { _,_ in model.stop(); if requestedPlayback { model.play(url:url,streamURL:streamURL) } }
            .onChange(of:scenePhase) { _,phase in
                if phase == .background { model.stop() }
                else if phase == .active, requestedPlayback { model.play(url:url,streamURL:streamURL) }
            }
    }
}
