import Foundation
import ParallaxCore

public enum ImageURLBuilder {
    public static func url(
        serverURL: URL,
        ref: ImageRef,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        guard let encodedID = percentEncoded(ref.itemID.rawValue) else { return nil }
        var path = "/Items/\(encodedID)/Images/\(ref.kind.pathSegment)"
        if case .backdrop(let index) = ref.kind {
            path += "/\(index)"
        }
        return makeURL(serverURL: serverURL, path: path, tag: ref.tag.rawValue,
                       maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
    }

    /// Percent-encodes an item ID for path interpolation. IDs are unconstrained
    /// `String` wrappers, so a stray "/" or "?" would corrupt the URL. Jellyfin uses UUIDs
    /// in practice; this is defense-in-depth.
    private static func percentEncoded(_ id: String) -> String? {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    /// Appends `path` to the server URL (collapsing a trailing slash) and attaches the
    /// shared `tag`/`quality`/size query. One assembly point for every image variant.
    private static func makeURL(
        serverURL: URL,
        path: String,
        tag: String,
        maxWidth: Int?,
        maxHeight: Int? = nil,
        quality: Int
    ) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path

        var items: [URLQueryItem] = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: String(quality)),
        ]
        if let maxWidth { items.append(URLQueryItem(name: "maxWidth", value: String(maxWidth))) }
        if let maxHeight { items.append(URLQueryItem(name: "maxHeight", value: String(maxHeight))) }
        components.queryItems = items
        return components.url
    }
}
