import Foundation
@testable import ParallaxFileBrowse

/// Directory-entry builders shared by every listing-driven suite (file source, browse sort,
/// subtitle resolver). Hand-writing `SMBDirectoryEntry(name:isDirectory:size:modifiedAt:)` per
/// fixture buried the one field a test actually varies under four that never change.
enum SMBEntry {

    /// A regular file. Non-zero `size` by default — zero is the "incomplete stub" case that
    /// `mediaFiles`/`browse` deliberately drop, so it has to be asked for explicitly.
    static func file(
        _ name: String,
        size: Int64 = 1,
        modified: Date? = nil,
        created: Date? = nil
    ) -> SMBDirectoryEntry {
        SMBDirectoryEntry(name: name, isDirectory: false, size: size, modifiedAt: modified, createdAt: created)
    }

    /// A subdirectory.
    static func dir(
        _ name: String,
        modified: Date? = nil,
        created: Date? = nil
    ) -> SMBDirectoryEntry {
        SMBDirectoryEntry(name: name, isDirectory: true, size: 0, modifiedAt: modified, createdAt: created)
    }
}

/// An `SMBFileSource` over a canned listing. `host`/`share`/`root` default to the values the URL
/// assertions expect; a test overrides only what it is about to assert on.
func makeFileSource(
    _ entries: [SMBDirectoryEntry],
    host: String = "nas",
    share: String = "Media",
    root: String = ""
) -> SMBFileSource {
    SMBFileSource(lister: FakeSMBLister(entries: entries), host: host, share: share, root: root)
}

/// An `SMBSubtitleResolver` over a canned listing, rooted where the resolver suites browse.
func makeSubtitleResolver(
    _ entries: [SMBDirectoryEntry],
    host: String = "nas",
    share: String = "Media",
    root: String = "Movies"
) -> SMBSubtitleResolver {
    SMBSubtitleResolver(lister: FakeSMBLister(entries: entries), host: host, share: share, root: root)
}
