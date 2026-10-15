import Foundation

/// Finds Sonos players on the LAN with an SSDP search for ZonePlayer devices.
enum SonosDiscovery {
    /// Addresses of players that answered. One is enough: the topology lists the rest.
    static func discover(timeout: TimeInterval = 2.5) async -> [String] {
        await Task.detached { Array(ssdpHosts(timeout: timeout)).sorted() }.value
    }

    private static func ssdpHosts(timeout: TimeInterval) -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
            + "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        let bytes = Array(msg.utf8)
        // Multicast is lossy; send twice.
        for _ in 0..<2 {
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0, String(decoding: buffer[0..<n], as: UTF8.self).contains("Sonos") else { continue }
            var addr = from.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
            hosts.insert(String(cString: text))
        }
        return hosts
    }
}
