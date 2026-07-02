#!/usr/bin/env bash
# Fake mlx.launch for exercising ProcessSupervisor / ServerController without MLX.
#
# Usage: fake_mlx_launch.sh <mode>
#   clean        emit the full startup log sequence, then run until SIGTERM (exit 0)
#   fail         emit a partial log then exit 1 (crash path)
#   ignore-term  like clean, but traps and ignores SIGTERM (forces SIGKILL escalation)
#   slow-load    sleep 30s before the first milestone (loadingModel with no timeout)
set -u
MODE="${1:-clean}"

emit_startup() {
  echo "[rank0] control-plane listening on 0.0.0.0:18080"
  echo "[rank0] all workers connected"
  echo "INFO:     Application startup complete."
}

case "$MODE" in
  fail)
    echo "loading model shards..."
    echo "Traceback (most recent call last): something broke" >&2
    exit 1
    ;;
  ignore-term)
    trap '' TERM
    emit_startup
    while true; do sleep 1; echo "tick"; done
    ;;
  slow-load)
    echo "loading model shards..."
    sleep 30
    emit_startup
    while true; do sleep 1; done
    ;;
  clean|*)
    echo "loading model shards..."
    sleep 1
    emit_startup
    trap 'echo "terminating"; exit 0' TERM
    while true; do sleep 1; done
    ;;
esac
