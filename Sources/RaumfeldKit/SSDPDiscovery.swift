import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Finds the Raumfeld host with an SSDP M-SEARCH for its config device.
///
/// - Important: On iOS, sending multicast requires the
///   `com.apple.developer.networking.multicast` entitlement, which Apple grants
///   on request. Apps without it should let the user enter the host's address.
public enum SSDPDiscovery {
    public static let searchTarget = "urn:schemas-raumfeld-com:device:ConfigDevice:1"

    /// Returns the IP address of the first Raumfeld host that answers, or `nil`.
    public static func findHost(timeout: TimeInterval = 3) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try search(timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static var searchMessage: String {
        [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 1",
            "ST: \(searchTarget)",
            "", "",
        ].joined(separator: "\r\n")
    }

    /// Extracts the host from the `LOCATION` header of an SSDP response.
    static func host(fromResponse response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("LOCATION") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return URL(string: value)?.host
        }
        return nil
    }

    private static func search(timeout: TimeInterval) throws -> String? {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #else
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #endif
        guard fd >= 0 else { throw RaumfeldError.invalidResponse("cannot open UDP socket (errno \(errno))") }
        defer { close(fd) }

        var ttl: UInt8 = 2
        setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1900).bigEndian
        address.sin_addr.s_addr = inet_addr("239.255.255.250")

        let message = Array(searchMessage.utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent >= 0 else { throw RaumfeldError.invalidResponse("SSDP send failed (errno \(errno))") }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var tv = timeval()
            tv.tv_sec = numericCast(Int(remaining))
            tv.tv_usec = numericCast(Int((remaining - floor(remaining)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            let response = String(decoding: buffer[0..<count], as: UTF8.self)
            if response.contains(searchTarget) || response.lowercased().contains("raumfeld"),
               let host = host(fromResponse: response) {
                return host
            }
        }
    }
}
