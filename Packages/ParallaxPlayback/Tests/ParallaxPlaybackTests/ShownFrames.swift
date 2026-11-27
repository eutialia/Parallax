import AVFoundation
import Foundation
import Testing

/// A frame AVPlayer displayed, known by the number a numbered fixture draws into its picture.
struct ShownFrame: CustomStringConvertible {
    /// The item time AVPlayer displays the frame at.
    let seconds: Double
    /// The number the picture itself carries, on its middle row.
    let number: Int
    /// The number on the row above, which is the other field's row in a picture made of a
    /// field.
    let numberAbove: Int

    var description: String { String(format: "#%d at %.4f s", number, seconds) }
    /// The fixture runs at 24 frames per second from item time zero.
    var isTheSourceFrameForItsTime: Bool { isTheSourceFrame(atPicturesPerSecond: 24) }

    func isTheSourceFrame(atPicturesPerSecond rate: Double) -> Bool { number == Int((seconds * rate).rounded()) }
}

/// An AVPlayer that has loaded a URL and is ready to play it.
@MainActor
struct ReadyPlayer {
    let output: AVPlayerItemVideoOutput
    let player: AVPlayer

    /// `context` says what was served, for the issue recorded when the item never gets ready.
    init(playing url: URL, context: () -> String = { "" }) async throws {
        let item = AVPlayerItem(url: url)
        // Three seconds keeps AVPlayer from fetching all of a minute-long file.
        item.preferredForwardBufferDuration = 3
        output = .numberedPictures()
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while item.status == .unknown, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if item.status != .readyToPlay {
            Issue.record("the item never became ready: \(String(describing: item.error)), after \(context())")
        }
        try #require(item.status == .readyToPlay)
    }

    /// Seeks to exactly `seconds`, plays, and returns the frames shown in the next `duration`.
    func framesShown(from seconds: Double? = nil, for duration: Duration) async -> [ShownFrame] {
        if let seconds {
            await player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 24_000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        let shown = await output.framesShown(for: duration)
        player.pause()
        return shown
    }
}

extension AVPlayerItemVideoOutput {
    /// A numbered picture output that will be added to an item.
    static func numberedPictures() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
    }

    /// The frames the item this output is added to shows in the next `duration`.
    @MainActor
    func framesShown(for duration: Duration) async -> [ShownFrame] {
        var shown: [ShownFrame] = []
        let clock = ContinuousClock()
        let end = clock.now + duration
        while clock.now < end {
            let time = itemTime(forHostTime: CACurrentMediaTime())
            var displayed = CMTime.invalid
            if hasNewPixelBuffer(forItemTime: time),
               let buffer = copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) {
                shown.append(ShownFrame(
                    seconds: displayed.seconds, number: BridgeFixture.frameNumber(in: buffer),
                    numberAbove: BridgeFixture.frameNumber(in: buffer, rowsAboveTheMiddle: 1)))
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return shown
    }
}
