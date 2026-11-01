import Foundation

/// A single metadata record for one volunteer correction. Images and optional clips
/// are stored separately under the same UUID, then referenced by their object keys.
struct HumanTeacherCorrection: Codable, Identifiable {
    struct BoundingBox: Codable {
        /// Normalized Vision coordinates, origin at bottom-left.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct OriginalDetection: Codable {
        let label: String
        let confidence: Double
        let boundingBox: BoundingBox
    }

    let id: UUID
    let capturedAt: Date
    let transcriptText: String
    let originalDetection: OriginalDetection?
    let modelVersion: String
    let frameObjectKey: String
    let clipObjectKey: String?
    let correctedLabel: String
    let triggeredAt: Date
    let source: String
    let frameSHA256: String
    let processingState: String
    let schemaVersion: Int

    init(id: UUID = UUID(), capturedAt: Date = Date(),
         transcriptText: String, originalDetection: OriginalDetection?,
         modelVersion: String, frameObjectKey: String,
         clipObjectKey: String? = nil, correctedLabel: String = "",
         triggeredAt: Date = Date(), source: String = "unknown", frameSHA256: String = "") {
        self.id = id
        self.capturedAt = capturedAt
        self.transcriptText = transcriptText
        self.originalDetection = originalDetection
        self.modelVersion = modelVersion
        self.frameObjectKey = frameObjectKey
        self.clipObjectKey = clipObjectKey
        self.correctedLabel = correctedLabel
        self.triggeredAt = triggeredAt
        self.source = source
        self.frameSHA256 = frameSHA256
        self.processingState = "awaiting_validation"
        self.schemaVersion = 1
    }

    var s3Prefix: String { "corrections/\(id.uuidString.lowercased())/" }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
