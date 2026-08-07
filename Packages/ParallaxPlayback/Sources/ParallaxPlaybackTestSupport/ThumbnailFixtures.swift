import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

// MARK: — Image decode (HEIC / JPEG)

/// Decode encoded thumbnail `Data` (HEIC, or JPEG on a host with no HEVC encoder) back into a
/// `CGImage` to assert pixel dimensions / validity. Codec-agnostic: ImageIO sniffs the format.
/// Shared by AV and VLC thumbnail suites so neither reimplements the sniffer.
public func decodeThumbnailImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) >= 1 else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: — Oversized still-source (pins the 320px tier)

/// Synthesizes a short solid-color H.264 MP4 larger than the 320-tall thumbnail tier so a test
/// can prove `AVAssetImageGenerator.maximumSize` / VLC's height bound actually scale down.
///
/// The bundled `tiny.mp4` is 160×90 — already under 320 — so deleting the tier setting would
/// not change its output at all. This clip is built at test time (no binary fixture committed),
/// written under a unique temp path, and removed by the returned handle's `cleanup`.
public enum OversizedThumbnailSource {
    /// 640×480 (4:3) — clearly taller than the 320 tier, wide enough that aspect math is obvious.
    public static let width = 640
    public static let height = 480
    /// A couple of seconds of solid color is enough for one keyframe grab.
    public static let durationSeconds: Double = 2
    public static let frameRate: Int32 = 10

    /// One synthesized clip + its cleanup. Call `cleanup` in a `defer` (or when the test ends).
    public struct Handle: Sendable {
        public let url: URL
        public let cleanup: @Sendable () -> Void
    }

    /// Writes a unique temp MP4 and returns a handle. Throws if AVAssetWriter fails to start/finish.
    public static func make() async throws -> Handle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallax-thumb-src-\(UUID().uuidString).mp4")
        try await writeSolidColorMP4(to: url)
        return Handle(url: url, cleanup: {
            try? FileManager.default.removeItem(at: url)
        })
    }

    private static func writeSolidColorMP4(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        do {
            try await writeSolidColorMP4Unchecked(to: url)
        } catch {
            // AVAssetWriter creates the file on `startWriting()`, before most of the throw sites
            // below — a caller that never runs `cleanup()` (because `make()` itself threw) must
            // not leave a stray temp MP4 behind.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func writeSolidColorMP4Unchecked(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttrs
        )
        guard writer.canAdd(input) else { throw SourceError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SourceError.startFailed }
        writer.startSession(atSourceTime: .zero)

        // Every frame is the same solid gray, so fill one buffer once and reuse it for every
        // append — the per-frame path used to allocate + byte-fill a fresh 640×480 BGRA buffer
        // (~1.2M writes) on every iteration of a 20-frame clip.
        guard let buffer = makeSolidPixelBuffer() else { throw SourceError.pixelBufferFailed }
        let frameCount = Int(durationSeconds * Double(frameRate))
        for frameIndex in 0..<frameCount {
            // Tiny clip: wait for readiness without spinning the run loop hard.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw writer.error ?? SourceError.appendFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? SourceError.finishFailed
        }
    }

    /// Solid mid-gray BGRA buffer at the fixture resolution.
    private static func makeSolidPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // BGRA: mid gray, fully opaque.
        for row in 0..<height {
            let rowStart = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                let p = rowStart.advanced(by: col * 4)
                p[0] = 0x80
                p[1] = 0x80
                p[2] = 0x80
                p[3] = 0xFF
            }
        }
        return buffer
    }

    public enum SourceError: Error, Sendable {
        case cannotAddInput
        case startFailed
        case pixelBufferFailed
        case appendFailed
        case finishFailed
    }
}
