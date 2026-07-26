import Foundation
import Get
import ParallaxCore

/// Validates every HTTP response a session's `JellyfinClient` receives, and reports the one
/// status that can't be recovered from by retrying: **401, the server rejecting our access token**.
///
/// This is the single chokepoint for that signal. Jellyfin access tokens are revoked
/// server-side for reasons the app never sees — an admin invalidating devices, a server
/// rebuild, or (the case that surfaced this) the public demo server's nightly reset. The
/// persisted row and its Keychain token both survive, so the app kept presenting the server as
/// connected while every request 401'd: libraries silently empty, no error, no way back except
/// removing and re-adding the server by hand. Reporting the rejection lets the store drop that
/// session, which surfaces the server as signed-out with a "Sign In Again" prompt.
///
/// Installed as the `JellyfinClient`'s delegate, so it sees browse, search, detail, favourite,
/// and playback traffic alike — a token is dead for all of them at once, and a rule that held
/// for only some request kinds would rot the first time a new endpoint was added. The *auth*
/// client deliberately has no validator: a 401 while signing in is a wrong password, not a dead
/// token, and must not sign the user out of anything.
///
/// - Note: `JellyfinClient` consults its delegate INSTEAD of its built-in 2xx check (see
///   `PassthroughAPIClientDelegate`), so this type owns status validation outright rather than
///   adding to it. It throws `AppError` directly, which `ErrorMapping` passes through untouched.
final class JellyfinResponseValidator: APIClientDelegate, Sendable {
    private let serverID: ServerID
    private let onTokenRejected: @Sendable (ServerID) -> Void

    init(serverID: ServerID, onTokenRejected: @escaping @Sendable (ServerID) -> Void) {
        self.serverID = serverID
        self.onTokenRejected = onTokenRejected
    }

    func client(
        _ client: APIClient,
        validateResponse response: HTTPURLResponse,
        data: Data,
        task: URLSessionTask
    ) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }

        guard response.statusCode == 401 else {
            throw AppError.server(statusCode: response.statusCode, message: nil)
        }

        // Not every 401 is Jellyfin rejecting our token. A Jellyfin behind an auth gateway
        // (Authelia, Authentik, a reverse proxy with basic auth) answers 401 for ITS OWN missing
        // credential, with the Jellyfin token perfectly intact — and signing the user out there
        // would destroy a working token to fix a problem it had nothing to do with, then send them
        // to a sign-in screen that 401s too.
        //
        // `WWW-Authenticate` separates the two, and it's a spec guarantee rather than a heuristic:
        // RFC 7235 §3.1 REQUIRES a server issuing a 401 challenge to send it. Jellyfin doesn't
        // (verified against a live server: a garbage token returns a bare 401 with no challenge
        // header), because its 401 isn't an HTTP-auth challenge at all. So a challenge present
        // means something in FRONT of Jellyfin is asking — leave the session alone and report a
        // plain server error.
        guard response.value(forHTTPHeaderField: "WWW-Authenticate") == nil else {
            Log.network.error("Jellyfin \(self.serverID.rawValue): HTTP 401 carrying an auth challenge — an upstream gateway, not a rejected token; session kept")
            throw AppError.server(statusCode: 401, message: nil)
        }

        // Fire-and-forget: the handler is expected to be cheap and idempotent (a burst of
        // concurrent requests all 401 together, so it WILL be called several times for one dead
        // token). Deduplication belongs to the consumer, which can see whether the session is
        // already gone; doing it here would need per-server state that no one clears on re-login.
        Log.network.error("Jellyfin \(self.serverID.rawValue): access token rejected (HTTP 401)")
        onTokenRejected(serverID)
        throw AppError.auth(.tokenInvalidated)
    }
}
