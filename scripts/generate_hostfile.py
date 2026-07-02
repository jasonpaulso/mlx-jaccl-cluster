#!/usr/bin/env python3
"""
Generate a JACCL hostfile by detecting the Thunderbolt cabling between nodes.

Each node reports its Thunderbolt buses via `system_profiler SPThunderboltDataType`:
every bus has a domain UUID, and a connected bus lists the peer's domain UUID.
Matching UUIDs across nodes yields the physical topology, and
`networksetup -listallhardwareports` maps each receptacle ("Thunderbolt N")
to its enX interface, giving the rdma_enX device names for the matrix.

Usage:
  python3 scripts/generate_hostfile.py <ssh-host> <ssh-host> [...] [-o FILE]

Hosts are given in rank order (rank 0 first). Rank 0's LAN IP (the mlx.launch
coordinator address) is auto-detected via `ipconfig getifaddr en0`.
Fails loudly if any pair of nodes has no cable, or more than one.
"""
import argparse
import json
import subprocess
import sys


def ssh(host: str, cmd: str) -> str:
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, cmd],
        capture_output=True, text=True, timeout=60,
    )
    if r.returncode != 0:
        raise RuntimeError(f"ssh {host} '{cmd}' failed: {r.stderr.strip()}")
    return r.stdout


def gather_buses(host: str) -> list[dict]:
    """One entry per Thunderbolt bus: domain uuid, receptacle id, speed, peer uuids."""
    data = json.loads(ssh(host, "system_profiler SPThunderboltDataType -json"))
    buses = []
    for bus in data.get("SPThunderboltDataType", []):
        uuid = bus.get("domain_uuid_key")
        tag = bus.get("receptacle_1_tag") or {}
        receptacle = tag.get("receptacle_id_key")
        if uuid is None or receptacle is None:
            continue
        # Peripherals (displays, disks) have no domain uuid; only Macs do.
        peers = [
            item["domain_uuid_key"]
            for item in bus.get("_items", [])
            if item.get("domain_uuid_key")
        ]
        buses.append({
            "uuid": uuid,
            "receptacle": receptacle,
            "speed": tag.get("current_speed_key", ""),
            "peers": peers,
        })
    return buses


def gather_ifaces(host: str) -> dict[str, str]:
    """Map hardware port name ("Thunderbolt 3") -> interface ("en2")."""
    out = ssh(host, "networksetup -listallhardwareports")
    ifaces = {}
    port = None
    for line in out.splitlines():
        if line.startswith("Hardware Port: "):
            port = line[len("Hardware Port: "):].strip()
        elif line.startswith("Device: ") and port is not None:
            ifaces[port] = line[len("Device: "):].strip()
            port = None
    return ifaces


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("hosts", nargs="+", help="ssh hosts in rank order (rank 0 first)")
    ap.add_argument("-o", "--output", help="write hostfile here (default: stdout)")
    args = ap.parse_args()
    hosts = args.hosts
    n = len(hosts)

    nodes = []
    for h in hosts:
        print(f"[{h}] querying Thunderbolt topology...", file=sys.stderr)
        buses, ifaces = gather_buses(h), gather_ifaces(h)
        for b in buses:
            port = f"Thunderbolt {b['receptacle']}"
            b["iface"] = ifaces.get(port)
        nodes.append(buses)

    # domain uuid -> owning node index
    owner = {}
    for i, buses in enumerate(nodes):
        for b in buses:
            owner[b["uuid"]] = i

    # For each node, edges to peer nodes: peer index -> list of buses
    errors = []
    matrix = []
    for i, buses in enumerate(nodes):
        edges: dict[int, list[dict]] = {}
        for b in buses:
            for peer_uuid in b["peers"]:
                j = owner.get(peer_uuid)
                if j is not None and j != i:
                    edges.setdefault(j, []).append(b)
        row = []
        for j in range(n):
            if j == i:
                row.append(None)
                continue
            found = edges.get(j, [])
            if not found:
                errors.append(f"no Thunderbolt cable detected between {hosts[i]} and {hosts[j]}")
                row.append(None)
            elif len(found) > 1:
                recs = ", ".join(f"receptacle {b['receptacle']} ({b['iface']})" for b in found)
                errors.append(f"multiple cables between {hosts[i]} and {hosts[j]}: {recs} — remove one")
                row.append(None)
            elif not found[0]["iface"]:
                errors.append(f"{hosts[i]}: no enX interface for Thunderbolt {found[0]['receptacle']}")
                row.append(None)
            else:
                b = found[0]
                row.append(f"rdma_{b['iface']}")
                print(f"[link] {hosts[i]} Thunderbolt {b['receptacle']} ({b['iface']}) -> {hosts[j]}  [{b['speed']}]",
                      file=sys.stderr)
        matrix.append(row)

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    try:
        rank0_ip = ssh(hosts[0], "ipconfig getifaddr en0").strip()
    except RuntimeError:
        rank0_ip = ""
        print(f"WARNING: could not detect LAN IP for {hosts[0]}; fill ips[0] manually", file=sys.stderr)

    hostfile = [
        {"ssh": h, "ips": [rank0_ip] if (i == 0 and rank0_ip) else [], "rdma": matrix[i]}
        for i, h in enumerate(hosts)
    ]
    text = json.dumps(hostfile, indent=2) + "\n"
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
        print(f"wrote {args.output}", file=sys.stderr)
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
