import Foundation
import os
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

/// One candidate-selection row: the collected attachments plus which name (if any) should win.
struct CoverArtSelectionCase: Sendable, CustomTestStringConvertible {
    let name: String
    let candidates: [MatroskaCoverArt.AttachmentCandidate]
    let expectedName: String?
    var testDescription: String { name }
}

private let selectionCases: [CoverArtSelectionCase] = [
    CoverArtSelectionCase(
        name: "cover.jpg preferred over poster.png",
        candidates: [
            .init(name: "poster.png", mimeType: "image/png", fileDataOffset: 0, fileDataSize: 10),
            .init(name: "cover.jpg", mimeType: "image/jpeg", fileDataOffset: 10, fileDataSize: 20),
        ],
        expectedName: "cover.jpg"
    ),
    CoverArtSelectionCase(
        name: "cover_land.jpg preferred over small_cover / small_cover_land / bare art",
        candidates: [
            .init(name: "art.png", mimeType: "image/png", fileDataOffset: 0, fileDataSize: 10),
            .init(name: "small_cover_land.png", mimeType: "image/png", fileDataOffset: 10, fileDataSize: 15),
            .init(name: "small_cover.png", mimeType: "image/png", fileDataOffset: 25, fileDataSize: 20),
            .init(name: "cover_land.jpg", mimeType: "image/jpeg", fileDataOffset: 45, fileDataSize: 30),
        ],
        expectedName: "cover_land.jpg"
    ),
    CoverArtSelectionCase(
        name: "small_cover.png preferred when no cover.* / cover_land.*",
        candidates: [
            .init(name: "art.png", mimeType: "image/png", fileDataOffset: 0, fileDataSize: 10),
            .init(name: "small_cover.png", mimeType: "image/png", fileDataOffset: 10, fileDataSize: 20),
        ],
        expectedName: "small_cover.png"
    ),
    CoverArtSelectionCase(
        name: "small_cover_land.png preferred over bare art when no higher tier",
        candidates: [
            .init(name: "art.png", mimeType: "image/png", fileDataOffset: 0, fileDataSize: 10),
            .init(name: "small_cover_land.png", mimeType: "image/png", fileDataOffset: 10, fileDataSize: 20),
        ],
        expectedName: "small_cover_land.png"
    ),
    CoverArtSelectionCase(
        name: "non-image cover.txt skipped",
        candidates: [
            .init(name: "cover.txt", mimeType: "text/plain", fileDataOffset: 0, fileDataSize: 10),
            .init(name: "art.png", mimeType: "image/png", fileDataOffset: 10, fileDataSize: 20),
        ],
        expectedName: "art.png"
    ),
    CoverArtSelectionCase(
        name: "oversize cover.jpg skipped in favor of smaller image",
        candidates: [
            .init(
                name: "cover.jpg", mimeType: "image/jpeg",
                fileDataOffset: 0,
                fileDataSize: MatroskaCoverArt.maxAttachmentBytes + 1
            ),
            .init(name: "poster.png", mimeType: "image/png", fileDataOffset: 100, fileDataSize: 20),
        ],
        expectedName: "poster.png"
    ),
    CoverArtSelectionCase(
        name: "only oversize image → nil",
        candidates: [
            .init(
                name: "cover.jpg", mimeType: "image/jpeg",
                fileDataOffset: 0,
                fileDataSize: MatroskaCoverArt.maxAttachmentBytes + 1
            ),
        ],
        expectedName: nil
    ),
    CoverArtSelectionCase(
        name: "first remaining image when no cover/small_cover tiers",
        candidates: [
            .init(name: "fanart.png", mimeType: "image/png", fileDataOffset: 0, fileDataSize: 10),
            .init(name: "backdrop.jpg", mimeType: "image/jpeg", fileDataOffset: 10, fileDataSize: 20),
        ],
        expectedName: "fanart.png"
    ),
]

/// Counts `read(offset:length:)` calls while delegating to an in-memory reader.
/// `@unchecked Sendable`: the only mutable state is the counter, guarded by
/// `OSAllocatedUnfairLock` (async-safe; `NSLock` is unavailable from async contexts).
private final class CountingRandomAccessReader: RandomAccessReading, @unchecked Sendable {
    private let inner: InMemoryRandomAccessReader
    private let readCountLock = OSAllocatedUnfairLock(initialState: 0)

    var readCount: Int {
        readCountLock.withLock { $0 }
    }

    init(data: Data) {
        self.inner = InMemoryRandomAccessReader(data: data)
    }

    var fileSize: UInt64 {
        get async throws { try await inner.fileSize }
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        readCountLock.withLock { $0 += 1 }
        return try await inner.read(offset: offset, length: length)
    }
}

@Suite("MatroskaCoverArt")
struct MatroskaCoverArtTests {
    private typealias F = EBMLFixtures

    private func extract(_ data: Data) async throws -> Data? {
        try await MatroskaCoverArt.extract(InMemoryRandomAccessReader(data: data))
    }

    private let coverBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) // pretend JPEG header
    private let posterBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]) // pretend PNG header

    // MARK: - Strategy A (SeekHead)

    @Test("SeekHead jump finds Attachments placed after Cluster stubs")
    func seekHeadAfterClusters() async throws {
        // pieces: 0 SeekHead→Attachments(3), 1 tracks, 2 cluster, 3 attachments
        let data = F.mkv(pieces: [
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 3, id: F.attachmentsID, idLength: 4),
            ]),
            .tracksStub,
            .cluster(payloadBytes: 64),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        let result = try await extract(data)
        #expect(result == coverBytes)
    }

    @Test("second-level SeekHead hop finds Attachments")
    func secondSeekHeadHop() async throws {
        // 0: SeekHead → piece 2 (second SeekHead)
        // 1: cluster (between the two SeekHeads)
        // 2: SeekHead → piece 3 (Attachments)
        // 3: attachments
        let data = F.mkv(pieces: [
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 2, id: F.seekHeadID, idLength: 4),
            ]),
            .cluster(payloadBytes: 48),
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 3, id: F.attachmentsID, idLength: 4),
            ]),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        let result = try await extract(data)
        #expect(result == coverBytes)
    }

    @Test("SeekHead cycle with no Attachments is authoritative — Strategy B must not run")
    func seekHeadCycleNoAttachmentsSkipsStrategyB() async throws {
        // Complete SeekHead chain with no Attachments entry anywhere (second hop
        // points back at the first SeekHead). Attachments sits before Cluster so
        // Strategy B WOULD find it if Finding 4b's gate regressed.
        let data = F.mkv(pieces: [
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 1, id: F.seekHeadID, idLength: 4),
            ]),
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 0, id: F.seekHeadID, idLength: 4),
            ]),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
            .cluster(payloadBytes: 32),
        ])
        let result = try await extract(data)
        #expect(result == nil)
    }

    @Test("hostile SeekPosition of UInt64.max returns nil without trapping")
    func hostileSeekPositionMaxDoesNotTrap() async throws {
        // Intentionally bogus 8-byte SeekPosition — overflow / out-of-range path.
        // Cluster before Attachments so Strategy B cannot salvage a cover either.
        let hostileSeekHead = F.seekHead([
            F.seek(
                targetID: F.attachmentsID,
                targetIDLength: 4,
                position: .max,
                positionWidth: 8
            ),
        ])
        let data = F.mkv(pieces: [
            .raw(hostileSeekHead),
            .cluster(payloadBytes: 32),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        let result = try await extract(data)
        #expect(result == nil)
    }

    // MARK: - Strategy B (no SeekHead)

    @Test("no SeekHead: Attachments before Cluster is found")
    func noSeekHeadBeforeCluster() async throws {
        let data = F.mkv(pieces: [
            .tracksStub,
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
            .cluster(payloadBytes: 32),
        ])
        let result = try await extract(data)
        #expect(result == coverBytes)
    }

    @Test("no SeekHead: Attachments after Cluster is unreachable")
    func noSeekHeadAfterCluster() async throws {
        let data = F.mkv(pieces: [
            .tracksStub,
            .cluster(payloadBytes: 32),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        let result = try await extract(data)
        #expect(result == nil)
    }

    // MARK: - Guards

    @Test("non-EBML magic at offset 0 returns nil")
    func nonEBMLMagic() async throws {
        // MP4 ftyp-shaped header — same spirit as MediaProbe's sniffs.
        let ftyp = ISOBMFFFixtures.ftyp()
        let result = try await extract(ftyp)
        #expect(result == nil)

        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        let result2 = try await extract(garbage)
        #expect(result2 == nil)
    }

    @Test("unknown-size Segment still walks via SeekHead")
    func unknownSizeSegmentSeekHead() async throws {
        let data = F.mkv(unknownSizeSegment: true, pieces: [
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 2, id: F.attachmentsID, idLength: 4),
            ]),
            .cluster(payloadBytes: 16),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        let result = try await extract(data)
        #expect(result == coverBytes)
    }

    @Test("unknown-size Segment still walks via Strategy B")
    func unknownSizeSegmentLinear() async throws {
        let data = F.mkv(unknownSizeSegment: true, pieces: [
            .tracksStub,
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
            .cluster(payloadBytes: 16),
        ])
        let result = try await extract(data)
        #expect(result == coverBytes)
    }

    // MARK: - Candidate selection

    @Test("candidate selection", arguments: selectionCases)
    func candidateSelection(_ c: CoverArtSelectionCase) {
        let winner = MatroskaCoverArt.selectCoverArt(from: c.candidates)
        #expect(winner?.name == c.expectedName)
    }

    @Test("extract applies selection: cover.jpg wins over poster.png in file order")
    func extractPrefersCoverName() async throws {
        let data = F.mkv(pieces: [
            .attachments(files: [
                F.AttachmentFile(name: "poster.png", mimeType: "image/png", fileData: posterBytes),
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        let result = try await extract(data)
        #expect(result == coverBytes)
    }

    // MARK: - Read-count budget (buffered Attachments scan)

    @Test("attachment scan read count stays flat as attachment count grows")
    func attachmentScanReadCountDoesNotScaleWithCount() async throws {
        // Larger than one scan chunk on purpose: chunk-exceeding payloads force one window
        // refill per attachment, which is what exhausted the byte budget and silently missed
        // a late cover behind 16+ real-sized fonts. Tiny payloads can't regress that axis.
        let fontPayload = Data(repeating: 0xAB, count: 20 * 1024)

        func fixture(attachmentCount: Int) -> Data {
            var files: [F.AttachmentFile] = (0..<(attachmentCount - 1)).map { i in
                F.AttachmentFile(
                    name: "font\(i).ttf",
                    mimeType: "application/x-truetype-font",
                    fileData: fontPayload
                )
            }
            // cover.jpg last — forces a full metadata walk before early-exit commits.
            files.append(
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes)
            )
            return F.mkv(pieces: [
                .seekHead(targets: [
                    F.SeekTarget(pieceIndex: 1, id: F.attachmentsID, idLength: 4),
                ]),
                .attachments(files: files),
            ])
        }

        let oneData = fixture(attachmentCount: 1)
        let oneReader = CountingRandomAccessReader(data: oneData)
        let oneResult = try await MatroskaCoverArt.extract(oneReader)
        #expect(oneResult == coverBytes)
        let oneCount = oneReader.readCount

        let manyData = fixture(attachmentCount: 30)
        let manyReader = CountingRandomAccessReader(data: manyData)
        let manyResult = try await MatroskaCoverArt.extract(manyReader)
        #expect(manyResult == coverBytes)
        let manyCount = manyReader.readCount

        // Regression ceilings, both axes: a chunk-exceeding payload costs at most ONE window
        // refill per attachment (never the 6-reads-per-attachment field walk this replaced),
        // and — the axis that actually broke once — the late cover must still be FOUND, not
        // starved out by a byte budget that bills each refill at the full chunk size.
        #expect(oneCount <= 12)
        #expect(manyCount <= 45, "well under the 64-read cap; ~1 refill per large attachment")
        #expect(manyCount <= oneCount + 32)
    }

    // MARK: - Fixture golden bytes

    @Test("EBMLFixtures.element emits hand-computed VINT bytes for a 2-byte ID + 1-byte payload")
    func elementGoldenBytes() {
        // 0x4286 (EBMLVersion) → 0x42 0x86; size 1 at 1-byte width → marker 0x80 | 0x01 = 0x81.
        #expect(
            F.element(id: 0x4286, idLength: 2, payload: Data([0x01]))
                == Data([0x42, 0x86, 0x81, 0x01])
        )
    }

    // MARK: - Corruption / truncation

    @Test("truncated mid-walk returns nil without throwing")
    func truncatedMidWalk() async throws {
        // Build a full valid file then chop it inside the Attachments region.
        let full = F.mkv(pieces: [
            .seekHead(targets: [
                F.SeekTarget(pieceIndex: 1, id: F.attachmentsID, idLength: 4),
            ]),
            .attachments(files: [
                F.AttachmentFile(name: "cover.jpg", mimeType: "image/jpeg", fileData: coverBytes),
            ]),
        ])
        // Keep only the front half so SeekHead/Attachments headers are incomplete.
        let truncated = full.prefix(max(full.count / 2, 20))
        let result = try await extract(Data(truncated))
        #expect(result == nil)
    }

    @Test("corrupt 0x00 VINT mid-walk returns nil without looping")
    func corruptZeroVINT() async throws {
        // Valid EBML + Segment header, then a 0x00 byte where the next element ID should be.
        var data = F.ebmlHeader()
        // Segment with a known size large enough that the walker tries to read children.
        var segmentPayload = Data([0x00]) // invalid VINT at first child
        segmentPayload.append(Data(count: 64))
        data.append(F.element(id: F.segmentID, idLength: 4, payload: segmentPayload))
        let result = try await extract(data)
        #expect(result == nil)
    }
}
