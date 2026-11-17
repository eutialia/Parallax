import AetherLibavutil
import AetherLibswscale
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// One picture as the encoder wrote it: its units each behind a four-byte length, as an MP4
/// sample holds them.
struct EncodedPicture: Sendable {
    let data: Data
    /// When it is shown, in the ticks the picture was handed over with.
    let tick: Int64
    let isKeyframe: Bool
}

/// What the encoder is asked for. A pure function of the stream and its first picture, so
/// every request for a segment asks for the same thing and gets the same parameter sets.
struct HEVCFormat: Sendable, Equatable {
    let width: Int
    let height: Int
    /// Main 10 from ten-bit pictures, Main from eight.
    let isTenBit: Bool
    let isFullRange: Bool
    let frameRate: Double
    /// The H.273 code points of the stream's color: primaries, transfer function and matrix.
    /// 2 is "unspecified".
    let primaries: Int32
    let transfer: Int32
    let matrix: Int32

    /// What the encoder holds steady, from 0 to 1. It is given no bitrate: a picture takes the
    /// bits it needs.
    static let quality = 0.85

    /// Bits per second a playlist says to expect, which no setting holds the encoder to:
    /// `0.15 × width × height × pictures per second`, and 2 Mbit/s at least. 7.5 Mbit/s for
    /// 1080p24.
    var expectedBitrate: Int {
        max(Int(0.15 * Double(width * height) * frameRate), 2_000_000)
    }

    fileprivate var pixelFormat: OSType {
        switch (isTenBit, isFullRange) {
        case (false, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (false, true): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (true, false): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (true, true): kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }

    /// The color as Core Video names it. A code point it has no name for is left out: it
    /// answers such a one with a placeholder, "YCbCrMatrix#5", which the session refuses.
    fileprivate var colorAttachments: [(key: CFString, value: CFString)] {
        [
            (kCVImageBufferColorPrimariesKey, CVColorPrimariesGetStringForIntegerCodePoint(primaries)?.takeUnretainedValue()),
            (kCVImageBufferTransferFunctionKey, CVTransferFunctionGetStringForIntegerCodePoint(transfer)?.takeUnretainedValue()),
            (kCVImageBufferYCbCrMatrixKey, CVYCbCrMatrixGetStringForIntegerCodePoint(matrix)?.takeUnretainedValue()),
        ].compactMap { pair in
            pair.1.flatMap { name in (name as String).contains("#") ? nil : (pair.0, name) }
        }
    }
}

/// Encodes pictures as HEVC through a `VTCompressionSession`, with no reordering: a picture
/// decodes when it is shown. The first picture a session is handed comes back a keyframe.
///
/// Lives on one thread, the demuxer's queue that reads the segment. The session hands its
/// pictures back on a thread of its own, into a locked list this one empties.
final class HEVCEncoder {
    enum Failure: Error, Equatable {
        /// No session opened, or it refused a setting.
        case session(code: OSStatus)
        case pixelBuffer(code: Int32)
        /// swscale has no path from the decoder's pixel format.
        case scaler
        case encoder(code: OSStatus)
    }

    private let session: VTCompressionSession
    private let format: HEVCFormat
    private let timescale: Int32
    private let output = Output()
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var scaledFrom: (width: Int32, height: Int32, format: Int32)?

    /// Pictures are handed over and come back timed in ticks of `timescale`.
    init(_ format: HEVCFormat, timescale: Int64) throws(Failure) {
        let buffers: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat, kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(format.width), height: Int32(format.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: buffers as CFDictionary, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else { throw .session(code: status) }
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel,
             format.isTenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_Quality, HEVCFormat.quality as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, format.frameRate as CFNumber),
        ] + zip(
            [kVTCompressionPropertyKey_ColorPrimaries, kVTCompressionPropertyKey_TransferFunction,
             kVTCompressionPropertyKey_YCbCrMatrix],
            [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
        ).compactMap { property, attachment in
            format.colorAttachments.first { $0.key == attachment }.map { (property, $0.value as CFTypeRef) }
        }
        for (key, value) in settings {
            let status = VTSessionSetProperty(made, key: key, value: value)
            guard status == noErr else {
                VTCompressionSessionInvalidate(made)
                throw .session(code: status)
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(made)
        session = made
        self.format = format
        self.timescale = Int32(timescale)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
        sws_freeContext(scaler)
    }

    /// The `hvcC` records of the pictures that have come back: the parameter sets they decode
    /// with. One, unless the session changed them part way.
    var records: [Data] { output.state.withLock { $0.records } }

    /// Hands the session one decoded picture, shown at `tick`. The picture is repacked into
    /// the two planes the encoder takes, and reduced to 4:2:0 and to ten bits on the way.
    func encode(_ frame: UnsafePointer<AVFrame>, at tick: Int64) throws {
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { throw Failure.pixelBuffer(code: 0) }
        var made: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard status == kCVReturnSuccess, let buffer = made else { throw Failure.pixelBuffer(code: status) }
        try repack(frame, into: buffer)
        // A buffer whose color disagrees with the session's can make the encoder write new
        // parameter sets.
        for (key, value) in format.colorAttachments { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }

        let output = output
        let submitted = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: tick, timescale: timescale),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            output.take(sample, status: status)
        }
        guard submitted == noErr else { throw Failure.encoder(code: submitted) }
    }

    /// Waits for every picture handed over to come back.
    func finish() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw Failure.encoder(code: status) }
    }

    /// The pictures that came back since the last call, in the order handed over. Throws what
    /// the session failed a picture with.
    func takeEncoded() throws -> [EncodedPicture] {
        let (pictures, status) = output.state.withLock { state in
            defer { state.pictures = [] }
            return (state.pictures, state.status)
        }
        guard status == noErr else { throw Failure.encoder(code: status) }
        return pictures
    }

    private func repack(_ frame: UnsafePointer<AVFrame>, into buffer: CVPixelBuffer) throws {
        let source = (frame.pointee.width, frame.pointee.height, frame.pointee.format)
        if scaledFrom.map({ $0 != source }) ?? true {
            sws_freeContext(scaler)
            scaler = sws_getContext(
                source.0, source.1, AVPixelFormat(rawValue: source.2), Int32(format.width), Int32(format.height),
                format.isTenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            scaledFrom = source
            // Both sides are given the one range, so no sample is rescaled. Left alone, swscale
            // takes a full-range JPEG format down to video range, under a buffer marked full.
            let range: Int32 = format.isFullRange ? 1 : 0
            let matrix = sws_getCoefficients(SWS_CS_DEFAULT)
            if let scaler { sws_setColorspaceDetails(scaler, matrix, range, matrix, range, 0, 1 << 16, 1 << 16) }
        }
        guard let scaler else { throw Failure.scaler }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planes: [UnsafeMutablePointer<UInt8>?] = (0..<2).map {
            CVPixelBufferGetBaseAddressOfPlane(buffer, $0)?.assumingMemoryBound(to: UInt8.self)
        } + [nil, nil]
        let strides = (0..<2).map { Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, $0)) } + [0, 0]
        let sourcePlanes: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3),
        ]
        let sourceStrides = [
            frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2, frame.pointee.linesize.3,
        ]
        let rows = sws_scale(scaler, sourcePlanes, sourceStrides, 0, source.1, planes, strides)
        guard rows == Int32(format.height) else { throw Failure.scaler }
    }

    /// What the session has handed back and nobody has taken yet.
    private final class Output: Sendable {
        let state = Mutex((pictures: [EncodedPicture](), records: [Data](), status: noErr))

        func take(_ sample: CMSampleBuffer?, status: OSStatus) {
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
                // A dropped picture comes back with no sample and no error.
                if status != noErr { state.withLock { $0.status = status } }
                return
            }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let copied = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            let atoms = CMSampleBufferGetFormatDescription(sample).flatMap {
                CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            } as? [String: Any]
            let picture = EncodedPicture(
                data: data, tick: CMSampleBufferGetPresentationTimeStamp(sample).value, isKeyframe: isKeyframe)
            state.withLock { state in
                guard copied == noErr else {
                    state.status = copied
                    return
                }
                state.pictures.append(picture)
                if let record = atoms?["hvcC"] as? Data, !state.records.contains(record) { state.records.append(record) }
            }
        }
    }
}
