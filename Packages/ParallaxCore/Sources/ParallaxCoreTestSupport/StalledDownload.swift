import Foundation

public enum RawClientError: Error {
    case missingURLComponent
    case connectFailed
}

/// A download the client never reads: it sends one `GET` with an open-ended `Range` over a raw
/// socket and then leaves the response unread, so the server's sends park against a full socket
/// buffer. `reset()` ends it the way libvlc's http input does, with an RST instead of a FIN.
///
/// A class rather than `~Copyable`: the test holds several in an array, which noncopyable
/// elements can't. `reset()`/`close()` are idempotent and `deinit` closes, so the descriptor is
/// released exactly once however the test exits.
public final class StalledDownload {
    private var fd: Int32?

    public init(url: URL) throws {
        guard let host = url.host, let port = url.port else { throw RawClientError.missingURLComponent }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawClientError.connectFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw RawClientError.missingURLComponent
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { Darwin.close(fd); throw RawClientError.connectFailed }
        let request = Array("GET \(url.path) HTTP/1.1\r\nHost: bridge\r\nRange: bytes=0-\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else {
            Darwin.close(fd)
            throw RawClientError.connectFailed
        }
        self.fd = fd
    }

    deinit { close() }

    public func reset() {
        guard let fd else { return }
        var abort = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
        close()
    }

    public func close() {
        guard let fd else { return }
        self.fd = nil
        Darwin.close(fd)
    }
}
