# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tooling to run a multi-Mac **MLX** inference cluster over **JACCL** (RDMA over Thunderbolt) and expose it as an OpenAI-compatible HTTP API. There is no build system and no test suite — it's a Python server, a benchmark script, and bash helpers, all launched across nodes via `mlx.launch --backend jaccl`.

## The one architectural idea that matters

MLX sharded inference is **SPMD**: every rank runs the same program and must call `generate()` for *every* request, or the collective ops deadlock. But only rank 0 runs the HTTP server. The server bridges this gap with a **second, hand-rolled control-plane** (`server/openai_cluster_server.py`) that is separate from JACCL's RDMA data path:

- Rank 0 opens a TCP listener on `CTRL_PORT` (default 18080) and runs the FastAPI/uvicorn app on `PORT` (8080).
- Worker ranks (1..N-1) skip HTTP entirely; they connect back to rank 0's control-plane and sit in `worker_loop()` blocking on a framed-JSON socket.
- Per request: rank 0 pops from an `asyncio.Queue`, broadcasts a `{prompt, max_tokens}` task to workers, then all ranks call `generate()`/`stream_generate()` in lockstep. Rank 0 waits for `{"type":"done"}` from each worker before finishing.

So there are two independent transports: RDMA/Thunderbolt (JACCL collectives inside `generate()`) and this TCP control-plane (task dispatch + done signaling). If a request hangs, it's almost always because not all ranks entered `generate()` — check every node's server process and `CTRL_PORT` reachability.

Requests are processed **strictly sequentially** (queue depth `QUEUE_MAX`, default 8; a full queue returns HTTP 429). No batching.

## Running things

There is nothing to install per-checkout. Setup (conda env `mlxjccl`, RDMA enablement in macOS Recovery, mesh cabling) is a one-time per-machine process documented in `docs/from-scratch.md`.

```bash
# Verify SSH + RDMA devices across nodes
./scripts/verify_cluster.sh
HOSTFILE=hostfiles/hosts-2node.json ./scripts/verify_cluster.sh   # non-default hostfile

# Distributed tokens/sec benchmark (rank 0 prints the numbers)
conda run -n mlxjccl mlx.launch --verbose --backend jaccl \
  --hostfile hostfiles/hosts.json \
  --env MLX_METAL_FAST_SYNCH=1 --env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 -- \
  python scripts/jaccl_tps_bench.py --model "$MODEL_DIR" --prompt "..." --max-tokens 256

# Start / stop the OpenAI server (MODEL_DIR is required)
MODEL_DIR=~/models_mlx/your-model ./scripts/run_openai_cluster_server.sh
./scripts/stop_openai_cluster_server.sh   # pkill -f openai_cluster_server.py on every node
```

The launcher (`run_openai_cluster_server.sh`) auto-detects `CTRL_HOST` from the first host's `ips[0]` in the hostfile, pkills stale servers on all nodes, then runs `mlx.launch`. It maps its `HTTP_HOST`/`HTTP_PORT` env vars onto the Python's `HOST`/`PORT`.

## Things that will bite you

- **`MLX_METAL_FAST_SYNCH=1` is mandatory for performance** — omitting it makes inference 5-6x slower. Always pass it through `mlx.launch --env`.
- **Always run offline** (`HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`). Without them, every node independently tries to download a missing model → races, partial downloads, inconsistent state. Download once on rank 0, `rsync` to every node at the *same absolute path*, then run offline.
- **The model path must be identical on every node.** `MODEL_DIR` is passed verbatim to all ranks.
- **The hostfile is topology, not just a host list.** Each entry's `rdma` array is a per-pair adjacency row (index N = the RDMA device facing node N, `null` on the diagonal) and must match physical cabling. Only rank 0 needs `ips` populated (the LAN coordinator address). `hostfiles/hosts.json` is gitignored; edit a copy of `hosts.json.example`. 4 nodes require a fully connected mesh (6 Thunderbolt cables).
- **Custom-tokenizer fallback:** `sharded_load_with_fallback()` catches tokenizer-load failures and manually loads a `tokenization_*.py` from the model dir (e.g. Kimi-K2.5), wrapping it in `TokenizerWrapper` to swallow unsupported `encode`/`decode` kwargs. This same block is duplicated in both `server/openai_cluster_server.py` and `scripts/jaccl_tps_bench.py` — keep them in sync if you touch one.
- **mlx-lm import drift:** `generate`/`stream_generate` are imported with try/except across `mlx_lm.utils` and `mlx_lm.generate` because the module moved between branches. Preserve that pattern.
- **Single prompt only** on `/v1/completions` — a list is rejected unless length 1 (distributed mode processes one prompt at a time).
- **Thunderbolt Bridge breaks JACCL.** A port that's a bridge member has no own IPv6 link-local → empty RDMA GID table → `Changing queue pair to RTR failed with errno 96`. Remove RDMA ports from the bridge (System Settings → Network → Manage Virtual Interfaces). A matrix device name the node doesn't have fails earlier as `Couldn't allocate protection domain`. `scripts/jaccl_smoke.py` exercises the whole RDMA path without a model; see from-scratch.md §10.

## The macOS app (`app/`)

`app/` is **JacclCluster**, a native macOS 14+ SwiftUI GUI over the same contract: a thin
Xcode app target (`app/JacclCluster/` + `JacclCluster.xcodeproj`) with ~all code in the
local Swift package `app/JacclClusterKit/` (Swift 6 language mode).

- Headless logic tests: `cd app/JacclClusterKit && swift test`.
- App build: `xcodebuild -project app/JacclCluster.xcodeproj -scheme JacclCluster build`
  or open in Xcode. App Sandbox is deliberately OFF (spawns ssh/mlx.launch/rsync).
- Add new kit sources under `app/JacclClusterKit/Sources/JacclClusterKit/` — the app
  target uses a synchronized folder group, so `project.pbxproj` never needs editing.
- The app must not change the existing contract: hostfile JSON shape, the script's
  `mlx.launch` env set (it execs `<conda-prefix>/bin/mlx.launch` directly, not
  `conda run`, so logs stream and SIGTERM works), `/health` + `/queue` endpoints, and
  per-node pkill stop semantics. The shell scripts remain a supported, interchangeable
  CLI path.
- `/usr/bin/rsync` on macOS is openrsync (no `--info=progress2`; classic `--progress`
  only) — the sync engine's progress parser handles both flavors.
- **Node provisioning replicates, never installs**: "Set up node" rsyncs rank 0's repo,
  python interpreter (uv-managed trees under $HOME), and env to the worker at identical
  absolute paths, then verifies `import mlx.core, mlx_lm, fastapi, uvicorn` remotely.
  This guarantees identical wheel versions on every rank; don't replace it with remote
  pip/uv installs.
