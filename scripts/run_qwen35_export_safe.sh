#!/usr/bin/env bash
set -euo pipefail

# Non-interactive runner for Qwen3.5 ONNX export.
# Prevents terminal flooding by running export detached with persistent logs.
#
# Usage:
#   bash scripts/run_qwen35_export_safe.sh start
#   bash scripts/run_qwen35_export_safe.sh status
#   bash scripts/run_qwen35_export_safe.sh tail
#   bash scripts/run_qwen35_export_safe.sh stop
#
# Optional env vars:
#   MODEL_HF_ID=Qwen/Qwen3.5-0.8B
#   OUTPUT_DIR=/abs/path/onnx_export/qwen3.5-0.8b
#   EXPORT_ONNX_PATH=/abs/path/onnx_export/qwen3.5-0.8b/model.onnx

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.run/qwen35_export"
PID_FILE="$RUNTIME_DIR/export.pid"
STATE_FILE="$RUNTIME_DIR/export.state"
LOG_FILE="$RUNTIME_DIR/export.log"
CMD_FILE="$RUNTIME_DIR/export.cmd"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-10485760}"

ACTION="${1:-status}"

mkdir -p "$RUNTIME_DIR"

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_export() {
  if is_running; then
    log "Export already running (pid=$(cat "$PID_FILE"))."
    log "Log: $LOG_FILE"
    return 0
  fi

  if [[ -f "$LOG_FILE" ]]; then
    local current_size
    current_size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
    if [[ "$current_size" -gt "$MAX_LOG_BYTES" ]]; then
      mv "$LOG_FILE" "$LOG_FILE.$(date +%s).bak"
    fi
  fi

  local cmd
  cmd="cd '$REPO_ROOT' && \
MODEL_HF_ID='${MODEL_HF_ID:-Qwen/Qwen3.5-0.8B}' \
OUTPUT_DIR='${OUTPUT_DIR:-$REPO_ROOT/onnx_export/qwen3.5-0.8b}' \
EXPORT_ONNX_PATH='${EXPORT_ONNX_PATH:-${OUTPUT_DIR:-$REPO_ROOT/onnx_export/qwen3.5-0.8b}/model.onnx}' \
HF_HUB_DISABLE_PROGRESS_BARS=1 \
TRANSFORMERS_VERBOSITY=error \
TOKENIZERS_PARALLELISM=false \
bash scripts/export_qwen35_to_onnx.sh"

  printf '%s\n' "$cmd" > "$CMD_FILE"
  printf 'starting\n' > "$STATE_FILE"

  nohup bash -lc "
set -euo pipefail
printf '[%s] START\n' \"\$(date -Is)\" >> '$LOG_FILE'
printf '%s\n' \"$cmd\" >> '$LOG_FILE'
if bash -lc \"$cmd\" >> '$LOG_FILE' 2>&1; then
  printf '[%s] SUCCESS\n' \"\$(date -Is)\" >> '$LOG_FILE'
  printf 'success\n' > '$STATE_FILE'
else
  rc=\$?
  printf '[%s] FAIL rc=%s\n' \"\$(date -Is)\" \"\$rc\" >> '$LOG_FILE'
  printf 'failed rc=%s\n' \"\$rc\" > '$STATE_FILE'
fi
" >/dev/null 2>&1 &

  local pid
  pid="$!"
  printf '%s\n' "$pid" > "$PID_FILE"

  log "Started export in background (pid=$pid)."
  log "State: $STATE_FILE"
  log "Log:   $LOG_FILE"
  log "Tail:  bash scripts/run_qwen35_export_safe.sh tail"
}

show_status() {
  local state
  state="unknown"
  if [[ -f "$STATE_FILE" ]]; then
    state="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
  fi

  if is_running; then
    log "status=running pid=$(cat "$PID_FILE") state=$state"
  else
    log "status=stopped state=$state"
  fi

  log "log=$LOG_FILE"
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 10 "$LOG_FILE" || true
  fi
}

tail_log() {
  [[ -f "$LOG_FILE" ]] || fail "Log file not found: $LOG_FILE"
  tail -f "$LOG_FILE"
}

stop_export() {
  if ! is_running; then
    log "No running export process."
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true

  for _ in 1 2 3 4 5; do
    if kill -0 "$pid" 2>/dev/null; then
      sleep 1
    else
      break
    fi
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi

  printf 'stopped\n' > "$STATE_FILE"
  rm -f "$PID_FILE"
  log "Stopped export process pid=$pid"
}

case "$ACTION" in
  start) start_export ;;
  status) show_status ;;
  tail) tail_log ;;
  stop) stop_export ;;
  *) fail "Unknown action: $ACTION (use start|status|tail|stop)" ;;
esac
