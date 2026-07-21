import Foundation

/// The app's unified error type. Every subsystem maps its failures into one of these cases
/// so the UI can render a consistent `userMessage` and logs a `diagnosticDescription`
/// without leaking provider-specific detail.
public enum AppError: Error, Sendable {
    /// A transport-level URL loading failure (no connection, timeout, host unreachable).
    case network(URLError)
    /// Authentication failed — see `AuthFailure` for the specific reason.
    case auth(AuthFailure)
    /// The server returned a non-success status; `message` is its text, if any.
    case server(statusCode: Int, message: String?)
    /// The media source couldn't be resolved or prepared — see `SourceFailure`.
    case source(SourceFailure)
    /// Playback itself failed — see `PlaybackFailure`.
    case playback(PlaybackFailure)
    /// An unmapped failure; `underlying` preserves the original error for diagnostics.
    case unexpected(String, underlying: AnySendableError?)

    public var userMessage: String {
        switch self {
        case .network(let urlError):
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Couldn't reach your server. Check your connection."
            case .timedOut:
                return "Your server took too long to respond. Try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Couldn't find your server. Check the URL, or make sure it's online."
            default:
                return "The connection failed. Try again."
            }
        case .auth(let failure):
            return failure.userMessage
        case .server:
            return "Your server returned an error. Try again in a moment."
        case .source(let failure):
            return failure.userMessage
        case .playback(let failure):
            return failure.userMessage
        case .unexpected:
            return "Something went wrong. Try again."
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .network(let urlError):
            return "network: \(urlError.code.rawValue) \(urlError.localizedDescription)"
        case .auth(let failure):
            return "auth: \(failure)"
        case .server(let statusCode, let message):
            return "server: HTTP \(statusCode) \(message ?? "")"
        case .source(let failure):
            return "source: \(failure)"
        case .playback(let failure):
            return "playback: \(failure)"
        case .unexpected(let note, let underlying):
            return "unexpected: \(note) underlying=\(underlying?.diagnosticDescription ?? "nil")"
        }
    }
}

public enum AuthFailure: Sendable {
    case invalidCredentials
    case quickConnectExpired
    case tokenInvalidated
    /// A credential that WAS saved can no longer be read from the Keychain (access-group
    /// change after a bundle-id rename, device migration with ThisDeviceOnly items). The
    /// server was never contacted — recovery is re-entering the credential, and callers
    /// must never degrade this into an empty-credential connection attempt.
    case credentialUnavailable

    public var userMessage: String {
        switch self {
        case .invalidCredentials:
            return "Incorrect username or password."
        case .quickConnectExpired:
            return "The pairing code expired before this device was approved."
        case .tokenInvalidated:
            return "Your session expired. Sign in again."
        case .credentialUnavailable:
            return "The saved password couldn't be read. Remove this server and add it again."
        }
    }
}

public enum SourceFailure: Sendable {
    case notFound
    case permissionDenied
    case connectionLost

    public var userMessage: String {
        switch self {
        case .notFound:
            return "Couldn't find that item."
        case .permissionDenied:
            return "You don't have access to that item."
        case .connectionLost:
            return "The connection dropped. Try again."
        }
    }
}

public enum PlaybackFailure: Sendable {
    case decodeFailed
    case unsupportedFormat
    case resourceUnavailable
    case audioSessionFailed

    public var userMessage: String {
        switch self {
        case .decodeFailed:
            return "Couldn't decode this file."
        case .unsupportedFormat:
            return "This file's format isn't supported on this device."
        case .resourceUnavailable:
            return "The stream stalled and didn't recover. Check your connection."
        case .audioSessionFailed:
            return "Couldn't start audio playback. Try again."
        }
    }
}

public struct AnySendableError: Sendable {
    public let diagnosticDescription: String

    public init(_ error: Error) {
        self.diagnosticDescription = String(describing: error)
    }
}
