#!/usr/bin/env python3
import os
import gc
import time
import json
import socket
import struct
import threading
import asyncio
import concurrent.futures
import importlib.util
import uuid
from typing import Optional, Union, AsyncGenerator

import mlx.core as mx
import sys
from pathlib import Path
from mlx_lm.utils import sharded_load, load_model

# generate() import differs across mlx-lm branches
try:
    from mlx_lm.utils import generate
except Exception:
    from mlx_lm.generate import generate

# stream_generate for SSE streaming
try:
    from mlx_lm.utils import stream_generate
except ImportError:
    try:
        from mlx_lm.generate import stream_generate
    except ImportError:
        stream_generate = None

from fastapi import FastAPI, HTTPException
from starlette.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn


# -------------------------
# Custom tokenizer support
# -------------------------
class TokenizerWrapper:
    """Wrapper to handle encode kwargs that some custom tokenizers don't support."""
    def __init__(self, tokenizer):
        self._tok = tokenizer

    def __getattr__(self, name):
        return getattr(self._tok, name)

    def encode(self, text, **kwargs):
        return self._tok.encode(text)

    def decode(self, tokens, **kwargs):
        return self._tok.decode(tokens)


def load_custom_tokenizer(model_path):
    """Load custom tokenizer directly when AutoTokenizer fails."""
    model_path = Path(model_path)
    sys.path.insert(0, str(model_path))

    for tok_file in model_path.glob("tokenization_*.py"):
        module_name = tok_file.stem
        mod = __import__(module_name)
        for attr in dir(mod):
            cls = getattr(mod, attr)
            if isinstance(cls, type) and hasattr(cls, 'from_pretrained'):
                try:
                    tok = cls.from_pretrained(model_path)
                    return TokenizerWrapper(tok)
                except:
                    continue
    raise RuntimeError(f"Could not load custom tokenizer from {model_path}")


def sharded_load_with_fallback(repo):
    """Load model with fallback for custom tokenizers."""
    model_path = Path(repo)

    try:
        return sharded_load(repo)
    except Exception as e:
        if "tokenizer" not in str(e).lower() and "NoneType" not in str(e):
            raise

    # Fallback: load model and tokenizer separately
    tok = load_custom_tokenizer(model_path)
    model, config = load_model(model_path, lazy=True, strict=False)

    tensor_group = mx.distributed.init()
    if hasattr(model, "shard"):
        model.shard(tensor_group)

    mx.eval(model.parameters())

    x = mx.zeros((1,))
    mx.eval(mx.distributed.all_sum(x))

    return model, tok


# -------------------------
# Model library scanning
# -------------------------
def _model_complete(d: Path) -> bool:
    """A model dir is usable when config.json exists and, if an index is
    present, every weight file it references is on disk (catches partial
    rsyncs — HF_HUB_OFFLINE means nothing gets repaired at load time)."""
    if not (d / "config.json").is_file():
        return False
    weights = {w.name for w in d.glob("*.safetensors")}
    if not weights:
        return False
    index = d / "model.safetensors.index.json"
    if index.is_file():
        try:
            needed = set(json.loads(index.read_text()).get("weight_map", {}).values())
        except Exception:
            return False
        if not needed <= weights:
            return False
    return True


def scan_local_models() -> dict[str, str]:
    """id -> absolute dir for complete model dirs under MODELS_DIR, plus the
    currently loaded model (which may live elsewhere)."""
    found: dict[str, str] = {}
    root = Path(MODELS_DIR)
    if root.is_dir():
        for d in sorted(root.iterdir()):
            if d.is_dir() and _model_complete(d):
                found[d.name] = str(d)
    if MODEL_ID and MODEL_ID not in found and Path(MODEL_DIR).is_dir():
        found[MODEL_ID] = MODEL_DIR
    return found


def _shard_compatible(model_dir: str) -> bool:
    """Same rule as the app's launch preflight: the config's model_type must
    map to an mlx_lm.models module whose source defines shard()."""
    try:
        cfg = json.loads((Path(model_dir) / "config.json").read_text())
        model_type = cfg.get("model_type")
        if not model_type:
            return False
        spec = importlib.util.find_spec(f"mlx_lm.models.{model_type}")
        if spec is None or not spec.origin:
            return False
        return "def shard" in Path(spec.origin).read_text()
    except Exception:
        return False


# -------------------------
# Configuration (env vars)
# -------------------------
# Initial model. Optional: without it the server starts empty and the first
# request (or POST /v1/models/load) picks the model.
MODEL_DIR = os.environ.get("MODEL_DIR") or ""
MODEL_ID = os.environ.get("MODEL_ID") or (
    os.path.basename(MODEL_DIR.rstrip("/")) if MODEL_DIR else None)

# Library of switchable models: immediate subdirectories of MODELS_DIR that
# are complete on EVERY rank and whose architecture mlx-lm can shard.
MODELS_DIR = os.path.expanduser(os.environ.get("MODELS_DIR", "~/models_mlx"))
LOAD_TIMEOUT = float(os.environ.get("LOAD_TIMEOUT", "600"))  # model (un)load budget

HOST = os.environ.get("HOST", "0.0.0.0")      # HTTP bind on rank0
PORT = int(os.environ.get("PORT", "8080"))    # HTTP port on rank0

# Control-plane (rank0 <-> workers) for coordinating "everyone call generate()"
CTRL_PORT = int(os.environ.get("CTRL_PORT", "18080"))

def _default_ctrl_host() -> str:
    c = os.environ.get("MLX_JACCL_COORDINATOR", "")
    if ":" in c:
        return c.split(":", 1)[0]
    return "macstudio1.local"

CTRL_HOST = os.environ.get("CTRL_HOST", _default_ctrl_host())

DEFAULT_MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "512"))

# Backpressure / queueing
QUEUE_MAX = int(os.environ.get("QUEUE_MAX", "8"))          # max queued requests
REQ_TIMEOUT = float(os.environ.get("REQ_TIMEOUT", "120"))  # per request timeout (seconds)

# -------------------------
# Globals
# -------------------------
app = FastAPI()
_model = None
_tok = None
_world = None

# Model registry (rank0): id -> dir for models loadable on every rank.
_available_models: dict[str, str] = {}
_available_at: float = 0.0
_loading: Optional[str] = None  # model id mid-switch, for /health
# Set when ranks may disagree about the loaded model (a rank went silent
# during a switch). Generation would deadlock; only a restart recovers.
_degraded = False

_queue: asyncio.Queue = asyncio.Queue(maxsize=QUEUE_MAX)  # rank0 only uses it

# Single thread for all blocking work (generate + control-plane I/O) so the
# event loop stays free to flush SSE chunks and serve /health during generation.
# One worker: MLX generation always runs on the same thread, one request at a time.
_gen_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="gen")

# -------------------------
# Tiny framed JSON protocol
# -------------------------
def _recvall(sock: socket.socket, n: int) -> Optional[bytes]:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf

def send_msg(sock: socket.socket, obj: dict) -> None:
    data = json.dumps(obj).encode("utf-8")
    sock.sendall(struct.pack("!I", len(data)))
    sock.sendall(data)

def recv_msg(sock: socket.socket) -> Optional[dict]:
    hdr = _recvall(sock, 4)
    if hdr is None:
        return None
    (n,) = struct.unpack("!I", hdr)
    body = _recvall(sock, n)
    if body is None:
        return None
    return json.loads(body.decode("utf-8"))

# -------------------------
# OpenAI-ish schemas
# -------------------------
class ChatMessage(BaseModel):
    role: str
    content: str

class ChatCompletionsReq(BaseModel):
    model: Optional[str] = None
    messages: list[ChatMessage]
    max_tokens: Optional[int] = None
    stream: Optional[bool] = False

class CompletionsReq(BaseModel):
    model: Optional[str] = None
    prompt: Union[str, list[str]]
    max_tokens: Optional[int] = None
    stream: Optional[bool] = False

def _build_chat_prompt(messages: list[ChatMessage]) -> str:
    # Prefer tokenizer chat template when available
    if hasattr(_tok, "apply_chat_template"):
        msgs = [{"role": m.role, "content": m.content} for m in messages]
        return _tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)

    # Fallback: simple "ROLE: content" format
    parts = [f"{m.role.upper()}: {m.content}" for m in messages]
    parts.append("ASSISTANT:")
    return "\n".join(parts)

def _tok_len(text: str) -> int:
    return len(_tok.encode(text))

# -------------------------
# Rank0 worker connections
# -------------------------
_worker_socks: dict[int, socket.socket] = {}  # rank -> socket
_worker_lock = threading.Lock()

def rank0_accept_workers(expected_world_size: int) -> None:
    """
    Rank0 listens for worker control-plane connections.
    Each worker sends {"type":"hello","rank":N}.
    """
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, CTRL_PORT))
    srv.listen(16)
    print(f"[rank0] control-plane listening on {HOST}:{CTRL_PORT}", flush=True)

    while True:
        conn, addr = srv.accept()
        hello = recv_msg(conn)
        if not hello or hello.get("type") != "hello" or "rank" not in hello:
            conn.close()
            continue
        r = int(hello["rank"])
        with _worker_lock:
            _worker_socks[r] = conn
        print(f"[rank0] worker connected rank={r} from {addr}", flush=True)

def rank0_wait_for_workers(expected_world_size: int, timeout_s: int = 60) -> bool:
    t0 = time.time()
    while True:
        with _worker_lock:
            ok = all(r in _worker_socks for r in range(1, expected_world_size))
        if ok:
            print("[rank0] all workers connected", flush=True)
            return True
        if time.time() - t0 > timeout_s:
            return False
        time.sleep(0.1)

def rank0_broadcast_task(task: dict) -> None:
    """
    Send the same task to all worker ranks (1..N-1).
    """
    with _worker_lock:
        items = list(_worker_socks.items())
    for r, s in items:
        send_msg(s, {"type": "task", **task})

def rank0_wait_done(expected_world_size: int) -> None:
    """
    Wait for {"type":"done"} from all workers.
    """
    done: set[int] = set()
    while len(done) < (expected_world_size - 1):
        with _worker_lock:
            items = list(_worker_socks.items())
        for r, s in items:
            if r in done:
                continue
            s.settimeout(0.2)
            try:
                msg = recv_msg(s)
            except Exception:
                msg = None
            if msg and msg.get("type") == "done":
                done.add(r)

def rank0_collect(expected_world_size: int, timeout_s: float) -> dict[int, dict]:
    """
    Collect one {"type":"done"|"error"} reply per worker, or give up at the
    deadline (a missing entry means that rank never answered). All control
    socket reads happen on the single gen thread, so replies can't be stolen
    by a concurrent reader.
    """
    deadline = time.time() + timeout_s
    replies: dict[int, dict] = {}
    while len(replies) < (expected_world_size - 1) and time.time() < deadline:
        with _worker_lock:
            items = list(_worker_socks.items())
        for r, s in items:
            if r in replies:
                continue
            s.settimeout(0.2)
            try:
                msg = recv_msg(s)
            except Exception:
                msg = None
            if msg and msg.get("type") in ("done", "error"):
                replies[r] = msg
    return replies

# -------------------------
# Lockstep model loading
# -------------------------
def _load_model_local(model_dir: Optional[str], model_id: Optional[str]) -> None:
    """
    Drop the current model and load another (or just unload, when model_dir
    is None). Every rank must run this at the same time — sharded_load ends
    in a collective, so a rank that skips it (or fails before reaching it)
    strands the others. Unloading alone runs no collectives.
    """
    global _model, _tok, MODEL_DIR, MODEL_ID
    _model = None
    _tok = None
    gc.collect()
    mx.clear_cache()
    if model_dir:
        _model, _tok = sharded_load_with_fallback(model_dir)
    MODEL_DIR = model_dir or ""
    MODEL_ID = model_id

# -------------------------
# Worker loop
# -------------------------
def worker_loop(rank: int) -> None:
    """
    Workers connect to rank0 control-plane, block waiting for tasks.
    For each task: call generate() (so collectives match rank0), then send done.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((CTRL_HOST, CTRL_PORT))
    send_msg(s, {"type": "hello", "rank": rank})
    print(f"[worker {rank}] connected to control-plane {CTRL_HOST}:{CTRL_PORT}", flush=True)

    while True:
        msg = recv_msg(s)
        if not msg:
            continue
        kind = msg.get("type")

        if kind == "task":
            prompt = msg["prompt"]
            max_tokens = int(msg["max_tokens"])
            _ = generate(_model, _tok, prompt, max_tokens=max_tokens)
            mx.eval()
            send_msg(s, {"type": "done", "rank": rank})

        elif kind == "scan":
            send_msg(s, {"type": "done", "rank": rank,
                         "models": sorted(scan_local_models())})

        elif kind == "load":
            try:
                _load_model_local(msg["model_dir"], msg["model_id"])
                send_msg(s, {"type": "done", "rank": rank})
            except Exception as e:
                print(f"[worker {rank}] load failed: {e}", flush=True)
                send_msg(s, {"type": "error", "rank": rank,
                             "detail": f"{type(e).__name__}: {e}"})

# -------------------------
# Model registry + switching (rank0, gen thread only)
# -------------------------
def _refresh_available_blocking() -> dict[str, str]:
    """
    Recompute the switchable-model registry: rank0's scan intersected with
    every worker's, then filtered to architectures mlx-lm can shard. Runs on
    the gen thread (it reads the control sockets). If a worker doesn't answer
    the scan, the previous registry is kept — stale beats wrong.
    """
    global _available_models, _available_at
    local = scan_local_models()

    with _worker_lock:
        items = list(_worker_socks.items())
    for r, s in items:
        send_msg(s, {"type": "scan"})
    replies = rank0_collect(_world.size(), timeout_s=15)
    if len(replies) < (_world.size() - 1):
        print("[rank0] model scan: not all workers replied; keeping previous registry", flush=True)
        return _available_models

    common = set(local)
    for msg in replies.values():
        common &= set(msg.get("models", []))
    available = {
        mid: local[mid] for mid in sorted(common) if _shard_compatible(local[mid])
    }
    if MODEL_ID:
        available.setdefault(MODEL_ID, MODEL_DIR)  # what's loaded is servable by definition
    _available_models = available
    _available_at = time.time()
    return available


def _switch_model_blocking(model_id: str) -> None:
    """
    Runs on the gen thread. Re-verifies availability on all ranks, then loads
    the model everywhere in lockstep. On a clean partial failure (every rank
    replied, at least one errored) the previous model is reloaded in lockstep.
    A rank that never replies leaves ranks disagreeing about the loaded model
    — that's unrecoverable without a restart, so the cluster is marked
    degraded rather than pretending.
    """
    global _loading, _degraded
    if _degraded:
        raise RuntimeError("Cluster is degraded from an earlier failed model load — restart the server.")
    if model_id == MODEL_ID:
        return
    available = _refresh_available_blocking()
    if model_id not in available:
        raise RuntimeError(
            f"Model '{model_id}' is not loadable on every node. Available: {sorted(available)}")

    old_dir, old_id = MODEL_DIR, MODEL_ID
    new_dir = available[model_id]
    _loading = model_id
    print(f"[rank0] switching model {old_id or '(none)'} -> {model_id}", flush=True)
    try:
        rank0_broadcast_task_raw({"type": "load", "model_dir": new_dir, "model_id": model_id})
        local_error: Optional[str] = None
        try:
            _load_model_local(new_dir, model_id)
        except Exception as e:
            local_error = f"rank 0: {type(e).__name__}: {e}"
        replies = rank0_collect(_world.size(), LOAD_TIMEOUT)

        missing = (_world.size() - 1) - len(replies)
        errors = [f"rank {r}: {m.get('detail', '?')}"
                  for r, m in replies.items() if m.get("type") == "error"]
        if local_error:
            errors.insert(0, local_error)

        if missing:
            _degraded = True
            raise RuntimeError(
                f"{missing} worker(s) never finished loading '{model_id}' "
                f"(errors: {errors or 'none'}); ranks may disagree — restart the server.")
        if errors:
            # Everyone replied cleanly, so a lockstep rollback is safe (when
            # nothing was loaded before, "rollback" is a lockstep unload).
            print(f"[rank0] load failed ({'; '.join(errors)}); rolling back to {old_id or '(none)'}", flush=True)
            rank0_broadcast_task_raw({"type": "load", "model_dir": old_dir or None, "model_id": old_id})
            rollback_error: Optional[str] = None
            try:
                _load_model_local(old_dir or None, old_id)
            except Exception as e:
                rollback_error = f"rank 0: {type(e).__name__}: {e}"
            rb = rank0_collect(_world.size(), LOAD_TIMEOUT)
            rb_bad = ((_world.size() - 1) - len(rb)) or rollback_error or any(
                m.get("type") == "error" for m in rb.values())
            if rb_bad:
                _degraded = True
                raise RuntimeError(
                    f"Loading '{model_id}' failed AND rollback to '{old_id}' failed — "
                    f"restart the server. Original errors: {'; '.join(errors)}")
            raise RuntimeError(
                f"Loading '{model_id}' failed: {'; '.join(errors)}. Rolled back to '{old_id}'.")
        print(f"[rank0] now serving {MODEL_ID}", flush=True)
    finally:
        _loading = None


def rank0_broadcast_task_raw(msg: dict) -> None:
    """Send a non-generate control message (scan/load) to all workers."""
    with _worker_lock:
        items = list(_worker_socks.items())
    for r, s in items:
        send_msg(s, msg)


# -------------------------
# Queue worker (rank0 only)
# -------------------------
def _stream_request_blocking(loop: asyncio.AbstractEventLoop, kind: str, prompt: str, max_t: int, chunk_queue: asyncio.Queue) -> None:
    """
    Runs on _gen_executor. Blocking: broadcasts the task, streams tokens,
    waits for workers. Chunks are handed to the event loop thread-safely.
    """
    def put(chunk) -> None:
        loop.call_soon_threadsafe(chunk_queue.put_nowait, chunk)

    # Chat prompts are templated here — after any model switch — so the
    # template always belongs to the model that will generate.
    if kind == "chat":
        prompt = _build_chat_prompt(prompt)

    rank0_broadcast_task({"prompt": prompt, "max_tokens": max_t})

    req_id = f"chatcmpl-{uuid.uuid4().hex[:24]}" if kind == "chat" else f"cmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())

    completion_tokens = 0
    for response in stream_generate(_model, _tok, prompt, max_tokens=max_t):
        completion_tokens += 1
        token_text = response.text  # GenerationResponse.text contains the decoded text
        if kind == "chat":
            chunk = {
                "id": req_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": MODEL_ID,
                "choices": [{
                    "index": 0,
                    "delta": {"content": token_text},
                    "finish_reason": None,
                }],
            }
        else:  # completions
            chunk = {
                "id": req_id,
                "object": "text_completion",
                "created": created,
                "model": MODEL_ID,
                "choices": [{
                    "index": 0,
                    "text": token_text,
                    "finish_reason": None,
                    "logprobs": None,
                }],
            }
        put(f"data: {json.dumps(chunk)}\n\n")

    mx.eval()

    pt = _tok_len(prompt)
    usage = {
        "prompt_tokens": pt,
        "completion_tokens": completion_tokens,
        "total_tokens": pt + completion_tokens,
    }

    # Send final chunk with finish_reason (usage rides along, mlx_lm.server-style)
    if kind == "chat":
        final_chunk = {
            "id": req_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": MODEL_ID,
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": "stop",
            }],
            "usage": usage,
        }
    else:
        final_chunk = {
            "id": req_id,
            "object": "text_completion",
            "created": created,
            "model": MODEL_ID,
            "choices": [{
                "index": 0,
                "text": "",
                "finish_reason": "stop",
                "logprobs": None,
            }],
            "usage": usage,
        }
    put(f"data: {json.dumps(final_chunk)}\n\n")
    put("data: [DONE]\n\n")
    put(None)  # Signal end of stream

    rank0_wait_done(_world.size())


def _request_blocking(kind: str, prompt: str, max_t: int) -> dict:
    """
    Runs on _gen_executor. Blocking: broadcasts the task, generates the full
    completion, waits for workers, returns the OpenAI-shaped response.
    """
    if kind == "chat":  # template with the (possibly just-switched) model's tokenizer
        prompt = _build_chat_prompt(prompt)

    rank0_broadcast_task({"prompt": prompt, "max_tokens": max_t})

    t0 = time.time()
    out_text = generate(_model, _tok, prompt, max_tokens=max_t)
    mx.eval()
    t1 = time.time()

    rank0_wait_done(_world.size())

    completion = out_text[len(prompt):] if out_text.startswith(prompt) else out_text
    pt = _tok_len(prompt)
    ct = _tok_len(completion)

    timing = {
        "seconds": round(t1 - t0, 3),
        "tokens_per_sec": round(ct / max(t1 - t0, 1e-9), 3),
    }

    if kind == "chat":
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": MODEL_ID,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": completion},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct},
            "timing": timing,
        }
    elif kind == "completions":
        return {
            "id": f"cmpl-{uuid.uuid4().hex[:24]}",
            "object": "text_completion",
            "created": int(time.time()),
            "model": MODEL_ID,
            "choices": [{
                "index": 0,
                "text": completion,
                "finish_reason": "stop",
                "logprobs": None,
            }],
            "usage": {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct},
            "timing": timing,
        }
    else:
        raise RuntimeError(f"Unknown request kind: {kind}")


async def _queue_worker() -> None:
    """
    Processes queued requests sequentially.
    Each request triggers:
      - broadcast task to workers
      - rank0 generate() or stream_generate()
      - wait for worker completion
      - fulfill per-request future with an OpenAI-shaped response (or stream chunks)
    All blocking work runs on _gen_executor so the event loop stays responsive.
    """
    loop = asyncio.get_running_loop()
    while True:
        item = await _queue.get()
        if item is None:
            _queue.task_done()
            continue

        kind = item["kind"]  # "chat" | "completions" | "load" | "refresh"

        if kind == "refresh":
            try:
                await loop.run_in_executor(_gen_executor, _refresh_available_blocking)
            except Exception as e:
                print(f"[rank0] model registry refresh failed: {e}", flush=True)
            _queue.task_done()
            continue

        if kind == "load":
            fut: asyncio.Future = item["target"]
            try:
                await loop.run_in_executor(_gen_executor, _switch_model_blocking, item["model_id"])
                if not fut.done():
                    fut.set_result({"ok": True, "model": MODEL_ID})
            except Exception as e:
                if not fut.done():
                    fut.set_exception(e)
            _queue.task_done()
            continue

        prompt = item["prompt"]
        max_t = item["max_tokens"]
        result_target = item["target"]
        is_stream = item["stream"]
        try:
            # Auto-switch when the request names another available model.
            wanted = item.get("model_id")
            if wanted and wanted != MODEL_ID:
                await loop.run_in_executor(_gen_executor, _switch_model_blocking, wanted)

            if is_stream and stream_generate is not None:
                chunk_queue: asyncio.Queue = result_target
                await loop.run_in_executor(
                    _gen_executor, _stream_request_blocking, loop, kind, prompt, max_t, chunk_queue
                )
            else:
                fut: asyncio.Future = result_target
                resp = await loop.run_in_executor(
                    _gen_executor, _request_blocking, kind, prompt, max_t
                )
                if not fut.done():  # client may have timed out (wait_for cancels fut)
                    fut.set_result(resp)

        except Exception as e:
            if is_stream:
                chunk_queue: asyncio.Queue = result_target
                await chunk_queue.put(f"data: {json.dumps({'error': str(e)})}\n\n")
                await chunk_queue.put("data: [DONE]\n\n")
                await chunk_queue.put(None)
            elif not result_target.done():
                result_target.set_exception(e)
        finally:
            _queue.task_done()

@app.on_event("startup")
async def _startup() -> None:
    # Only rank0 runs the HTTP server, so only rank0 starts the queue worker
    if _world and _world.rank() == 0:
        asyncio.create_task(_queue_worker())

# -------------------------
# HTTP endpoints (rank0 only)
# -------------------------
@app.get("/health")
def health() -> dict:
    return {
        "ok": not _degraded,
        "world_size": _world.size(),
        "rank": _world.rank(),
        "model": MODEL_ID,
        "queue_max": QUEUE_MAX,
        "queue_size": _queue.qsize(),
        "loading": _loading,
        "degraded": _degraded,
    }

@app.get("/v1/models")
async def list_models() -> dict:
    # Serve the cached registry immediately; kick a lazy re-scan through the
    # queue when it's stale (the scan reads control sockets, which belong to
    # the gen thread).
    if time.time() - _available_at > 60:
        try:
            _queue.put_nowait({"kind": "refresh"})
        except asyncio.QueueFull:
            pass
    models = _available_models or {MODEL_ID: MODEL_DIR}
    return {
        "object": "list",
        "data": [
            {"id": mid, "object": "model", "owned_by": "jaccl-cluster",
             "ready": mid == MODEL_ID}
            for mid in sorted(models)
        ],
    }

class LoadModelReq(BaseModel):
    model: str

@app.post("/v1/models/load")
async def load_model_endpoint(req: LoadModelReq):
    """Explicitly switch the served model (all ranks, in lockstep)."""
    loop = asyncio.get_running_loop()
    fut: asyncio.Future = loop.create_future()
    try:
        _queue.put_nowait({"kind": "load", "model_id": req.model, "target": fut})
    except asyncio.QueueFull:
        raise HTTPException(status_code=429, detail="Server busy (queue full). Try again later.")
    try:
        return await asyncio.wait_for(fut, timeout=LOAD_TIMEOUT + 30)
    except asyncio.TimeoutError:
        raise HTTPException(status_code=504, detail="Model load timed out")
    except RuntimeError as e:
        raise HTTPException(status_code=409, detail=str(e))

@app.get("/queue")
def queue_status() -> dict:
    return {"size": _queue.qsize(), "max": QUEUE_MAX}

async def _stream_generator(chunk_queue: asyncio.Queue) -> AsyncGenerator[str, None]:
    """Yield SSE chunks from the queue until None is received."""
    while True:
        chunk = await chunk_queue.get()
        if chunk is None:
            break
        yield chunk


def _resolve_requested_model(requested: Optional[str]) -> Optional[str]:
    """None when the request targets the loaded model; otherwise the model id
    to switch to (validated against the registry) or an HTTP 400/409."""
    wanted = (requested or "").strip()
    if not wanted or wanted == MODEL_ID:
        if _model is None:
            raise HTTPException(
                status_code=409,
                detail="No model loaded. Name one in the request's \"model\" field or "
                       f"POST /v1/models/load. Available: {sorted(_available_models)}")
        return None
    if wanted not in _available_models:
        available = sorted(_available_models) or ([MODEL_ID] if MODEL_ID else [])
        raise HTTPException(
            status_code=400,
            detail=f"Unknown model '{wanted}'. Available: {available}")
    return wanted

@app.post("/v1/chat/completions")
async def chat_completions(req: ChatCompletionsReq):
    if req.stream and stream_generate is None:
        raise HTTPException(status_code=400, detail="stream=true not supported (stream_generate not available)")
    switch_to = _resolve_requested_model(req.model)

    if _world.rank() != 0:
        raise HTTPException(status_code=500, detail="Rank != 0 received HTTP request")

    # Deliberately NOT templated here: the chat template must come from the
    # tokenizer that generates, which a model switch may be about to replace.
    prompt = req.messages
    max_t = req.max_tokens or DEFAULT_MAX_TOKENS

    if req.stream:
        # Streaming mode: return SSE response
        chunk_queue: asyncio.Queue = asyncio.Queue()
        try:
            _queue.put_nowait({"kind": "chat", "prompt": prompt, "max_tokens": max_t,
                               "target": chunk_queue, "stream": True, "model_id": switch_to})
        except asyncio.QueueFull:
            raise HTTPException(status_code=429, detail="Server busy (queue full). Try again later.")

        return StreamingResponse(
            _stream_generator(chunk_queue),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )
    else:
        # Non-streaming mode: return JSON response
        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()

        try:
            _queue.put_nowait({"kind": "chat", "prompt": prompt, "max_tokens": max_t,
                               "target": fut, "stream": False, "model_id": switch_to})
        except asyncio.QueueFull:
            raise HTTPException(status_code=429, detail="Server busy (queue full). Try again later.")

        # A model switch can dwarf the normal request budget.
        timeout = REQ_TIMEOUT + (LOAD_TIMEOUT if switch_to else 0)
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            raise HTTPException(status_code=504, detail="Request timed out")

@app.post("/v1/completions")
async def completions(req: CompletionsReq):
    if req.stream and stream_generate is None:
        raise HTTPException(status_code=400, detail="stream=true not supported (stream_generate not available)")
    switch_to = _resolve_requested_model(req.model)

    if _world.rank() != 0:
        raise HTTPException(status_code=500, detail="Rank != 0 received HTTP request")

    if isinstance(req.prompt, list):
        # Keep it simple + safe for distributed mode: one prompt at a time.
        if len(req.prompt) != 1:
            raise HTTPException(status_code=400, detail="Only a single prompt string is supported (prompt must be a string, or a list of length 1).")
        prompt = req.prompt[0]
    else:
        prompt = req.prompt

    max_t = req.max_tokens or DEFAULT_MAX_TOKENS

    if req.stream:
        # Streaming mode: return SSE response
        chunk_queue: asyncio.Queue = asyncio.Queue()
        try:
            _queue.put_nowait({"kind": "completions", "prompt": prompt, "max_tokens": max_t,
                               "target": chunk_queue, "stream": True, "model_id": switch_to})
        except asyncio.QueueFull:
            raise HTTPException(status_code=429, detail="Server busy (queue full). Try again later.")

        return StreamingResponse(
            _stream_generator(chunk_queue),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )
    else:
        # Non-streaming mode: return JSON response
        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()

        try:
            _queue.put_nowait({"kind": "completions", "prompt": prompt, "max_tokens": max_t,
                               "target": fut, "stream": False, "model_id": switch_to})
        except asyncio.QueueFull:
            raise HTTPException(status_code=429, detail="Server busy (queue full). Try again later.")

        timeout = REQ_TIMEOUT + (LOAD_TIMEOUT if switch_to else 0)
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            raise HTTPException(status_code=504, detail="Request timed out")

# -------------------------
# Main
# -------------------------
def main() -> None:
    global _model, _tok, _world
    _world = mx.distributed.init()
    if MODEL_DIR:
        _model, _tok = sharded_load_with_fallback(MODEL_DIR)
    else:
        print(f"[rank {_world.rank()}] starting without a model — load one via the API", flush=True)

    if _world.rank() == 0:
        th = threading.Thread(target=rank0_accept_workers, args=(_world.size(),), daemon=True)
        th.start()

        if not rank0_wait_for_workers(_world.size(), timeout_s=60):
            raise RuntimeError("Workers did not connect to control-plane in time")

        # Build the model registry before serving (the gen thread owns the
        # control sockets afterwards; here nothing else is reading them).
        available = _refresh_available_blocking()
        print(f"[rank0] switchable models: {sorted(available)}", flush=True)

        uvicorn.run(app, host=HOST, port=PORT, log_level="info")
    else:
        worker_loop(_world.rank())

if __name__ == "__main__":
    main()

