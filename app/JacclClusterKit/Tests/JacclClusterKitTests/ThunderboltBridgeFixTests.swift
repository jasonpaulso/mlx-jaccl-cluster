import XCTest
@testable import JacclClusterKit

final class ThunderboltBridgeFixTests: XCTestCase {
    private let macBookPorts = [
        ThunderboltBridgeFix.Port(bsdName: "en1", displayName: "Thunderbolt 1"),
        ThunderboltBridgeFix.Port(bsdName: "en7", displayName: "Thunderbolt 2"),
        ThunderboltBridgeFix.Port(bsdName: "en2", displayName: "Thunderbolt 3"),
    ]

    /// The classic broken state: bridge0 holds every Thunderbolt port, the
    /// bridge service still exists, no per-port services.
    func testStockBridgeIsFullyDismantled() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [.init(name: "bridge0", userDefinedName: "Thunderbolt Bridge",
                            members: ["en1", "en2", "en7"])],
            services: [
                .init(serviceID: "WIFI", name: "Wi-Fi", interfaceBSDName: "en0"),
                .init(serviceID: "TB-BRIDGE", name: "Thunderbolt Bridge", interfaceBSDName: "bridge0"),
            ],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertEqual(plan.bridgesToRemove, ["bridge0"])
        XCTAssertEqual(plan.serviceIDsToRemove, ["TB-BRIDGE"])
        XCTAssertEqual(plan.portsNeedingService, ["en1", "en2", "en7"])
    }

    /// The MacBook's pre-fix state: the bridge *service* was deleted from the
    /// Network list but the virtual interface persisted and re-captures the
    /// ports at boot.
    func testOrphanBridgeInterfaceWithoutService() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [.init(name: "bridge0", userDefinedName: "Thunderbolt Bridge",
                            members: ["en1", "en2", "en7"])],
            services: [.init(serviceID: "WIFI", name: "Wi-Fi", interfaceBSDName: "en0")],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertEqual(plan.bridgesToRemove, ["bridge0"])
        XCTAssertEqual(plan.serviceIDsToRemove, [])
        XCTAssertEqual(plan.portsNeedingService, ["en1", "en2", "en7"])
    }

    /// The MacBook's current state: bridge already gone, en2 has a service,
    /// but the other two ports would come up without an IPv6 link-local if
    /// cabled for a bigger mesh.
    func testPartiallyFixedMachineOnlyAddsMissingServices() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [],
            services: [
                .init(serviceID: "WIFI", name: "Wi-Fi", interfaceBSDName: "en0"),
                .init(serviceID: "TB3", name: "Thunderbolt 3", interfaceBSDName: "en2"),
            ],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertEqual(plan.bridgesToRemove, [])
        XCTAssertEqual(plan.serviceIDsToRemove, [])
        XCTAssertEqual(plan.portsNeedingService, ["en1", "en7"])
    }

    /// A healthy machine (the Studio): nothing to do, so the UI can say so
    /// instead of prompting for admin rights.
    func testHealthyMachineYieldsEmptyPlan() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [],
            services: [
                .init(serviceID: "TB1", name: "Thunderbolt 1", interfaceBSDName: "en1"),
                .init(serviceID: "TB2", name: "Thunderbolt 2", interfaceBSDName: "en7"),
                .init(serviceID: "TB3", name: "Thunderbolt 3", interfaceBSDName: "en2"),
            ],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertTrue(plan.isEmpty)
    }

    /// A user-built bridge over non-Thunderbolt ports must be left alone.
    func testUnrelatedBridgeIsPreserved() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [.init(name: "bridge1", userDefinedName: "Lab Bridge",
                            members: ["en0", "en5"])],
            services: [
                .init(serviceID: "LAB", name: "Lab Bridge", interfaceBSDName: "bridge1"),
                .init(serviceID: "TB1", name: "Thunderbolt 1", interfaceBSDName: "en1"),
                .init(serviceID: "TB2", name: "Thunderbolt 2", interfaceBSDName: "en7"),
                .init(serviceID: "TB3", name: "Thunderbolt 3", interfaceBSDName: "en2"),
            ],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertTrue(plan.isEmpty)
    }

    /// Seen in the wild on the MacBook: the bridge virtual interface was
    /// deleted via the GUI but its service record survived outside the
    /// current set, still pointing at the now-nonexistent bridge0.
    func testOrphanedThunderboltBridgeServiceIsRemoved() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [],
            services: [
                .init(serviceID: "TB-BRIDGE", name: "Thunderbolt Bridge", interfaceBSDName: "bridge0"),
                .init(serviceID: "TB3", name: "Thunderbolt 3", interfaceBSDName: "en2"),
            ],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertEqual(plan.bridgesToRemove, [])
        XCTAssertEqual(plan.serviceIDsToRemove, ["TB-BRIDGE"])
        XCTAssertEqual(plan.portsNeedingService, ["en1", "en7"])
    }

    /// A renamed Thunderbolt bridge with an oddly-parsed (empty) member list
    /// is still caught by its stock name.
    func testBridgeMatchedByNameWhenMembersUnparsed() {
        let snapshot = ThunderboltBridgeFix.Snapshot(
            bridges: [.init(name: "bridge0", userDefinedName: "thunderbolt bridge", members: [])],
            services: [],
            thunderboltPorts: macBookPorts
        )
        let plan = ThunderboltBridgeFix.plan(for: snapshot)
        XCTAssertEqual(plan.bridgesToRemove, ["bridge0"])
    }
}
