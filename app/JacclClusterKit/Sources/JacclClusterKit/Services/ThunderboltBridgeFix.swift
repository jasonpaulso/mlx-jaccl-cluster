import Foundation

/// Pure planning for the reboot-proof Thunderbolt Bridge fix.
///
/// A Thunderbolt port that is a Bridge member has no own IPv6 link-local, so
/// its RDMA GID table is empty and JACCL's QP handshake fails with "Changing
/// queue pair to RTR failed with errno 96". Deleting the Bridge *service*
/// from the Network list is not enough: the bridge *virtual interface* lives
/// in the system config's `VirtualNetworkInterfaces:Bridge` section and
/// re-captures the ports on every reboot. The durable fix (what the GUI
/// two-step does) is: remove the bridge virtual interface, then give each
/// Thunderbolt port its own network service so configd assigns it an
/// IPv6 link-local at boot.
///
/// This type only decides *what* to change; `ThunderboltBridgeFixer` applies
/// the plan through SCPreferences with admin authorization (networksetup
/// mutations are blocked from the CLI on macOS 27, so that path is out).
public enum ThunderboltBridgeFix {
    /// A bridge entry from `VirtualNetworkInterfaces:Bridge` in the system
    /// network preferences (e.g. bridge0 holding en1/en2/en7).
    public struct Bridge: Sendable, Equatable {
        public let name: String
        public let userDefinedName: String?
        public let members: [String]

        public init(name: String, userDefinedName: String?, members: [String]) {
            self.name = name
            self.userDefinedName = userDefinedName
            self.members = members
        }
    }

    /// A configured network service and the BSD interface it rides on.
    public struct Service: Sendable, Equatable {
        public let serviceID: String
        public let name: String?
        public let interfaceBSDName: String?

        public init(serviceID: String, name: String?, interfaceBSDName: String?) {
            self.serviceID = serviceID
            self.name = name
            self.interfaceBSDName = interfaceBSDName
        }
    }

    /// A physical Thunderbolt port (e.g. en2 / "Thunderbolt 3").
    public struct Port: Sendable, Equatable {
        public let bsdName: String
        public let displayName: String?

        public init(bsdName: String, displayName: String?) {
            self.bsdName = bsdName
            self.displayName = displayName
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var bridges: [Bridge]
        public var services: [Service]
        public var thunderboltPorts: [Port]

        public init(bridges: [Bridge], services: [Service], thunderboltPorts: [Port]) {
            self.bridges = bridges
            self.services = services
            self.thunderboltPorts = thunderboltPorts
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Bridge interface names (bridge0, …) to delete from
        /// `VirtualNetworkInterfaces:Bridge`.
        public var bridgesToRemove: [String]
        /// Services riding on a removed bridge (usually already gone if the
        /// user deleted "Thunderbolt Bridge" from the Network list).
        public var serviceIDsToRemove: [String]
        /// Thunderbolt ports left without any service — each needs a fresh
        /// per-port service (mirrors a healthy machine's "Thunderbolt N"
        /// service list).
        public var portsNeedingService: [String]

        public var isEmpty: Bool {
            bridgesToRemove.isEmpty && serviceIDsToRemove.isEmpty && portsNeedingService.isEmpty
        }
    }

    public static func plan(for snapshot: Snapshot) -> Plan {
        let thunderboltBSDNames = Set(snapshot.thunderboltPorts.map(\.bsdName))

        // A bridge is the culprit when it holds Thunderbolt ports; match the
        // stock name too in case its member list is empty or parsed oddly.
        let bridgesToRemove = snapshot.bridges.filter { bridge in
            !thunderboltBSDNames.isDisjoint(with: bridge.members)
                || bridge.userDefinedName?.localizedCaseInsensitiveContains("Thunderbolt") == true
        }.map(\.name)
        let removedBridges = Set(bridgesToRemove)

        // Services riding a removed bridge, plus orphaned Thunderbolt Bridge
        // services left behind when the virtual interface was deleted but the
        // service record survived outside the current set (seen in the wild:
        // "Thunderbolt Bridge" on a bridge0 that no longer exists).
        let knownBridges = Set(snapshot.bridges.map(\.name))
        let serviceIDsToRemove = snapshot.services.filter { service in
            guard let bsd = service.interfaceBSDName, bsd.hasPrefix("bridge") else { return false }
            if removedBridges.contains(bsd) { return true }
            return !knownBridges.contains(bsd)
                && service.name?.localizedCaseInsensitiveContains("Thunderbolt") == true
        }.map(\.serviceID)
        let removedServiceIDs = Set(serviceIDsToRemove)

        let servicedPorts = Set(snapshot.services.compactMap { service in
            removedServiceIDs.contains(service.serviceID) ? nil : service.interfaceBSDName
        })
        let portsNeedingService = snapshot.thunderboltPorts
            .map(\.bsdName)
            .filter { !servicedPorts.contains($0) }
            .sorted()

        return Plan(
            bridgesToRemove: bridgesToRemove.sorted(),
            serviceIDsToRemove: serviceIDsToRemove.sorted(),
            portsNeedingService: portsNeedingService
        )
    }
}
