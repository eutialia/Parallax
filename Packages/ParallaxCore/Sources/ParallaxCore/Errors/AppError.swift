import Foundation

public enum AppError: Error, Sendable {
    case network(URLError)
    case auth(AuthFailure)
    case server(statusCode: Int, message: String?)
    case source(SourceFailure)
    case playback(PlaybackFailure)
    case unexpected(String, underlying: AnySendableError?)

    public var userMessage: String {
        switch self {
        case .network(let urlError):
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Couldn't reach the server. Check your internet connection."
            case .timedOut:
                return "The server took too long to respond. Try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Couldn't find the server. Check the URL."
            default:
                return "Network error. Please try again."
            }
        case .auth(let failure):
            return failure.userMessage
        case .server:
            return "The server is having trouble responding. Try again in a moment."
        case .source(let failure):
            return failure.userMessage
        case .playback(let failure):
            return failure.userMessage
        case .unexpected:
            return "Something went wrong. Please try again."
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

    public var userMessage: String {
        switch self {
        case .invalidCredentials:
            return "Incorrect username or password."
        case .quickConnectExpired:
            return "The pairing code expired. Please try again."
        case .tokenInvalidated:
            return "Your session expired. Please sign in again."
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
            return "That item couldn't be found."
        case .permissionDenied:
            return "You don't have access to that item."
        case .connectionLost:
            return "Lost connection to the source. Try again."
        }
    }
}

public enum PlaybackFailure: Sendable {
    case decodeFailed
    case unsupportedFormat
    case resourceUnavailable

    public var userMessage: String {
        switch self {
        case .decodeFailed:
            return "Couldn't decode that file."
        case .unsupportedFormat:
            return "This file's format isn't supported on this device."
        case .resourceUnavailable:
            return "Couldn't reach the file. Check your connection."
        }
    }
}

public struct AnySendableError: Sendable {
    public let diagnosticDescription: String

    public init(_ error: Error) {
        self.diagnosticDescription = String(describing: error)
    }
}
