import Foundation

// Local numeric/lifecycle diagnostics only: no images, labels, or audio.
// Allows lock tests without a debugger or interactive phone screen connection.
enum GlassesSessionDiagnostics {
    private static let lock = NSLock()
    private static var state: [String: Any] = [:]
    private static var frames = 0
    static func record(_ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if values["event"] as? String == "start" { state = [:]; frames = 0 }
        state.merge(values) { _, new in new }
        save()
    }
    static func frameDecoded() {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        if frames == 1 || frames % 30 == 0 {
            state["decodedFrames"] = frames
            state["lastFrameAt"] = Date().timeIntervalSince1970
            save()
        }
    }
    private static func save() {
        state["updatedAt"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent("glasses-session-diagnostics.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
