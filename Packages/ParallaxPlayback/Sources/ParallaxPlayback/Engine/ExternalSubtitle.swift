import Foundation
import ParallaxCore

public struct ExternalSubtitle: Sendable, Hashable {
    public let url: URL
    public let format: SubtitleFormat
    public let languageCode: String?
    public let isForced: Bool

    public init(url: URL, format: SubtitleFormat, languageCode: String?, isForced: Bool) {
        self.url = url
        self.format = format
        self.languageCode = languageCode
        self.isForced = isForced
    }
}
