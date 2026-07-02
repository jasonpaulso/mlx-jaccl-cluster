import Foundation
import Security
import SystemConfiguration

public enum ThunderboltBridgeFixerError: Error, LocalizedError {
    case authorizationCanceled
    case authorizationDenied
    case preferencesUnavailable
    case lockFailed
    case bridgeRemovalFailed(String)
    case serviceRemovalFailed(String)
    case serviceCreationFailed(String)
    case noCurrentSet
    case commitFailed
    case applyFailed

    public var errorDescription: String? {
        switch self {
        case .authorizationCanceled: "Authorization was canceled."
        case .authorizationDenied: "Authorization was denied."
        case .preferencesUnavailable: "Could not open the system network preferences."
        case .lockFailed: "Could not lock the system network preferences for writing."
        case .bridgeRemovalFailed(let name): "Could not remove bridge interface \(name)."
        case .serviceRemovalFailed(let id): "Could not remove network service \(id)."
        case .serviceCreationFailed(let port): "Could not create a network service for \(port)."
        case .noCurrentSet: "No current network set (location) to add services to."
        case .commitFailed: "Could not save the network configuration changes."
        case .applyFailed: "Could not apply the network configuration changes."
        }
    }
}

public struct ThunderboltBridgeFixOutcome: Sendable {
    public let plan: ThunderboltBridgeFix.Plan
    /// Display names of the per-port services created (e.g. "Thunderbolt 1").
    public let createdServices: [String]
    /// True when a live bridge survived the config apply and was dissolved
    /// with an extra admin shell (ifconfig destroy + re-enable IPv6).
    public let ranRuntimeKick: Bool
}

/// Applies a `ThunderboltBridgeFix.Plan` to the system network configuration
/// through SCPreferences with admin authorization — the same edit the GUI
/// two-step performs (System Settings → Network → Manage Virtual Interfaces →
/// delete Thunderbolt Bridge, then add per-port services). `networksetup`
/// mutations are blocked from the CLI on macOS 27, so SCPreferences is the
/// only scriptable path left.
///
/// Blocking: the authorization prompt and SC calls block the calling thread —
/// run `fix()` off the main actor (e.g. `Task.detached`).
public enum ThunderboltBridgeFixer {
    /// Snapshot of the machine's bridge/service/port state, read without
    /// authorization (reads are unprivileged).
    public static func snapshot() -> ThunderboltBridgeFix.Snapshot {
        let prefs = SCPreferencesCreate(kCFAllocatorDefault, "JacclCluster" as CFString, nil)
        return snapshot(prefs: prefs)
    }

    static func snapshot(prefs: SCPreferences?) -> ThunderboltBridgeFix.Snapshot {
        var bridges: [ThunderboltBridgeFix.Bridge] = []
        var services: [ThunderboltBridgeFix.Service] = []

        if let prefs {
            if let bridgeDict = SCPreferencesPathGetValue(prefs, bridgePathKey) as? [String: Any] {
                bridges = bridgeDict.map { name, value in
                    let entry = value as? [String: Any]
                    return ThunderboltBridgeFix.Bridge(
                        name: name,
                        userDefinedName: entry?["UserDefinedName"] as? String,
                        members: entry?["Interfaces"] as? [String] ?? []
                    )
                }.sorted { $0.name < $1.name }
            }
            if let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
                services = all.map { service in
                    ThunderboltBridgeFix.Service(
                        serviceID: SCNetworkServiceGetServiceID(service) as String? ?? "",
                        name: SCNetworkServiceGetName(service) as String?,
                        interfaceBSDName: SCNetworkServiceGetInterface(service).flatMap {
                            SCNetworkInterfaceGetBSDName($0) as String?
                        }
                    )
                }
            }
        }

        // Physical Thunderbolt ports, identified by their localized hardware
        // name ("Thunderbolt 1", …) — the bridge itself reports as
        // "Thunderbolt Bridge" and is excluded by requiring a digit suffix.
        let ports = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap {
            interface -> ThunderboltBridgeFix.Port? in
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                  display.hasPrefix("Thunderbolt "),
                  display.dropFirst("Thunderbolt ".count).allSatisfy(\.isNumber)
            else { return nil }
            return ThunderboltBridgeFix.Port(bsdName: bsd, displayName: display)
        }.sorted { $0.bsdName < $1.bsdName }

        return ThunderboltBridgeFix.Snapshot(
            bridges: bridges, services: services, thunderboltPorts: ports)
    }

    /// Plans against the live system and applies the plan. No-op (and no
    /// admin prompt) when the machine is already healthy.
    public static func fix() throws -> ThunderboltBridgeFixOutcome {
        let plan = ThunderboltBridgeFix.plan(for: snapshot())
        guard !plan.isEmpty else {
            return ThunderboltBridgeFixOutcome(plan: plan, createdServices: [], ranRuntimeKick: false)
        }

        let authRef = try makeAuthorization()
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        guard let prefs = SCPreferencesCreateWithAuthorization(
            kCFAllocatorDefault, "JacclCluster" as CFString, nil, authRef
        ) else {
            throw ThunderboltBridgeFixerError.preferencesUnavailable
        }

        guard SCPreferencesLock(prefs, true) else {
            throw ThunderboltBridgeFixerError.lockFailed
        }
        var unlocked = false
        defer { if !unlocked { SCPreferencesUnlock(prefs) } }

        try removeBridges(plan.bridgesToRemove, prefs: prefs)
        try removeServices(plan.serviceIDsToRemove, prefs: prefs)
        let created = try createServices(forPorts: plan.portsNeedingService, prefs: prefs)

        guard SCPreferencesCommitChanges(prefs) else {
            throw ThunderboltBridgeFixerError.commitFailed
        }
        guard SCPreferencesApplyChanges(prefs) else {
            throw ThunderboltBridgeFixerError.applyFailed
        }
        SCPreferencesUnlock(prefs)
        unlocked = true

        let kicked = runtimeKickIfBridgeSurvived(plan: plan)
        return ThunderboltBridgeFixOutcome(
            plan: plan, createdServices: created, ranRuntimeKick: kicked)
    }

    // MARK: - Steps

    private static var bridgePathKey: CFString { "/VirtualNetworkInterfaces/Bridge" as CFString }

    private static func makeAuthorization() throws -> AuthorizationRef {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess,
              let authRef else {
            throw ThunderboltBridgeFixerError.authorizationDenied
        }

        let status = "system.services.systemconfiguration.network".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    authRef, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authRef, [.destroyRights])
            throw status == errAuthorizationCanceled
                ? ThunderboltBridgeFixerError.authorizationCanceled
                : ThunderboltBridgeFixerError.authorizationDenied
        }
        return authRef
    }

    /// There is no public SCBridgeInterface API, so the bridge entries are
    /// pruned from the raw `VirtualNetworkInterfaces:Bridge` dictionary.
    private static func removeBridges(_ names: [String], prefs: SCPreferences) throws {
        guard !names.isEmpty else { return }
        guard var dict = SCPreferencesPathGetValue(prefs, bridgePathKey) as? [String: Any] else {
            throw ThunderboltBridgeFixerError.bridgeRemovalFailed(names.joined(separator: ", "))
        }
        for name in names { dict.removeValue(forKey: name) }
        let ok = dict.isEmpty
            ? SCPreferencesPathRemoveValue(prefs, bridgePathKey)
            : SCPreferencesPathSetValue(prefs, bridgePathKey, dict as CFDictionary)
        guard ok else {
            throw ThunderboltBridgeFixerError.bridgeRemovalFailed(names.joined(separator: ", "))
        }
    }

    private static func removeServices(_ serviceIDs: [String], prefs: SCPreferences) throws {
        guard !serviceIDs.isEmpty,
              let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return }
        for service in all {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  serviceIDs.contains(id) else { continue }
            guard SCNetworkServiceRemove(service) else {
                throw ThunderboltBridgeFixerError.serviceRemovalFailed(id)
            }
        }
    }

    private static func createServices(
        forPorts ports: [String], prefs: SCPreferences
    ) throws -> [String] {
        guard !ports.isEmpty else { return [] }
        guard let currentSet = SCNetworkSetCopyCurrent(prefs) else {
            throw ThunderboltBridgeFixerError.noCurrentSet
        }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []

        var created: [String] = []
        for port in ports {
            guard let interface = interfaces.first(where: {
                SCNetworkInterfaceGetBSDName($0) as String? == port
            }), let service = SCNetworkServiceCreate(prefs, interface) else {
                throw ThunderboltBridgeFixerError.serviceCreationFailed(port)
            }
            guard SCNetworkServiceEstablishDefaultConfiguration(service),
                  SCNetworkSetAddService(currentSet, service) else {
                throw ThunderboltBridgeFixerError.serviceCreationFailed(port)
            }
            // Mirror the GUI's default naming ("Thunderbolt 1"); a name clash
            // is fine — the service works under its default name.
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? port
            _ = SCNetworkServiceSetName(service, display as CFString)
            created.append(display)
        }
        return created
    }

    /// Config-level removal doesn't always dissolve an already-live bridge0;
    /// if one of the removed bridges is still up, run the runtime fix
    /// (deletem members, destroy, re-enable IPv6 on the ports) in one admin
    /// shell so RDMA works without a reboot.
    private static func runtimeKickIfBridgeSurvived(plan: ThunderboltBridgeFix.Plan) -> Bool {
        let live = plan.bridgesToRemove.filter { liveInterfaceExists($0) }
        guard !live.isEmpty else { return false }

        var lines: [String] = []
        for bridge in live {
            lines.append(
                "ifconfig \(bridge) 2>/dev/null | awk '/member:/{print $2}' | " +
                "xargs -n1 ifconfig \(bridge) deletem 2>/dev/null || true")
            lines.append("ifconfig \(bridge) destroy 2>/dev/null || true")
        }
        for port in plan.portsNeedingService {
            lines.append("ipconfig set \(port) AUTOMATIC-V6 || true")
        }
        let script = lines.joined(separator: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func liveInterfaceExists(_ name: String) -> Bool {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0 else { return false }
        defer { freeifaddrs(ifaddrPointer) }
        var pointer = ifaddrPointer
        while let entry = pointer {
            if String(cString: entry.pointee.ifa_name) == name { return true }
            pointer = entry.pointee.ifa_next
        }
        return false
    }
}
