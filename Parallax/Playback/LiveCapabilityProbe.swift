import AVFoundation
import CoreMedia
import VideoToolbox
import os
import UIKit
import ParallaxCore
import ParallaxPlayback

/// Live `CapabilityProbe`. Lives in the app target: `ParallaxPlayback` stays
/// free of UIKit and device-bound AV APIs so profile building is deterministic
/// under test, and the no-drift rule forbids `#if os` in `Packages/`.
/// Injected into `DeviceProfileBuilder`.
struct LiveCapabilityProbe: CapabilityProbe {
    nonisolated func hdrSupport() -> HDRSupport {
        // `eligibleForHDRPlayback` already means "this device can present content
        // to an HDR display" — it accounts for the connected display and updates
        // on display changes. The old extra requirement that the UI screen report
        // a P3 gamut broke Apple TV: a tvOS session commonly runs its UI in SDR
        // (match-content setups), the probe then claimed no HDR, the new
        // videoRangeType gate excluded HDR10, and the server was forced into a
        // 4K tone-map re-encode it couldn't sustain in realtime — endless
        // buffering with -12889 segment timeouts (device-diagnosed 2026-06-10).
        // Per TN3145, AVPlayer tone-maps HDR optimally on any Apple device, so
        // delivering HDR10 whenever the device is eligible is safe.
        guard AVPlayer.eligibleForHDRPlayback else { return .none }
        var support: HDRSupport = .hdr10

        // Dolby Vision (bare profile 5, no fallback layer — see
        // DeviceProfileTranslator.codecProfiles). The obvious API,
        // `AVPlayer.availableHDRModes` (`AVPlayerHDRMode.dolbyVision`), is
        // deprecated as of iOS/tvOS 26 in favor of `eligibleForHDRPlayback` —
        // confirmed via the installed iOS 26 SDK header (AVPlayer.h): "Use
        // eligibleForHDRPlayback instead". That replacement collapses to a
        // single generic "some HDR is presentable" bit and can't distinguish
        // Dolby Vision from HDR10/HLG, so it can't stand in for the old
        // DV-specific check. `VTIsHardwareDecodeSupported` for the Dolby
        // Vision HEVC codec type is NOT deprecated and IS cross-platform (iOS
        // 11+ / tvOS 11+ per the VideoToolbox header) — it answers "can this
        // silicon decode a DV bitstream at all," which combined with the
        // HDR-eligible-display gate above is the closest available proxy for
        // "safe to declare bare DOVI to the server." It can't tell a
        // DV-capable panel from a generic-HDR one, but there is no narrower
        // public signal post-deprecation, on either iOS or tvOS.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC) {
            support.insert(.dolbyVision)
        }
        return support
    }

    nonisolated func avPlayerSupport() -> AVPlayerSupport {
        AVPlayerSupportProbe.probe(
            isPlayable: AVURLAsset.isPlayableExtendedMIMEType,
            mimeTypes: Set(AVURLAsset.audiovisualMIMETypes()),
            decodesInHardware: VTIsHardwareDecodeSupported,
            decodesH264High10: Self.decodesH264High10()
        )
    }

    /// Decodes one frame of 10-bit H.264 on the hardware decoder. The MIME check says yes on
    /// devices whose decoder turns it into a black picture, so only a decoded frame answers.
    nonisolated private static func decodesH264High10() -> Bool {
        var format: CMFormatDescription?
        let made = H264High10Frame.sequenceParameters.withUnsafeBufferPointer { sps in
            H264High10Frame.pictureParameters.withUnsafeBufferPointer { pps in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: [sps.baseAddress!, pps.baseAddress!],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        var session: VTDecompressionSession?
        guard made == noErr, let format,
              VTDecompressionSessionCreate(
                  allocator: nil, formatDescription: format,
                  decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
                      as CFDictionary,
                  imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session
        else { return false }
        defer { VTDecompressionSessionInvalidate(session) }

        let sample = withUnsafeBytes(of: UInt32(H264High10Frame.slice.count).bigEndian, Array.init)
            + H264High10Frame.slice
        var block: CMBlockBuffer?
        var buffer: CMSampleBuffer?
        var size = sample.count
        guard CMBlockBufferCreateWithMemoryBlock(
                  allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil,
                  customBlockSource: nil, offsetToData: 0, dataLength: sample.count,
                  flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(
                  with: sample, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count) == noErr,
              CMSampleBufferCreateReady(
                  allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                  sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer
        else { return false }

        let decoded = OSAllocatedUnfairLock(initialState: false)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            let shown = status == noErr && image != nil
            decoded.withLock { $0 = shown }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr && decoded.withLock { $0 }
    }
}

/// A 64×64 grey keyframe in H.264 High 10, from `ffmpeg -f lavfi -i color=c=gray:size=64x64
/// -frames:v 1 -c:v libx264 -preset ultrafast -pix_fmt yuv420p10le -profile:v high10`. Smaller
/// frames fail in any profile: they are below the hardware decoder's minimum size.
nonisolated private enum H264High10Frame {
    static let sequenceParameters: [UInt8] = [
        0x67, 0x6E, 0x00, 0x0A, 0xA6, 0xCB, 0x42, 0x13, 0x60, 0x22, 0x00, 0x00, 0x03, 0x00, 0x02, 0x00,
        0x00, 0x03, 0x00, 0x04, 0x1E, 0x24, 0x4D, 0x40,
    ]
    static let pictureParameters: [UInt8] = [0x68, 0xCE, 0x0F, 0xC8]
    static let slice: [UInt8] = [
        0x65, 0x88, 0x84, 0x3A, 0x26, 0x28, 0x0C, 0x9C, 0x9C, 0x9D, 0x75, 0xD7, 0x5D, 0x75, 0xD7, 0x5D,
        0x75, 0xD7, 0x5E,
    ]
}
