import Foundation

public enum ImageURLBuilder {
    public static func url(
        serverURL: URL,
        ref: ImageRef,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        // ItemID is an unconstrained String wrapper — percent-encode before
        // path interpolation so a stray "/" or "?" can't corrupt the URL.
        // Jellyfin uses UUIDs in practice; this is defense-in-depth.
        guard let encodedID = ref.itemID.rawValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        var path = "/Items/\(encodedID)/Images/\(ref.kind.pathSegment)"
        if case .backdrop(let index) = ref.kind {
            path += "/\(index)"
        }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path

        var items: [URLQueryItem] = [
            URLQueryItem(name: "tag", value: ref.tag.rawValue),
            URLQueryItem(name: "quality", value: String(quality)),
        ]
        if let maxWidth { items.append(URLQueryItem(name: "maxWidth", value: String(maxWidth))) }
        if let maxHeight { items.append(URLQueryItem(name: "maxHeight", value: String(maxHeight))) }
        components.queryItems = items
        return components.url
    }
}
