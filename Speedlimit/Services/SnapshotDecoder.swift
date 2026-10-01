import ImageIO
import UIKit

enum SnapshotDecoder {
    static let maximumPixelSize = 1024
    private static let cache = DecodedSnapshotCache()
    static func releaseMemory() { cache.removeAll() }
    static func cacheUsage() -> (bytes: Int, count: Int) { cache.usage() }
    static func decode(_ snapshot: CameraSnapshot, url: String) throws -> UIImage {
        let (cached,generation) = cache.lookup(url:url,downloadedAt:snapshot.downloadedAt)
        if let cached { return cached }
        let image = try decode(snapshot.data)
        let bytes = image.cgImage.map { $0.bytesPerRow*$0.height } ?? 0
        cache.insert(image,url:url,downloadedAt:snapshot.downloadedAt,cost:bytes,generation:generation)
        return image
    }
    static func decode(_ data: Data) throws -> UIImage {
        try autoreleasepool { try downsample(data) }
    }
    private static func downsample(_ data: Data) throws -> UIImage {
        guard data.count <= 3_000_000,
              let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8000, height <= 8000, width * height <= 25_000_000 else {
            throw CCTVError.imageTooLarge
        }
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                                    kCGImageSourceCreateThumbnailWithTransform:true,
                                    kCGImageSourceThumbnailMaxPixelSize:maximumPixelSize,
                                    kCGImageSourceShouldCacheImmediately:true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { throw CCTVError.unavailable }
        return UIImage(cgImage:image)
    }
}

private final class DecodedSnapshotCache: @unchecked Sendable {
    private struct Entry: @unchecked Sendable {
        let image: UIImage
        let downloadedAt: Date
    }
    private let lock = NSLock()
    private var generation = 0
    private var images = BoundedCache<String,Entry>(capacity:2,costLimit:4_000_000)
    func lookup(url: String, downloadedAt: Date) -> (UIImage?,Int) {
        lock.lock(); defer { lock.unlock() }
        let entry = images.value(for:url)
        return (entry?.downloadedAt == downloadedAt ? entry?.image : nil,generation)
    }
    func insert(_ image: UIImage, url: String, downloadedAt: Date, cost: Int, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        // A decode started before a memory warning must not refill the cleared cache.
        guard self.generation == generation else { return }
        images.insert(.init(image:image,downloadedAt:downloadedAt),for:url,cost:cost)
    }
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; images.removeAll()
    }
    func usage() -> (bytes: Int, count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (images.totalCost,images.count)
    }
}
