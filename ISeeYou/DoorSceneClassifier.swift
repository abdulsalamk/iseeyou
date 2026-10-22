import Foundation
import CoreML
import CoreImage

enum DoorVisualState: String, CaseIterable {
    case open, partlyOpen, closed, stateUncertain, uncertain
    var message: String {
        switch self {
        case .open: return "Door may be open. Opening not verified."
        case .partlyOpen: return "Door may be partly open."
        case .closed: return "Door may be closed."
        case .stateUncertain: return "Possible door. Open or closed uncertain."
        case .uncertain: return "Door not established. State uncertain."
        }
    }
}

// Similarities are not probabilities or calibrated confidence percentages.
// These conservative experimental thresholds still require physical evaluation.
enum DoorSceneScoring {
    static func decide(_ scores: [String: Double]) -> DoorVisualState {
        let states = [DoorVisualState.open, .partlyOpen, .closed]
        guard scores.values.allSatisfy(\.isFinite),
              states.allSatisfy({ scores[$0.rawValue] != nil }) else { return .uncertain }
        let ranked = states.sorted { scores[$0.rawValue]! > scores[$1.rawValue]! }
        let best = scores[ranked[0].rawValue]!
        let runnerUp = scores[ranked[1].rawValue]!
        let negatives = scores.filter { !states.map(\.rawValue).contains($0.key) }.map(\.value)
        guard let nonDoor = negatives.max(), best >= 0.25,
              best - nonDoor >= 0.025 else { return .uncertain }
        return best - runnerUp >= 0.03 ? ranked[0] : .stateUncertain
    }
}

struct DoorStateConsensus {
    private var state: DoorVisualState?
    private var first: TimeInterval?
    private var last: TimeInterval?
    private var count = 0
    mutating func update(_ next: DoorVisualState, at time: TimeInterval) -> DoorVisualState? {
        guard time.isFinite else { self = DoorStateConsensus(); return nil }
        if state != next || last == nil || time < last! || time - last! > 1.2 {
            state = next; first = time; count = 0
        }
        last = time; count += 1
        guard count >= 3, time - first! + 0.000001 >= 0.8 else { return nil }
        return next
    }
}

struct DoorSceneAssessment {
    let state: DoorVisualState
    let scores: [String: Double]
    var diagnostic: String {
        let ranked = scores.sorted { $0.value > $1.value }
        return "Scene comparison (not confidence percentages): " + ranked.prefix(4).map {
            String(format: "%@ %.3f", $0.key, $0.value)
        }.joined(separator: "; ")
    }
}

final class DoorSceneClassifier {
    private struct PromptBank: Decodable {
        struct Group: Decodable { let label: String; let embedding: [Double] }
        let model: String
        let variant: String
        let groups: [Group]
    }
    private let model: MLModel
    private let bank: PromptBank
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "DoorSceneImage", withExtension: "mlmodelc"),
              let prompts = Bundle.main.url(forResource: "DoorPrompts", withExtension: "json") else {
            throw Self.failure("Door scene model or prompt embeddings are missing.")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        bank = try JSONDecoder().decode(PromptBank.self, from: Data(contentsOf: prompts))
        guard bank.model == "openai/CLIP", bank.variant == "ViT-B/32",
              bank.groups.count >= 4, bank.groups.allSatisfy({
                  $0.embedding.count == 512 && $0.embedding.allSatisfy(\.isFinite)
              }) else { throw Self.failure("Door prompt embeddings do not match the image model.") }
    }
    func assess(_ buffer: CVPixelBuffer) throws -> DoorVisualState {
        try assessDetailed(buffer).state
    }
    func assessDetailed(_ buffer: CVPixelBuffer) throws -> DoorSceneAssessment {
        let source = CIImage(cvPixelBuffer: buffer)
        let side = min(source.extent.width, source.extent.height)
        let crop = CGRect(x: source.extent.midX - side / 2, y: source.extent.midY - side / 2,
                          width: side, height: side)
        let image = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: 224 / side, y: 224 / side))
        var resized: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 224, 224, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &resized)
        guard status == kCVReturnSuccess, let resized else { throw Self.failure("Cannot prepare door image.") }
        context.render(image, to: resized, bounds: CGRect(x: 0, y: 0, width: 224, height: 224),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: resized)]))
        guard let embedding = output.featureValue(for: "imageEmbedding")?.multiArrayValue,
              embedding.count == 512 else { throw Self.failure("Unexpected door image embedding.") }
        let values = (0..<512).map { embedding[$0].doubleValue }
        guard values.allSatisfy(\.isFinite) else { return DoorSceneAssessment(state: .uncertain, scores: [:]) }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return DoorSceneAssessment(state: .uncertain, scores: [:]) }
        var scores: [String: Double] = [:]
        for group in bank.groups {
            let groupNorm = sqrt(group.embedding.reduce(0) { $0 + $1 * $1 })
            guard groupNorm > 0 else { return DoorSceneAssessment(state: .uncertain, scores: [:]) }
            scores[group.label] = zip(values, group.embedding).reduce(0) { $0 + $1.0 * $1.1 } / (norm * groupNorm)
        }
        return DoorSceneAssessment(state: DoorSceneScoring.decide(scores), scores: scores)
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "DoorSceneClassifier", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
