import Foundation

enum CameraLifecyclePolicy {
    static func shouldStop(active: Bool, background: Bool, permissionPending: Bool,
                           glassesSessionRequested: Bool = false) -> Bool {
        if glassesSessionRequested { return false }
        return background || (!active && !permissionPending)
    }
}
