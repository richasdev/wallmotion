import AVFoundation
import CoreVideo
import CoreGraphics
import XCTest

@MainActor
enum LocalVideoFixture {
    static func write(at url: URL, rotated: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32, AVVideoHeightKey: 16
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw XCTSkip("O encoder H.264 não está disponível nesta sessão.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "WallmotionVideoFixture", code: 1)
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            guard try await eventually({ input.isReadyForMoreMediaData || writer.status == .failed }) else {
                throw NSError(domain: "WallmotionVideoFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout esperando encoder H.264"])
            }
            if let error = writer.error { throw error }
            var optionalBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary, &optionalBuffer)
            XCTAssertEqual(result, kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            do {
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                let context = try XCTUnwrap(CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: 32, height: 16,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                ))
                context.setFillColor(CGColor(red: CGFloat(index) / 2, green: 0.5, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 3)) else {
                throw writer.error ?? NSError(domain: "WallmotionVideoFixture", code: 3)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "WallmotionVideoFixture", code: 4)
        }
    }
    private static func eventually(timeout: Duration = .seconds(5), _ predicate: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
