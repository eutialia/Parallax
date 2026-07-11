import Darwin
import Foundation

/// Resolves the device's primary LAN IPv4 address for the SMB→HTTP bridge URL.
public enum LocalNetworkAddress {

    /// The primary LAN IPv4 (Wi-Fi/Ethernet `en*`) as a dotted quad, or `nil` off-network.
    ///
    /// Walks `getifaddrs`, keeping `AF_INET` interfaces whose name begins with `en` (excludes
    /// loopback `lo0`, cellular `pdp_ip*`, and the `awdl*`/`bridge*` virtual links AirPlay can't
    /// route to). Returns the first match — on a typical device only one `en*` carries an IPv4.
    public static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            // Interface must be up, running, and not loopback.
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var storage = sockaddr_in()
            memcpy(&storage, addr, Int(MemoryLayout<sockaddr_in>.size))
            var sinAddr = storage.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let address = String(cString: buffer)
            // A self-assigned link-local address means the interface has no DHCP lease —
            // an AirPlay receiver can't route to it, and on-device a VPN's policy layer
            // (NECP) resets connections to it. Worse than the loopback fallback; skip it.
            guard !address.hasPrefix("169.254.") else { continue }
            return address
        }
        return nil
    }
}
