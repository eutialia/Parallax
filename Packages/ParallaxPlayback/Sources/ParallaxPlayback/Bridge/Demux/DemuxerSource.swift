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
    private static let blockSize = Int(bufferSize)
    /// 64 MB. A segment and the one before it took 13 to 21 MB together in the 4K files measured.
    private static let blocksKept = 256
    /// 2 MB, what direct play asks for at a time. Each request to an SMB share opens and closes
    /// the file, so a segment read 256 KB at a time took longer than AVPlayer waits for one.
    private static let blocksPerOrderedRead = 8

    private let reader: any RandomAccessReading
    private let size: Int64
    private var position: Int64 = 0
    /// The parts of the file read last, oldest first. A segment's read starts an index entry
    /// before its own, and each audio segment reads what its video segment read, so without
    /// these a file is fetched four times over as it plays.
    private var blocks: [(index: Int64, data: Data)] = []
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
        let index = position / Int64(Self.blockSize)
        let start = Int(position - index * Int64(Self.blockSize))
        // A reader may answer with less than was asked. The block then stops before `position`,
        // and what is there is still to be read.
        let read = block(index).flatMap { block in
            start < block.count
                ? .success(block.dropFirst(start).prefix(length))
                : blockingRead(offset: UInt64(position), length: length)
        }
        switch read {
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

    private func block(_ index: Int64) -> Result<Data, any Error> {
        if let kept = blocks.first(where: { $0.index == index }) {
            blocks = blocks.filter { $0.index != index } + [kept]
            return .success(kept.data)
        }
        let offset = index * Int64(Self.blockSize)
        let inOrder = blocks.contains { $0.index == index - 1 }
        let nextKept = blocks.map(\.index).filter { $0 > index }.min() ?? .max
        let asked = Self.blockSize * (inOrder ? Int(min(Int64(Self.blocksPerOrderedRead), nextKept - index)) : 1)
        return blockingRead(offset: UInt64(offset), length: asked).map { data in
            let read = stride(from: 0, to: data.count, by: Self.blockSize).map { start in
                (index: index + Int64(start / Self.blockSize),
                 data: data.subdata(in: (data.startIndex + start)..<(data.startIndex + min(start + Self.blockSize, data.count))))
            }
            // A block that came back short is kept only where the file ends: elsewhere the next
            // read asks for it again.
            let whole = read.filter { Int64($0.data.count) == min(Int64(Self.blockSize), size - $0.index * Int64(Self.blockSize)) }
            let replaced = Set(whole.map(\.index))
            blocks = Array((blocks.filter { !replaced.contains($0.index) } + whole).suffix(Self.blocksKept))
            return read.first?.data ?? Data()
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
