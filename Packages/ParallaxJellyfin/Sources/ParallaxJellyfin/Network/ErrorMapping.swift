import Foundation
import Get
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

        // kean/Get's HTTP failure. Sessions built through the client factories never reach here
        // for a non-2xx — `JellyfinResponseValidator` already threw a typed `AppError` — so this
        // covers the clients with no validator installed: sign-in and Quick Connect.
        if let apiError = error as? APIError,
           case .unacceptableStatusCode(let statusCode) = apiError {
            // A 401 while authenticating is a rejected credential, not a dead session — the
            // caller is standing at the login form, and telling them to "sign in again" there
            // would be nonsense. The validator owns the dead-token reading.
            if statusCode == 401 { return .auth(.invalidCredentials) }
            return .server(statusCode: statusCode, message: nil)
        }

        return .unexpected("Jellyfin SDK: \(typeName)", underlying: AnySendableError(error))
    }
}
