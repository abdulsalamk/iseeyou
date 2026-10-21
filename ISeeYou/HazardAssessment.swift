import Foundation
import CoreGraphics

enum AlertLevel: Int, Comparable {
    case silence, caution, urgent
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum GroundContact { case unknown, floor, supported, occluded }
enum UserMotion { case unknown, stationary, walking }
enum WarningSensitivity: String, CaseIterable {
    case conservative, balanced
    var minimumConfidence: Float { self == .conservative ? 0.8 : 0.65 }
}

// Evidence must come from a validated, timestamp-aligned sensor/model, never a COCO label.
struct HazardContext {
    var poseStable = false
    var motion: UserMotion = .unknown
    var contact: [UUID: GroundContact] = [:]
    var imminent: Set<UUID> = []
}

struct HazardDecision {
    let detection: Detection
    let level: AlertLevel
    let rationale: String
    let message: String
}

// Vision coordinates, bottom-left origin. An uncalibrated candidate, not free space.
enum CandidateCorridor {
    static let farY: CGFloat = 0.55
    static func halfWidth(at y: CGFloat) -> CGFloat {
        0.32 - min(max(y, 0), farY) / farY * 0.22
    }
    static func intersectsFoot(_ bounds: CGRect) -> Bool {
        guard bounds.minY >= 0, bounds.minY < farY else { return false }
        let width = halfWidth(at: bounds.minY)
        return bounds.maxX > 0.5 - width && bounds.minX < 0.5 + width
    }
}

protocol HazardAssessing {
    func assess(_ detections: [Detection], context: HazardContext,
                sensitivity: WarningSensitivity) -> [HazardDecision]
}

struct HazardAssessment: HazardAssessing {
    func assess(_ detections: [Detection], context: HazardContext,
                sensitivity: WarningSensitivity) -> [HazardDecision] {
        detections.map { object in
            func decision(_ level: AlertLevel, _ reason: String, _ message: String = "") -> HazardDecision {
                HazardDecision(detection: object, level: level, rationale: reason, message: message)
            }
            let b = object.bounds
            guard b.origin.x.isFinite, b.origin.y.isFinite, b.width.isFinite, b.height.isFinite,
                  b.width > 0, b.height > 0, b.minX >= 0, b.maxX <= 1, b.minY >= 0, b.maxY <= 1 else {
                return decision(.silence, "Invalid geometry")
            }
            guard object.confidence >= sensitivity.minimumConfidence else {
                return decision(.silence, "Low confidence")
            }
            guard CandidateCorridor.intersectsFoot(b) else {
                return decision(.silence, "Foot outside candidate corridor")
            }
            guard context.poseStable else { return decision(.silence, "Camera pose unknown or changing") }
            guard context.motion == .walking else { return decision(.silence, "Walking not established") }
            guard let contact = context.contact[object.id], contact == .floor else {
                return decision(.silence, "Floor contact unverified, supported or occluded")
            }
            // Size is image-space evidence only; it never supplies metres.
            guard b.minY < 0.3, b.width * b.height > 0.015 else {
                return decision(.silence, "Interaction uncertain: small or distant image footprint")
            }
            if context.imminent.contains(object.id) {
                return decision(.urgent, "Validated imminent interaction", "Obstacle ahead, stop")
            }
            let low = b.height < 0.25
            return decision(.caution, "Floor footprint intersects candidate corridor",
                            low ? "Trip hazard ahead" : "Obstacle ahead")
        }
    }
}

// No implementation is bundled: COCO cannot establish stairs, kerbs, holes,
// drop-offs, uneven surfaces, or even a generic wall.
protocol SurfaceHazardProviding {
    var validatedCapabilities: Set<String> { get }
    func hazards(at timestamp: TimeInterval) -> [HazardDecision]
}

struct UnavailableSurfaceHazards: SurfaceHazardProviding {
    let validatedCapabilities: Set<String> = []
    func hazards(at timestamp: TimeInterval) -> [HazardDecision] { [] }
}
