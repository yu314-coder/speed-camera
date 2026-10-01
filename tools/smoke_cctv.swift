import Foundation
import ImageIO

@main
struct CCTVSmoke {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: cctv-smoke HTTPS_URL OUTPUT_JPEG"); exit(2)
        }
        do {
            let start = Date()
            let image = try await CCTVService.shared.snapshot(urlString:CommandLine.arguments[1])
            guard let source = CGImageSourceCreateWithData(image.data as CFData,nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CCTVError.unavailable }
            try image.data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
            print("Public CCTV JPEG: \(image.data.count) bytes, \(Date().timeIntervalSince(start)) seconds; decoded \(decoded.width)x\(decoded.height); no credentials; \(CommandLine.arguments[1])")
        } catch { print("Public camera unavailable: \(error.localizedDescription)"); exit(1) }
    }
}
