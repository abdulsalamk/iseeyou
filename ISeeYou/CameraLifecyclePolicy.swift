import Foundation

enum CameraLifecyclePolicy {
    static func shouldStop(active: Bool, background: Bool, permissionPending: Bool) -> Bool {
        background || (!active && !permissionPending)
    }
}
