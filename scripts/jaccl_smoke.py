#!/usr/bin/env python3
"""Minimal JACCL smoke test: init the distributed group and run one all_sum.

Run via:
    mlx.launch --verbose --backend jaccl --hostfile hostfiles/hosts.json -- \
        python scripts/jaccl_smoke.py

Exercises the whole RDMA path (device open, PD, QP handshake, one collective)
without loading a model. Rank 0 prints one OK line per rank.
"""
import mlx.core as mx

world = mx.distributed.init()
result = mx.distributed.all_sum(mx.ones((4,)))
mx.eval(result)
print(f"[smoke] rank={world.rank()} size={world.size()} all_sum={result.tolist()}", flush=True)
