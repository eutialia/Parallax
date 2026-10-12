import Foundation
import ParallaxCore
import ParallaxJellyfin
import ParallaxFeatures
@testable import Parallax

// Canonical domain fixtures for the app test target. Everything here was, until this file
// existed, a private builder copy-pasted across suites. One copy each now, every field
// defaulted to the value the majority of callers used, so a suite that needs a different
// shape passes an argument instead of re-spelling the literal.
//
// Deliberately NOT importing `ParallaxCoreTestSupport`: it's a SECOND product of the
// ParallaxCore package, and a sibling product duplicates ParallaxCore in the app-hosted
// bundle, breaking cross-boundary `as AppError` casts — same reason `Fakes/FakeKeychain.swift`
// stays a local copy.

// MARK: - SMB servers

func makeSMBServerData(
    host: String = "nas.local",
    username: String = "alice",
    domain: String = "WORKGROUP",
    shares: [String] = ["Media"]
) -> SMBServerData {
    SMBServerData(host: host, username: username, domain: domain, shares: shares)
}

/// An `SMBServerRef` over `makeSMBServerData`. The default id is the `host|share|path` shape
/// `ServerStore` mints, because the resolver suites seed a Keychain slot keyed on it.
func makeSMBRef(
    id: String = "smb-nas|Media|Movies",
    host: String = "nas.local",
    username: String = "alice",
    domain: String = "WORKGROUP",
    shares: [String] = ["Media"]
) -> SMBServerRef {
    SMBServerRef(
        id: ServerID(rawValue: id),
        data: makeSMBServerData(host: host, username: username, domain: domain, shares: shares)
    )
}
