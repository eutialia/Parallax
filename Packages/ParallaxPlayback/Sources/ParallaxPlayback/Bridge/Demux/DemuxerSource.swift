import AetherLibavformat
import AetherLibavutil
import Foundation
import ParallaxCore
import Synchronization

/// The bytes libavformat reads, served from a `RandomAccessReading`.
///
/// libavformat calls back synchronously and the reader is async, so each read parks the calling
/// thread until the reader answers. That thread must be the demuxer's own, never one of the
/// cooperative pool's: `MediaDemuxer` guarantees it.
final class DemuxerSource {
    static let bufferSize: Int32 = 1 << 18

    private let reader: any RandomAccessReading
    private let size: Int64
    private var position: Int64 = 0
    /// libavformat reports a failed read as a bare code. The reader's own error waits here for
    /// the demuxer to rethrow.
    private var failure: (any Error)?

    var hasFailed: Bool { failure != nil }

    /// Hands over the reader's error and forgets it, so the next read gets a fresh try.
    func takeFailure() -> (any Error)? {
        defer { failure = nil }
        return failure
    }

    init(reader: any RandomAccessReading, size: UInt64) {
        self.reader = reader
        self.size = Int64(clamping: size)
    }

    /// The caller frees it with `Self.free`. The context holds an unretained pointer to `self`,
    /// so `self` must outlive it.
    func makeContext() -> UnsafeMutablePointer<AVIOContext>? {
        guard let buffer = av_malloc(Int(Self.bufferSize)) else { return nil }
        let context = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), Self.bufferSize, 0,
            Unmanaged.passUnretained(self).toOpaque(),
            { opaque, buffer, length in
                guard let opaque, let buffer else { return Code.ioError }
                return Unmanaged<DemuxerSource>.fromOpaque(opaque).takeUnretainedValue()
                    .read(into: buffer, length: Int(length))
            },
            nil,
            { opaque, offset, whence in
                guard let opaque else { return Int64(Code.ioError) }
                return Unmanaged<DemuxerSource>.fromOpaque(opaque).takeUnretainedValue()
                    .seek(to: offset, whence: whence)
            })
        if context == nil { av_free(buffer) }
        return context
    }

    static func free(_ context: UnsafeMutablePointer<AVIOContext>?) {
        guard let context else { return }
        // libavformat may have swapped the buffer for a larger one, so the current one is freed.
        av_freep(&context.pointee.buffer)
        var freed: UnsafeMutablePointer<AVIOContext>? = context
        avio_context_free(&freed)
    }

    private func read(into buffer: UnsafeMutablePointer<UInt8>, length: Int) -> Int32 {
        guard failure == nil else { return Code.ioError }
        guard position < size, length > 0 else { return Code.endOfFile }
        switch blockingRead(offset: UInt64(position), length: length) {
        case .success(let data) where data.isEmpty:
            return Code.endOfFile
        case .success(let data):
            data.copyBytes(to: buffer, count: data.count)
            position += Int64(data.count)
            return Int32(data.count)
        case .failure(let error):
            failure = error
            return Code.ioError
        }
    }

    private func seek(to offset: Int64, whence: Int32) -> Int64 {
        if whence & AVSEEK_SIZE != 0 { return size }
        // libavformat resolves relative seeks itself and only ever asks for an absolute one.
        guard whence & ~AVSEEK_FORCE == SEEK_SET else { return Int64(Code.ioError) }
        position = offset
        return position
    }

    private func blockingRead(offset: UInt64, length: Int) -> Result<Data, any Error> {
        let answer = Mutex<Result<Data, any Error>>(.success(Data()))
        let answered = DispatchSemaphore(value: 0)
        Task { [reader] in
            let result: Result<Data, any Error>
            do {
                result = .success(try await reader.read(offset: offset, length: length))
            } catch {
                result = .failure(error)
            }
            answer.withLock { $0 = result }
            answered.signal()
        }
        answered.wait()
        return answer.withLock { $0 }
    }

    /// The `AVERROR` macros do not import into Swift.
    enum Code {
        static let ioError = -EIO
        /// `FFERRTAG('E', 'O', 'F', ' ')`, negated.
        static let endOfFile: Int32 = -0x2046_4F45
    }
}
