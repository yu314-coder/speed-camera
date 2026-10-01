#if DEBUG
import UIKit

// Opt-in simulator/device profiling. No destination text or location is recorded.
@MainActor
final class SearchInteractionProbe: NSObject {
    private var link: CADisplayLink?
    private var started = 0.0, previous = 0.0, maximumGap = 0.0
    private var frames = 0, edits = 0
    private var maximumEdit = 0.0, editingBegan = 0.0
    func begin() {
        guard ProcessInfo.processInfo.arguments.contains("--profile-search"), link == nil else { return }
        started = CACurrentMediaTime(); previous = 0; maximumGap = 0; frames = 0
        edits = 0; maximumEdit = 0; editingBegan = 0
        let link = CADisplayLink(target:self,selector:#selector(tick))
        link.add(to:.main,forMode:.common); self.link = link
    }
    func didBeginEditing() { if link != nil { editingBegan = (CACurrentMediaTime()-started)*1000 } }
    func edit(duration: Double) { if link != nil { edits += 1; maximumEdit = max(maximumEdit,duration*1000) } }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        if previous > 0 { maximumGap = max(maximumGap,(now-previous)*1000) }
        previous = now; frames += 1
    }
    func finish() {
        guard let link else { return }; link.invalidate(); self.link = nil
        let sample: [String:Any] = ["duration_ms":(CACurrentMediaTime()-started)*1000,
            "first_responder_ms":editingBegan,"display_callbacks":frames,"maximum_main_callback_gap_ms":maximumGap,
            "native_edits":edits,"maximum_edit_scheduling_ms":maximumEdit,
            "note":"Simulator timing includes OS/automation load; not a physical-device FPS measurement"]
        guard var data = try? JSONSerialization.data(withJSONObject:sample,options:.sortedKeys),
              let directory = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        data.append(10)
        let url = directory.appendingPathComponent("search-interactions.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil) }
        if let file = try? FileHandle(forWritingTo:url) {
            defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf:data)
        }
    }
}
#endif
