import Foundation
import JellyfinAPI
import ParallaxCore

public enum ErrorMapping {
    public static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }

        if let urlError = error as? URLError {
            return .network(urlError)
        }

        if let clientError = error as? JellyfinClient.ClientError {
            switch clientError {
            case .noAccessToken:
                return .auth(.invalidCredentials)
            }
        }

        // Quick Connect errors are internal to the SDK's QuickConnect helper.
        // The cases aren't public, so match on the type description.
        // Only `maxPollingHit` has a stable user-facing meaning ("the code
        // expired"). `retrievingCodeFailed` is a server/transport problem
        // that should fall through to .unexpected so the upper layer can
        // render an accurate reason instead of a misleading "rejected".
        let typeName = String(describing: type(of: error))
        if typeName.contains("QuickConnectError") {
            let description = String(describing: error)
            if description.contains("maxPollingHit") {
                return .auth(.quickConnectExpired)
            }
        }

        // kean/Get APIError: unacceptableStatusCode(Int) is the common HTTP
        // non-2xx case. Detected by description because the case isn't
        // imported at this layer.
        let description = String(describing: error)
        if description.contains("unacceptableStatusCode") {
            let statusCode = extractStatusCode(from: description)
            return .server(statusCode: statusCode, message: nil)
        }

        return .unexpected("Jellyfin SDK: \(typeName)", underlying: AnySendableError(error))
    }

    private static func extractStatusCode(from description: String) -> Int {
        // Match `unacceptableStatusCode(NNN)` specifically so a stray digit
        // sequence elsewhere in the description (port number, request ID,
        // byte count) can't corrupt the result.
        guard let match = description.range(
            of: #"unacceptableStatusCode\((\d+)\)"#,
            options: .regularExpression
        ) else {
            return 0
        }
        let chunk = description[match]
        let prefix = "unacceptableStatusCode("
        guard chunk.hasPrefix(prefix), chunk.hasSuffix(")") else { return 0 }
        let digits = chunk.dropFirst(prefix.count).dropLast()
        return Int(digits) ?? 0
    }
}
