import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Pins `SMBFileSource.isTransportClass` — the shared cut that decides whether a listing retry or a
/// thumbnail negative-cache poison should treat the error as "the socket died" vs "the server
/// answered no" / "the caller gave up" / "some non-SMB decode failure".
@Suite("SMB error classification")
struct SMBErrorClassificationTests {

    struct TransportCase: Sendable, CustomTestStringConvertible {
        let name: String
        let error: any Error
        let expected: Bool
        var testDescription: String { name }

        init(_ name: String, _ error: any Error, _ expected: Bool) {
            self.name = name
            self.error = error
            self.expected = expected
        }
    }

    static let transportCases: [TransportCase] = [
        // Transport-class POSIX codes (the "everything else" connection-lost bucket).
        .init("ECONNRESET → transport", POSIXError(.ECONNRESET), true),
        .init("ETIMEDOUT → transport", innerTimeoutError, true),
        .init("ECONNREFUSED → transport", POSIXError(.ECONNREFUSED), true),
        .init("NSPOSIX ECONNRESET → transport",
              NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNRESET.rawValue)), true),

        // Content-level / definitive server answers — never transport.
        .init("ENOENT → not transport", POSIXError(.ENOENT), false),
        .init("ENOTDIR → not transport", POSIXError(.ENOTDIR), false),
        .init("ENODEV → not transport", POSIXError(.ENODEV), false),
        .init("EACCES → not transport", POSIXError(.EACCES), false),
        .init("EPERM → not transport", POSIXError(.EPERM), false),

        // Named non-POSIX shapes.
        .init("CancellationError → not transport", CancellationError(), false),
        .init("HardTimeoutError → transport", HardTimeoutError(), true),
        .init("SMBListerError.timedOut → transport", SMBListerError.timedOut, true),
        .init("SMBListerError.managerInitFailed → not transport", SMBListerError.managerInitFailed, false),

        // Bare non-POSIX / non-named errors must not inherit classify's over-broad default.
        .init("foreign NSError domain → not transport",
              NSError(domain: "SomeOtherDomain", code: 42), false),
        .init("plain Error → not transport", PlainDecodeError(), false),
    ]

    @Test("isTransportClass classifies transport vs content-level faults", arguments: transportCases)
    func isTransportClassTable(_ testCase: TransportCase) {
        #expect(SMBFileSource.isTransportClass(testCase.error) == testCase.expected)
    }

    /// A stand-in for a VLC/decode failure with no POSIX code — the shape that must never poison
    /// via the transport path (and must never look like a lost connection either).
    private struct PlainDecodeError: Error {}
}
