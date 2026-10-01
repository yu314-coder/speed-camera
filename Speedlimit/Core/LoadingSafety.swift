import Foundation

@MainActor
final class LoadingDeadline {
    private var generation: UInt64 = 0
    private var active = false
    private var timer: Task<Void,Never>?

    func begin(after duration: Duration, onTimeout: @escaping @MainActor () -> Void) -> UInt64 {
        cancel()
        active = true
        let token = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for:duration) } catch { return }
            guard let self, self.accepts(token) else { return }
            self.active = false; self.timer = nil
            onTimeout()
        }
        return token
    }
    func accepts(_ token: UInt64) -> Bool { active && generation == token }
    func finish(_ token: UInt64) {
        guard accepts(token) else { return }
        active = false; timer?.cancel(); timer = nil
    }
    func cancel() {
        generation &+= 1; active = false; timer?.cancel(); timer = nil
    }
    deinit { timer?.cancel() }
}

struct BoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let capacity: Int
    private let costLimit: Int
    private var counter: UInt64 = 0
    private var entries: [Key:(value:Value,used:UInt64,cost:Int)] = [:]
    private(set) var totalCost = 0
    init(capacity: Int, costLimit: Int = .max) {
        self.capacity = max(1,capacity); self.costLimit = max(0,costLimit)
    }
    var count: Int { entries.count }
    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        counter &+= 1; entries[key] = (entry.value,counter,entry.cost)
        return entry.value
    }
    mutating func insert(_ value: Value, for key: Key, cost: Int = 0) {
        removeValue(for:key)
        let cost = max(0,cost)
        guard cost <= costLimit else { return }
        // Evict before adding, so byte accounting cannot overflow even for an oversized input.
        while entries.count >= capacity || totalCost > costLimit-cost {
            guard let oldest = entries.min(by:{ $0.value.used < $1.value.used })?.key else { break }
            removeValue(for:oldest)
        }
        counter &+= 1; entries[key] = (value,counter,cost); totalCost += cost
    }
    mutating func removeValue(for key: Key) {
        if let entry = entries.removeValue(forKey:key) { totalCost -= entry.cost }
    }
    mutating func removeAll() {
        entries.removeAll(keepingCapacity:false); totalCost = 0
    }
}

enum MapRenderBudget {
    static func cameraLimit(for bounds: MapBounds) -> Int {
        guard bounds.valid else { return 240 }
        let latitude = (bounds.north+bounds.south)/2
        let width = (bounds.east-bounds.west)*111_320*cos(latitude * .pi/180)
        let height = (bounds.north-bounds.south)*111_320
        let span = max(width,height)
        if span <= 6000 { return 600 }
        if span <= 30_000 { return 360 }
        return 240
    }
}
