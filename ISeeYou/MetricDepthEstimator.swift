import CoreML
import CoreImage
import CoreGraphics

struct ObjectDistance: Equatable {
    let metres: Double
    let spread: Double
    let coverage: Double
}

// Portrait detector and depth both consume the same sample buffer. The full
// image is resized, never cropped, so normalized boxes map directly to depth.
final class MetricDepthEstimator {
    static let modelID = "hypersim-small-294x518-v1"
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private let width = 294, height = 518
    init() throws {
        guard let url = Bundle.main.url(forResource: "MetricDepthSmall", withExtension: "mlmodelc") else {
            throw NSError(domain: "Depth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metric depth model missing"])
        }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: config)
    }
    func estimate(_ buffer: CVPixelBuffer, detections: [Detection]) throws -> [Detection] {
        try estimateFrame(buffer, detections: detections).objects
    }
    func estimateFrame(_ buffer: CVPixelBuffer, detections: [Detection]) throws -> (objects: [Detection], surface: ObjectDistance?) {
        var resized: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &resized) == kCVReturnSuccess, let resized else {
            throw NSError(domain: "Depth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate depth input"])
        }
        let source = CIImage(cvPixelBuffer: buffer)
        let image = source.transformed(by: CGAffineTransform(scaleX: Double(width)/source.extent.width,
            y: Double(height)/source.extent.height))
        context.render(image, to: resized, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: resized)]))
        guard let depth = output.featureValue(for: "depthMetres")?.multiArrayValue,
              depth.shape.map(\.intValue) == [1, height, width] else {
            throw NSError(domain: "Depth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected depth output shape"])
        }
        let objects = detections.map { item in
            var result = item
            result.distance = DepthSampling.read(bounds: item.bounds, width: width, height: height) { x, y in
                depth[[0, NSNumber(value: y), NSNumber(value: x)]].doubleValue
            }
            return result
        }
        let surface = SurfaceDepthSampling.read(width: width, height: height) { x, y in
            depth[[0, NSNumber(value: y), NSNumber(value: x)]].doubleValue
        }
        return (objects, surface)
    }
}

enum DepthSampling {
    static func read(bounds: CGRect, width: Int, height: Int, value: (Int, Int) -> Double) -> ObjectDistance? {
        guard bounds.width >= 0.035, bounds.height >= 0.035 else { return nil }
        // Inset centre ROI reduces background leakage; it cannot eliminate it.
        let roi = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)
        let left = max(0, Int(roi.minX * Double(width)))
        let right = min(width - 1, Int(roi.maxX * Double(width)))
        let top = max(0, Int((1 - roi.maxY) * Double(height)))
        let bottom = min(height - 1, Int((1 - roi.minY) * Double(height)))
        guard right > left, bottom > top else { return nil }
        var samples: [Double] = []; var total = 0
        for y in stride(from: top, through: bottom, by: max(1, (bottom - top)/12)) {
            for x in stride(from: left, through: right, by: max(1, (right - left)/12)) {
                total += 1
                let v = value(x, y)
                if v.isFinite && v >= 0.15 && v <= 10 { samples.append(v) }
            }
        }
        let coverage = Double(samples.count)/Double(max(1, total))
        guard samples.count >= 9, coverage >= 0.8 else { return nil }
        samples.sort()
        let median = samples[samples.count/2]
        let spread = samples[samples.count * 3/4] - samples[samples.count/4]
        guard spread <= max(0.15, median * 0.25) else { return nil }
        return ObjectDistance(metres: median, spread: spread, coverage: coverage)
    }
}
