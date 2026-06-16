import ParallaxJellyfin

extension SMBServerData {
    /// libVLC media options carrying SMB credentials. Applied verbatim by the engine,
    /// never logged. Order is irrelevant — libVLC merges per-media options.
    func vlcCredentialOptions(password: String) -> [String] {
        [":smb-user=\(username)", ":smb-pwd=\(password)", ":smb-domain=\(domain)"]
    }
}
