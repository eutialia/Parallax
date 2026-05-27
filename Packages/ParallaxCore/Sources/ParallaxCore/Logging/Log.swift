import Foundation
import os

public enum Log {
    private static let subsystem = "com.lhdev.parallax"

    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

// Wrap any sensitive value (tokens, passwords, signed URLs, etc.) in `Redacted`
// before interpolating into a log message. The wrapper substitutes `<redacted>`
// when printed via `CustomStringConvertible`, so the underlying value never
// reaches Console.app, sysdiagnose archives, or crash reports.
//
//     Log.auth.debug("authenticated user=\(Redacted(token))")
//
// For cases where you need the value to survive into the unified log under
// Apple's privacy controls (e.g., for support diagnostics with the user's
// consent), use `Logger.sensitive(_:value:)` below — it uses
// `OSLogPrivacy.private(mask: .hash)` so the value is hashed at the boundary.
public struct Redacted<Value: Sendable>: CustomStringConvertible, Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public var description: String { "<redacted>" }
}

public extension Logger {
    func sensitive(
        _ message: String,
        value: String,
        level: OSLogType = .debug
    ) {
        self.log(level: level, "\(message): \(value, privacy: .private(mask: .hash))")
    }
}

public extension Error {
    /// Compact, log-safe summary of a network-shaped error. `URLError` gets
    /// structured detail (code + symbol + failing URL) so an opaque
    /// "Network error" turns into something like
    /// `URLError code=-1022 (appTransportSecurityRequiresSecureConnection) failingURL=http://192.168.1.10:8096/...`.
    /// Other errors fall back to type name + description, which for the kean/Get
    /// and Jellyfin SDK errors covers status code / URL without echoing
    /// authorization headers or response bodies.
    var networkDiagnostic: String {
        if let urlError = self as? URLError {
            let failing = urlError.failingURL?.absoluteString ?? "nil"
            return "URLError code=\(urlError.code.rawValue) (\(urlError.code)) failingURL=\(failing)"
        }
        return "\(type(of: self)): \(self)"
    }
}
