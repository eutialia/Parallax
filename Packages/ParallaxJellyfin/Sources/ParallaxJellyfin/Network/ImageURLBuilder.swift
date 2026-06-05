import Foundation

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

    /// A user's Jellyfin profile image. It lives under `/Users/{id}` — a different root
    /// from item images — so it can't be expressed as an `ImageRef` and routed through
    /// `url(ref:)`; it gets its own entry point sharing the same query assembly.
    public static func userImageURL(
        serverURL: URL,
        userID: String,
        tag: String,
        maxWidth: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        guard let encodedID = percentEncoded(userID) else { return nil }
        return makeURL(serverURL: serverURL, path: "/Users/\(encodedID)/Images/Primary",
                       tag: tag, maxWidth: maxWidth, quality: quality)
    }

    /// Percent-encodes an item/user ID for path interpolation. IDs are unconstrained
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
