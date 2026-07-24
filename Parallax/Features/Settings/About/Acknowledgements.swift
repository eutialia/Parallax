import Foundation

/// A license text bundled as a plain-text resource under `Resources/Licenses/`. The raw value is the
/// resource's base name; the texts are verbatim upstream LICENSE files (copyright lines included), so
/// the MIT/Apache "text must accompany redistributions" terms are met by the app binary itself.
enum LicenseDoc: String, Hashable {
    case gpl3 = "gpl-3.0"
    case lgpl21 = "lgpl-2.1"
    case apache2 = "apache-2.0"
    case mitNuke = "mit-nuke"
    case mitGet = "mit-get"
    case ccBySa4 = "cc-by-sa-4.0"

    var displayName: String {
        switch self {
        case .gpl3: "GNU General Public License v3"
        case .lgpl21: "GNU Lesser General Public License v2.1"
        case .apache2: "Apache License 2.0"
        case .mitNuke, .mitGet: "MIT License"
        case .ccBySa4: "Creative Commons BY-SA 4.0"
        }
    }

    /// The bundled license text, loaded once per document (SwiftUI can re-evaluate a body often,
    /// and GPLv3 is 35 KB). Missing resource = packaging bug; surfaced as visible text rather
    /// than a crash so a broken build still renders the screen.
    @MainActor var text: String {
        if let cached = Self.textCache[self] { return cached }
        let loaded: String
        if let url = Bundle.main.url(forResource: rawValue, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            loaded = text
        } else {
            loaded = "License text \(rawValue).txt is missing from this build."
        }
        Self.textCache[self] = loaded
        return loaded
    }

    @MainActor private static var textCache: [LicenseDoc: String] = [:]
}

/// One credited third-party component on the About screen. Mirrors CREDITS.md; the CI drift check
/// (`scripts/check-acknowledgements.sh`) fails when a `Package.resolved` identity appears in the
/// dependency graph without being listed in an entry's `packageIdentities` here.
struct Acknowledgement: Identifiable, Hashable {
    let name: String
    /// `Package.resolved` identities this entry covers (empty for non-SPM credits like artwork).
    let packageIdentities: [String]
    let role: String
    /// Display label for the license; kept separate from `license` because jellyfin-sdk-swift has
    /// no upstream license file to bundle.
    let licenseName: String
    let license: LicenseDoc?
    /// Upstream home, shown as plain text (tvOS has no browser, so nothing here is a tappable link).
    let url: String
    var id: String { name }

    /// Parallax's own entry — drives the About screen's License row, so the GPL text screen
    /// carries the same attribution header as every third-party one.
    static let parallax = Acknowledgement(
        name: "Parallax",
        packageIdentities: [],
        role: "This app",
        licenseName: "GPLv3",
        license: .gpl3,
        url: "github.com/eutialia/Parallax"
    )

    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "jellyfin-sdk-swift",
            packageIdentities: ["jellyfin-sdk-swift"],
            role: "Jellyfin API client",
            licenseName: "No license declared upstream",
            license: nil,
            url: "github.com/jellyfin/jellyfin-sdk-swift"
        ),
        Acknowledgement(
            name: "Get",
            packageIdentities: ["get"],
            role: "HTTP transport, via the Jellyfin SDK",
            licenseName: "MIT",
            license: .mitGet,
            url: "github.com/kean/Get"
        ),
        Acknowledgement(
            name: "Nuke",
            packageIdentities: ["nuke"],
            role: "Image loading & caching",
            licenseName: "MIT",
            license: .mitNuke,
            url: "github.com/kean/Nuke"
        ),
        Acknowledgement(
            name: "AMSMB2",
            packageIdentities: ["amsmb2"],
            role: "SMB2/3 client, wraps libsmb2",
            licenseName: "LGPL-2.1",
            license: .lgpl21,
            url: "github.com/amosavian/AMSMB2"
        ),
        Acknowledgement(
            name: "SwiftNIO",
            packageIdentities: [
                "swift-nio", "swift-nio-transport-services",
                "swift-atomics", "swift-collections", "swift-system",
            ],
            role: "Local HTTP bridge for SMB playback",
            licenseName: "Apache-2.0",
            license: .apache2,
            url: "github.com/apple/swift-nio"
        ),
        Acknowledgement(
            name: "VLCKit",
            packageIdentities: ["vlckit-spm"],
            role: "Alternate playback engine, © VideoLAN",
            licenseName: "LGPL-2.1",
            license: .lgpl21,
            url: "code.videolan.org/videolan/VLCKit"
        ),
        Acknowledgement(
            name: "Jellyfin icon",
            packageIdentities: [],
            role: "“Works with Jellyfin” glyph, © Jellyfin contributors, used unmodified",
            licenseName: "CC-BY-SA-4.0",
            license: .ccBySa4,
            url: "github.com/jellyfin/jellyfin-ux"
        ),
    ]
}
