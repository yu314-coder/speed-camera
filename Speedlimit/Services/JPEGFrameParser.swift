import Foundation

struct JPEGFrameParser {
    static let maximumBytes = 3_000_000
    private enum State { case start, marker, length(UInt8), payload(Int,UInt8), scan, ended }
    private var buffer = Data()
    private var cursor = 0
    private var state = State.start
    private let continuous: Bool
    var bufferedByteCount: Int { buffer.count }

    init(continuous: Bool = false) { self.continuous = continuous }

    mutating func append(_ chunk: Data) throws -> Data? {
        if case .ended = state { return nil }
        guard buffer.count+chunk.count <= Self.maximumBytes else { throw CCTVError.imageTooLarge }
        buffer.append(chunk)
        while true {
            switch state {
            case .start:
                while cursor+1 < buffer.count {
                    if buffer[cursor] == 0xff && buffer[cursor+1] == 0xd8 {
                        buffer = Data(buffer.dropFirst(cursor)); cursor = 2; state = .marker; break
                    }
                    cursor += 1
                }
                if case .start = state {
                    guard cursor < 64_000 else { throw CCTVError.unsupportedFormat }
                    return nil
                }
            case .marker:
                guard cursor+1 < buffer.count else { return nil }
                guard buffer[cursor] == 0xff else { throw CCTVError.unsupportedFormat }
                let code = buffer[cursor+1]
                if code == 0xff { cursor += 1; continue }
                cursor += 2
                if code == 0xd9 { return finishFrame() }
                if code == 0x01 || (0xd0...0xd7).contains(code) { continue }
                guard code != 0 && code != 0xd8 else { throw CCTVError.unsupportedFormat }
                state = .length(code)
            case .length(let code):
                guard cursor+1 < buffer.count else { return nil }
                let length = Int(buffer[cursor])*256+Int(buffer[cursor+1])
                guard length >= 2 else { throw CCTVError.unsupportedFormat }
                cursor += 2; state = .payload(length-2,code)
            case .payload(let length,let code):
                guard buffer.count-cursor >= length else { return nil }
                // APP/EXIF payload may contain FF D9: only the JPEG marker stream terminates a frame.
                cursor += length; state = code == 0xda ? .scan : .marker
            case .scan:
                while cursor+1 < buffer.count {
                    if buffer[cursor] != 0xff { cursor += 1; continue }
                    let code = buffer[cursor+1]
                    if code == 0 { cursor += 2; continue }
                    if code == 0xff { cursor += 1; continue }
                    if (0xd0...0xd7).contains(code) { cursor += 2; continue }
                    state = .marker; break
                }
                if case .scan = state { return nil }
            case .ended: return nil
            }
        }
    }
    private mutating func finishFrame() -> Data {
        // Copy just the frame, not a slice that could retain a much larger multipart buffer.
        let count = cursor
        let frame = buffer.withUnsafeBytes { Data(bytes:$0.baseAddress!,count:count) }
        buffer = continuous ? Data(buffer.dropFirst(count)):Data()
        cursor = 0; state = continuous ? .start:.ended
        return frame
    }
}
