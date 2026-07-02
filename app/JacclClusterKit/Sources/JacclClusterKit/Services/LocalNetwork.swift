import Foundation
import Darwin

/// Local interface enumeration + hostname identity, used to catch stale
/// coordinator IPs before JACCL tries (and fails) to bind them.
public enum LocalNetwork {
    public struct Interface: Sendable, Equatable {
        public let name: String
        public let address: String

        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }

        /// Link-local (169.254.x — e.g. Thunderbolt bridge) addresses are
        /// poor coordinator choices; the LAN address should be used.
        public var isLinkLocal: Bool {
            address.hasPrefix("169.254.")
        }
    }

    /// Up, non-loopback IPv4 interfaces, routable LAN addresses first.
    public static func ipv4Interfaces() -> [Interface] {
        var results: [Interface] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return [] }
        defer { freeifaddrs(ifaddrPointer) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let sockaddrPtr = entry.pointee.ifa_addr,
                  sockaddrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var addr = sockaddr_in()
            memcpy(&addr, sockaddrPtr, min(MemoryLayout<sockaddr_in>.size, Int(sockaddrPtr.pointee.sa_len)))
            var sinAddr = addr.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }

            results.append(Interface(
                name: String(cString: entry.pointee.ifa_name),
                address: String(cString: buffer)
            ))
        }
        return results.sorted { a, b in
            if a.isLinkLocal != b.isLinkLocal { return !a.isLinkLocal }
            return a.name < b.name
        }
    }

    public static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, 255)
        return String(cString: buffer)
    }

    /// Whether an ssh hostname from the hostfile refers to this machine
    /// (case-insensitive, ".local" suffix ignored).
    public static func hostRefersToThisMachine(_ host: String, localName: String = localHostName()) -> Bool {
        normalized(host) == normalized(localName)
    }

    static func normalized(_ name: String) -> String {
        var normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        if normalized.hasSuffix(".local") {
            normalized.removeLast(".local".count)
        }
        return normalized
    }
}
