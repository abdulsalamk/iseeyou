import XCTest
import VideoToolbox
@testable import ISeeYou

final class GlassesVideoDecoderTests: XCTestCase {
    private final class EncodedFrame {
        let ready: XCTestExpectation
        var sample: CMSampleBuffer?
        init(_ ready: XCTestExpectation) { self.ready = ready }
    }

    func testCompressedHEVCBecomesAnImageWithoutHardwareDecoding() throws {
        let frame = EncodedFrame(expectation(description: "HEVC encoded"))
        var encoder: VTCompressionSession?
        let creation = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: 128, height: 128, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in
                guard let ref else { return }
                let frame = Unmanaged<EncodedFrame>.fromOpaque(ref).takeUnretainedValue()
                if status == noErr { frame.sample = sample }
                frame.ready.fulfill()
            }, refcon: Unmanaged.passUnretained(frame).toOpaque(), compressionSessionOut: &encoder)
        XCTAssertEqual(creation, noErr)
        let session = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(session) }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 128, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        let time = CMTime(value: 1, timescale: 15)
        XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: image,
            presentationTimeStamp: time, duration: time, frameProperties: nil,
            sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        wait(for: [frame.ready], timeout: 10)
        let compressed = try XCTUnwrap(frame.sample)
        XCTAssertNil(CMSampleBufferGetImageBuffer(compressed))
        let decoder = GlassesVideoDecoder()
        let decoded = try XCTUnwrap(decoder.decode(compressed))
        let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(decoded))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 128)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(decoded), time)
        // Already-decoded frames also pass through, covering both SDK formats.
        XCTAssertNotNil(try decoder.decode(decoded))
    }
}
