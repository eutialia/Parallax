/// The container libavformat read a file as. It holds what differs between libavformat's
/// readers and cannot be seen in the file. What a file's index holds and what its streams are
/// coded in are read from the file, never from this.
enum BridgedContainer {
    case matroska
    /// MPEG-TS, and M2TS with its four bytes ahead of each packet.
    case transportStream
    case flashVideo
    case avi

    /// `formatName` is libavformat's own: "matroska,webm", "mpegts". Nil for a reader whose span
    /// reads are not proven:
    /// - The MPEG program stream reader. A byte seek to a keyframe's position gave other packets
    ///   than a read of the whole file did (4 of 5 keyframes of a synthetic file), and its
    ///   index lists every packet as a keyframe.
    /// - The ASF reader. It keeps its place inside a data packet across a byte seek, and a
    ///   seek by time landed one keyframe early (24 of 24 keyframes of two synthetic files).
    init?(formatName: String) {
        if formatName.contains("matroska") {
            self = .matroska
        } else if formatName == "mpegts" {
            self = .transportStream
        } else if formatName == "flv" {
            self = .flashVideo
        } else if formatName == "avi" {
            self = .avi
        } else {
            return nil
        }
    }

    /// Where a read may start.
    enum SpanStart {
        /// Only where the file's own index points. A file with no index has no span.
        case indexEntry
        /// At any packet: a read from any byte finds the next one. The file has no index, so
        /// its keyframes are listed by reading it, whole or in samples.
        case packet
        /// Only at a packet a read from the file's start came to. The file has no index, so
        /// its keyframes are listed by reading all of it.
        case packetReadFromTheStart
    }

    var spanStart: SpanStart {
        switch self {
        // A byte seek resyncs at the next cluster, and a packet's position is not one.
        // AVI: `idx1` lists every frame.
        case .matroska, .avi: .indexEntry
        // A byte seek to each keyframe's position gave the packets a read of the whole file
        // did, from that keyframe on, in every stream: 72 keyframes of four synthetic files.
        // libavformat's index of one is the packets its last seek by time read through, which
        // are not keyframes.
        case .transportStream: .packet
        // A byte seek to each keyframe's tag gave the packets a read of the whole file did (48
        // keyframes of two synthetic files). A tag has nothing to resync on, and the keyframe
        // list a file's metadata may hold is written by tools that get it wrong.
        case .flashVideo: .packetReadFromTheStart
        }
    }

    /// How a read is put at a listed keyframe.
    enum Seek {
        /// To the keyframe's position.
        case byte
        /// To the keyframe's time, through the file's index.
        case time
    }

    var seek: Seek {
        switch self {
        case .matroska, .transportStream, .flashVideo: .byte
        // The reader counts frames to time them and a byte seek leaves the count where it was:
        // none of 48 keyframes of two synthetic files came back at its own time. A seek by
        // time gave every one, and put the audio at its own packet for that time.
        case .avi: .time
        }
    }

    /// Whether a packet carries the time its picture is shown. Where it carries only the time
    /// it is decoded, that is the time it is shown for a stream that stores its pictures in
    /// the order they show.
    var storesPresentationTimes: Bool {
        switch self {
        case .matroska, .transportStream, .flashVideo: true
        case .avi: false
        }
    }

    /// How a read for a span's audio is placed.
    enum AudioPlacement {
        /// By the seek to the keyframe, which puts the audio at its own packet for that time.
        case bySeek
        /// Audio may be stored ahead of the keyframe it plays with, so a read starts before it.
        case before(AudioSearch)
    }

    /// Where before a keyframe a read can start.
    enum AudioSearch {
        /// At the cluster starts, the only places a read can begin.
        case matroskaClusters
        /// This many bytes before the keyframe, then twice that, and on.
        case bytesBefore(Int64)
        /// At the tag starts. Each is found from the tag after it, which is preceded by its
        /// size. The first look is this many bytes back, then twice that, and on.
        case flashVideoTags(Int64)
    }

    var audioPlacement: AudioPlacement {
        switch self {
        case .matroska: .before(.matroskaClusters)
        // A multiplexer sends video ahead of the audio it plays with, so a read from the
        // keyframe itself starts early enough: of 72 keyframes in four synthetic files none
        // had its audio stored before it. This is the first step back for a file that does.
        case .transportStream: .before(.bytesBefore(Self.wholePackets))
        // Tags are stored in the order they decode, as a transport stream's packets are.
        case .flashVideo: .before(.flashVideoTags(Self.wholePackets))
        case .avi: .bySeek
        }
    }

    /// 72 KB, a whole number of packets of 188 bytes and of a disc's 192, so a read that starts
    /// this far before a packet starts at one.
    private static let wholePackets: Int64 = 188 * 192 * 2

    /// The bytes libavformat may read to describe the streams.
    var analysisLimit: Int64 {
        switch self {
        // Most of libavformat's 5 MB is spent waiting for a subtitle stream to show a packet.
        // One megabyte gave the same codec, profile, reorder depth and frame rate on 74 real
        // files.
        case .matroska: 1_000_000
        // A recording starts part way through a keyframe interval, and the parameter sets come
        // with the next keyframe: at a disc's 40 Mbit/s one megabyte is a fifth of a second.
        // This is libavformat's own limit.
        case .transportStream: 5_000_000
        // libavformat's own limit.
        case .flashVideo, .avi: 5_000_000
        }
    }

    /// The time the file ends, in nanoseconds of its own time, from the duration libavformat
    /// reports for it and the time it says the file starts.
    func end(of duration: Int64, startingAt start: Int64, lastSegmentStart: Int64, firstKeyframe: Int64) -> Int64 {
        switch self {
        case .matroska:
            // Muxers disagree on Duration. ffmpeg writes the time the last sample ends; mkvmerge
            // writes the length, which is the same thing only for a file that starts at zero. A
            // value at or before the last segment's start can only be a length.
            duration > lastSegmentStart ? duration : firstKeyframe + duration
        case .flashVideo:
            // The file's metadata gives the time its last tag ends, counted from zero. A
            // capture that starts part way through a stream gives a length.
            duration > lastSegmentStart ? duration : firstKeyframe + duration
        case .transportStream, .avi:
            // libavformat measures from the first timestamp of the file to the last.
            start + duration
        }
    }
}
