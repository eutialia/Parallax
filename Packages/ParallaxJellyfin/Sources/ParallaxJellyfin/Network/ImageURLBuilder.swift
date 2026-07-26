import Foundation
import ParallaxCore

public enum ImageURLBuilder {
    /// JPEG quality asked of the server's image scaler. High enough that artwork edges stay clean
    /// on a Retina tile, low enough that a wall of posters isn't pulling full-quality JPEGs.
    public static let defaultQuality = 90

    public static func url(
        serverURL: URL,
        ref: ImageRef,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int = defaultQuality
    ) -> URL? {
        guard let encodedID = percentEncodedSegment(ref.itemID.rawValue) else { return nil }
        var path = "/Items/\(encodedID)/Images/\(ref.kind.pathSegment)"
        if case .backdrop(let index) = ref.kind {
            path += "/\(index)"
        }
        return makeURL(serverURL: serverURL, path: path, tag: ref.tag.rawValue,
                       maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
    }

    /// Everything a single path SEGMENT may carry unescaped. `/` is subtracted from the
    /// path-allowed set on purpose: an id containing a slash has to stay ONE segment, or it would
    /// silently address a different item.
    private static let segmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    /// Percent-encodes an item ID for path interpolation. IDs are unconstrained
    /// `String` wrappers, so a stray "/" or "?" would corrupt the URL. Jellyfin uses UUIDs
    /// in practice; this is defense-in-depth.
    ///
    /// The result is already escaped, so it must be assembled through
    /// `URLComponents.percentEncodedPath` — see `makeURL`.
    private static func percentEncodedSegment(_ id: String) -> String? {
        id.addingPercentEncoding(withAllowedCharacters: segmentAllowed)
    }

    /// Appends `path` to the server URL (collapsing a trailing slash) and attaches the
    /// shared `tag`/`quality`/size query. One assembly point for every image variant.
    ///
    /// `path` arrives already percent-encoded, so both sides of the join go through
    /// `percentEncodedPath`. Assigning to `path` instead would escape the `%` of every escape a
    /// second time and put `%253F` on the wire for an id's `?`.
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
        let prefix = components.percentEncodedPath
        components.percentEncodedPath = (prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix) + path

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
