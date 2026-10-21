import Foundation
import CoreGraphics

struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    // Vision coordinates: normalized, bottom-left origin, portrait image.
    let bounds: CGRect
    var distance: ObjectDistance? = nil
    var inPath: Bool { bounds.maxX > 0.3 && bounds.minX < 0.7 }
}

enum DetectionGeometry {
    static func displayRect(_ bounds: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: bounds.minX * size.width, y: (1 - bounds.maxY) * size.height,
               width: bounds.width * size.width, height: bounds.height * size.height)
    }
}
