import Foundation
import MapKit
import Combine

struct SearchSuggestion: Identifiable {
    let id: String
    let completion: MKLocalSearchCompletion
    var title: String { completion.title }
    var subtitle: String { completion.subtitle }
}

struct PlaceResult: Identifiable {
    let id: String
    let item: MKMapItem
    var title: String { item.name ?? "Map location" }
    var subtitle: String { item.placemark.title ?? "" }
}

@MainActor
final class SearchService: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    typealias SearchProvider = (MKLocalSearch.Request) async throws -> [MKMapItem]
    private let provider: SearchProvider?
    private let timeout: Duration
    private let deadline = LoadingDeadline()
    // Native text entry owns its buffer; keystrokes must not invalidate SwiftUI/the map.
    var query = ""
    @Published private(set) var suggestions: [SearchSuggestion] = []
    @Published private(set) var results: [PlaceResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var focusRelease = 0
    @Published private(set) var inputRevision = 0
    private var completer: MKLocalSearchCompleter?
    private var region = MKCoordinateRegion(center:.init(latitude:25.04,longitude:121.51),latitudinalMeters:60_000,longitudinalMeters:60_000)
    private var focused = false
    private var completionRegion: MKCoordinateRegion?
    private var debounce: Task<Void,Never>?
    private var selection: Task<Void,Never>?
    private var request: MKLocalSearch?
    private var generation = 0
    private var dismissed = false
    var onPick: ((MKMapItem) -> Void)?
    var onDismissKeyboard: (() -> Void)?
    init(provider: SearchProvider? = nil, timeout: Duration = .seconds(12)) {
        self.provider = provider; self.timeout = timeout
        super.init()
    }
    func updateRegion(_ region: MKCoordinateRegion) {
        self.region = region
    }
    func setFocused(_ focused: Bool) {
        if focused && !self.focused { completionRegion = nil }
        self.focused = focused
    }
    func edit(_ text: String) {
        guard text != query else { return }
        query = text; textChanged()
    }
    private func autocomplete(_ text: String) {
        if completer == nil {
            let completer = MKLocalSearchCompleter()
            completer.delegate = self; completer.resultTypes = [.address,.pointOfInterest]
            self.completer = completer
        }
        if completionRegion == nil || (!focused && regionDiffers(from:completionRegion!)) {
            completer?.region = region; completionRegion = region
        }
        completer?.queryFragment = text
    }
    private func regionDiffers(from previous: MKCoordinateRegion) -> Bool {
        Geo.distance(Coordinate(previous.center),Coordinate(region.center)) > 500 ||
        abs(region.span.latitudeDelta-previous.span.latitudeDelta) > previous.span.latitudeDelta*0.3
    }
    func textChanged() {
        cancel(stopCompletions:false)
        dismissed = false
        if !suggestions.isEmpty { suggestions = [] }; if !results.isEmpty { results = [] }; if error != nil { error = nil }
        let text = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { completer?.cancel(); return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            self.autocomplete(text)
        }
    }
    private func cancel(stopCompletions: Bool = true) {
        generation += 1; deadline.cancel(); debounce?.cancel(); selection?.cancel(); request?.cancel()
        if stopCompletions { completer?.cancel() }
        debounce = nil; selection = nil; request = nil
        if isSearching { isSearching = false }
    }
    func dismiss() { cancel(); dismissed = true; suggestions = []; results = []; error = nil; dismissKeyboard() }
    func dismissKeyboard() { onDismissKeyboard?(); focusRelease += 1 }
    func clear() {
        cancel(); dismissed = true
        query = ""; suggestions = []; results = []; error = nil; isSearching = false; inputRevision += 1
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard !dismissed, !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              completer.queryFragment == query.trimmingCharacters(in:.whitespacesAndNewlines) else { return }
        error = nil
        var seen = Set<String>()
        var next: [SearchSuggestion] = []
        for result in completer.results {
            let id = result.title + "|" + result.subtitle
            if seen.insert(id).inserted { next.append(.init(id:id,completion:result)) }
            if next.count == 6 { break }
        }
        if next.map(\.id) != suggestions.map(\.id) { suggestions = next }
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard !dismissed, !query.isEmpty, completer.queryFragment == query.trimmingCharacters(in:.whitespacesAndNewlines),
              (error as? URLError)?.code != .cancelled else { return }
        self.error = "Search needs an Internet connection. You can also hold the map to pick a destination."
    }
    func choose(_ suggestion: SearchSuggestion) {
        guard suggestions.contains(where:{ $0.id == suggestion.id }) else { return }
        run(MKLocalSearch.Request(completion:suggestion.completion),pickSingle:true)
    }
    func submit() {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query; request.region = region
        request.resultTypes = [.address,.pointOfInterest]
        run(request,pickSingle:false)
    }
    private func run(_ searchRequest: MKLocalSearch.Request, pickSingle: Bool) {
        cancel(); let token = generation
        dismissed = true; suggestions = []; results = []; error = nil; isSearching = true
        let provider = provider
        let search = provider == nil ? MKLocalSearch(request:searchRequest) : nil; request = search
        let deadlineToken = deadline.begin(after:timeout) { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancel()
            self.error = "Search timed out. Retry or hold the map to pick a destination."
        }
        selection = Task { [weak self] in
            do {
                let items: [MKMapItem]
                if let provider { items = try await provider(searchRequest) }
                else if let search { items = try await search.start().mapItems }
                else { items = [] }
                guard let self, !Task.isCancelled, self.generation == token, self.deadline.accepts(deadlineToken) else { return }
                self.deadline.finish(deadlineToken); self.isSearching = false; self.request = nil; self.selection = nil
                let usable = items.filter { Coordinate($0.placemark.coordinate).valid }
                if pickSingle, usable.count == 1, let item = usable.first { self.onPick?(item) }
                else {
                    self.results = usable.prefix(12).enumerated().map { index,item in
                        PlaceResult(id:"\(token):\(index)",item:item)
                    }
                    if usable.isEmpty { self.error = "No places found. Try a more specific name or pick on the map." }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.deadline.accepts(deadlineToken) else { return }
                self.deadline.finish(deadlineToken); self.selection = nil; self.request = nil
                self.isSearching = false; self.error = "Search unavailable. Check your connection or pick a location on the map."
            }
        }
    }
    func choose(_ result: PlaceResult) {
        guard results.contains(where: { $0.id == result.id }) else { return }
        dismiss(); onPick?(result.item)
    }
}
