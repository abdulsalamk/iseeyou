import CoreMedia
import VideoToolbox

// Decode on the SDK delivery thread, serially and synchronously: compressed
// reference frames must not be dropped by the inference backpressure gate.
// No GPU or hardware video decoder is used, including in the foreground.
final class GlassesVideoDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
        guard let inputFormat = CMSampleBufferGetFormatDescription(sample) else { return nil }
        if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: inputFormat) {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; format = nil
            let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false] as CFDictionary
            let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                              kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                formatDescription: inputFormat, decoderSpecification: specification,
                imageBufferAttributes: attributes, outputCallback: nil,
                decompressionSessionOut: &session)
            guard status == noErr else { throw Self.error(status) }
            format = inputFormat
        }
        guard let session else { return nil }
        var result: CMSampleBuffer?
        var failure: OSStatus = noErr
        // Neither asynchronous nor temporal-processing flags are set. Apple
        // guarantees the callback completes before DecodeFrame returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            flags: [], infoFlagsOut: nil) { status, _, image, time, duration in
                guard status == noErr, let image else { failure = status; return }
                var outputFormat: CMVideoFormatDescription?
                failure = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: image, formatDescriptionOut: &outputFormat)
                guard failure == noErr, let outputFormat else { return }
                var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time,
                                                decodeTimeStamp: .invalid)
                failure = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: image, formatDescription: outputFormat, sampleTiming: &timing,
                    sampleBufferOut: &result)
            }
        guard status == noErr, failure == noErr else {
            // Damaged compressed frames are skipped; a later keyframe can recover.
            print("[ISeeYou.Meta] software decode dropped frame: \(status == noErr ? failure : status)")
            return nil
        }
        return result
    }

    private static func error(_ code: OSStatus) -> NSError {
        NSError(domain: "GlassesVideoDecoder", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Cannot create the glasses software video decoder (\(code))."])
    }
}
