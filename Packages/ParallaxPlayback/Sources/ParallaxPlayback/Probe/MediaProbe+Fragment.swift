import Foundation

/// What a fragmented MP4's first fragment says of a track's samples. Its moov holds no
/// samples; each `moof` lists its own in the `trun`s of a `traf` per track.
extension MediaProbe {
    /// A sample a `trun` lists: how long it lasts, its size, where its bytes start, and its
    /// show time's offset from its decode time where the run gives one.
    struct FragmentSample {
        let duration: UInt32
        let size: UInt32
        let offset: UInt64
        let compositionOffset: Int32?
    }

    /// The samples of track `trackID` in `moof`, the whole box as read from file offset
    /// `moofOffset`, in decode order. Nil when the fragment holds no `traf` for the track or a
    /// box in it is cut short. A duration neither the `trun` nor the `tfhd` gives, left to the
    /// moov's `trex`, reads as 0, and no show times are judged on it.
    static func fragmentSamples(_ moof: Data, at moofOffset: UInt64, trackID: UInt32) -> [FragmentSample]? {
        guard let header = readBoxHeader(moof, at: 0, limit: moof.count), header.type == "moof" else { return nil }
        for traf in allChildBoxes(moof, type: "traf", in: header.contentStart..<header.boxEnd) {
            let content = traf.contentStart..<traf.boxEnd
            guard let tfhd = firstChildBox(moof, type: "tfhd", in: content),
                  let track = TrackFragmentHeader(moof, box: tfhd, moofOffset: moofOffset)
            else { return nil }
            guard track.trackID == trackID else { continue }
            var samples: [FragmentSample] = []
            var dataOffset = track.baseOffset
            for trun in allChildBoxes(moof, type: "trun", in: content) {
                guard let run = runSamples(moof, box: trun, track: track, continuingAt: dataOffset) else { return nil }
                samples += run
                dataOffset = run.last.map { $0.offset &+ UInt64($0.size) } ?? dataOffset
            }
            return samples
        }
        return nil
    }

    /// `tfhd`: the track, where its data is counted from, and the defaults for its samples.
    private struct TrackFragmentHeader {
        let trackID: UInt32
        let baseOffset: UInt64
        let duration: UInt32
        let size: UInt32

        init?(_ data: Data, box: BoxHeader, moofOffset: UInt64) {
            var reader = FieldReader(data: data, at: box.contentStart, end: box.boxEnd)
            guard let flags = reader.uint32().map({ $0 & 0xFF_FFFF }), let trackID = reader.uint32() else { return nil }
            // An explicit base, else the moof's own start: ffmpeg's default-base-is-moof, and
            // where the first traf of any fragment counts from.
            var base = moofOffset
            if flags & 0x01 != 0 {
                guard let high = reader.uint32(), let low = reader.uint32() else { return nil }
                base = UInt64(high) << 32 | UInt64(low)
            }
            if flags & 0x02 != 0, reader.uint32() == nil { return nil }
            var duration: UInt32 = 0
            if flags & 0x08 != 0 {
                guard let value = reader.uint32() else { return nil }
                duration = value
            }
            var size: UInt32 = 0
            if flags & 0x10 != 0 {
                guard let value = reader.uint32() else { return nil }
                size = value
            }
            self.trackID = trackID
            baseOffset = base
            self.duration = duration
            self.size = size
        }
    }

    /// One `trun`'s samples, their bytes contiguous from its data offset, or from where the run
    /// before it ended when it gives none.
    private static func runSamples(
        _ data: Data, box: BoxHeader, track: TrackFragmentHeader, continuingAt previousEnd: UInt64
    ) -> [FragmentSample]? {
        var reader = FieldReader(data: data, at: box.contentStart, end: box.boxEnd)
        guard let flags = reader.uint32().map({ $0 & 0xFF_FFFF }), let count = reader.uint32() else { return nil }
        var offset = previousEnd
        if flags & 0x001 != 0 {
            guard let relative = reader.uint32() else { return nil }
            guard let base = Int64(exactly: track.baseOffset) else { return nil }
            let (start, overflow) = base.addingReportingOverflow(Int64(Int32(bitPattern: relative)))
            guard !overflow, start >= 0 else { return nil }
            offset = UInt64(start)
        }
        if flags & 0x004 != 0, reader.uint32() == nil { return nil }
        let fields = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count
        // A count the box could not hold is not read. A run of no per-sample fields is bounded
        // by nothing in the box; a fragment of minutes at 60 fps still holds fewer than this.
        guard Int(count) <= (fields == 0 ? 65_536 : reader.remaining / (4 * fields)) else { return nil }

        var samples: [FragmentSample] = []
        samples.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let duration = flags & 0x100 != 0 ? reader.uint32() : track.duration,
                  let size = flags & 0x200 != 0 ? reader.uint32() : track.size,
                  flags & 0x400 == 0 || reader.uint32() != nil
            else { return nil }
            let composition: Int32?
            if flags & 0x800 != 0 {
                guard let raw = reader.uint32() else { return nil }
                composition = Int32(bitPattern: raw)
            } else {
                composition = nil
            }
            samples.append(FragmentSample(duration: duration, size: size, offset: offset, compositionOffset: composition))
            let (next, overflow) = offset.addingReportingOverflow(UInt64(size))
            guard !overflow else { return nil }
            offset = next
        }
        return samples
    }

    /// Big-endian 32-bit fields read in turn from `data[at..<end]`.
    private struct FieldReader {
        let data: Data
        var at: Int
        let end: Int

        var remaining: Int { max(0, min(end, data.count) - at) }

        mutating func uint32() -> UInt32? {
            guard remaining >= 4 else { return nil }
            defer { at += 4 }
            return readUInt32BE(data, at: at)
        }
    }
}
