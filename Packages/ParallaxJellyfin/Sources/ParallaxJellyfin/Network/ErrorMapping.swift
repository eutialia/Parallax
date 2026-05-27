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
        let typeName = String(describing: type(of: error))
        if typeName.contains("QuickConnectError") {
            let description = String(describing: error)
            if description.contains("maxPollingHit") {
                return .auth(.quickConnectExpired)
            }
            if description.contains("retrievingCodeFailed") {
                return .auth(.quickConnectRejected)
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
        let digits = description.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        return Int(String(String.UnicodeScalarView(digits))) ?? 0
    }
}
