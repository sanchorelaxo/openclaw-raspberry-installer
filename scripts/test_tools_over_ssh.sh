#!/usr/bin/env bash
set -euo pipefail

SSH_HOST=${SSH_HOST:-raspberrypi}
SSH_USER=${SSH_USER:-sanchobot}
SSH_PORT=${SSH_PORT:-22}
OPENCLAW_BIN=${OPENCLAW_BIN:-openclaw}
OPENCLAW_AGENT=${OPENCLAW_AGENT:-main}
OPENCLAW_CHANNEL=${OPENCLAW_CHANNEL:-last}
OPENCLAW_USE_LOCAL=${OPENCLAW_USE_LOCAL:-true}
OPENCLAW_SESSION_ID=${OPENCLAW_SESSION_ID:-tooltest-$(date +%s)}
MOLT_TEST_ENABLED=${MOLT_TEST_ENABLED:-false}
RAG_AGENT_TEST_ENABLED=${RAG_AGENT_TEST_ENABLED:-false}
AGENT_TIMEOUT_SECONDS=${AGENT_TIMEOUT_SECONDS:-240}
HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-120}
LOG_FOLLOW_ENABLED=${LOG_FOLLOW_ENABLED:-true}
LOG_FOLLOW_TIMEOUT_MS=${LOG_FOLLOW_TIMEOUT_MS:-1800000}
LOG_FOLLOW_OUTPUT=${LOG_FOLLOW_OUTPUT:-/tmp/openclaw_ssh_test_${OPENCLAW_SESSION_ID}.log}
LOG_TAIL_LINES=${LOG_TAIL_LINES:-80}
FAIL_DIAGNOSTIC_LOG_LIMIT=${FAIL_DIAGNOSTIC_LOG_LIMIT:-120}
FAIL_DIAGNOSTIC_JOURNAL_LINES=${FAIL_DIAGNOSTIC_JOURNAL_LINES:-120}
GATEWAY_PORT=${GATEWAY_PORT:-18789}
GATEWAY_RESTART_CHECK_ENABLED=${GATEWAY_RESTART_CHECK_ENABLED:-true}
GATEWAY_RESTART_WAIT_SECONDS=${GATEWAY_RESTART_WAIT_SECONDS:-1}
GATEWAY_LISTENER_RETRY_SECONDS=${GATEWAY_LISTENER_RETRY_SECONDS:-12}

SSH_CMD=(ssh -o ConnectTimeout=10 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}")
REMOTE_PATH_EXPORT='export PATH=$HOME/.npm-global/bin:$PATH'
OPENCLAW_REMOTE_BIN=""
REMOTE_HAS_TIMEOUT=false
LOG_FOLLOW_PID=""

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -f "$LOG_FOLLOW_OUTPUT" ]]; then
    printf '%s\n' "--- Last ${LOG_TAIL_LINES} lines of followed OpenClaw logs ---" >&2
    tail -n "$LOG_TAIL_LINES" "$LOG_FOLLOW_OUTPUT" >&2 || true
    printf '%s\n' "--- End followed OpenClaw logs ---" >&2
  fi
  print_remote_failure_diagnostics
  exit 1
}

run_ssh() {
  "${SSH_CMD[@]}" "$@"
}

print_remote_failure_diagnostics() {
  if [[ -z "${OPENCLAW_REMOTE_BIN:-}" ]]; then
    return 0
  fi

  printf '%s\n' "--- Remote gateway diagnostics ---" >&2
  run_ssh "systemctl --user show openclaw-gateway -p ActiveState -p SubState -p MainPID 2>/dev/null" \
    | sed 's/^/[diag] /' >&2 || true
  run_ssh "if command -v ss >/dev/null 2>&1; then ss -H -ltn | awk '\$4 ~ /:${GATEWAY_PORT}\$/ {count++} END{print count+0}'; else echo unavailable; fi" \
    | sed 's/^/[diag] listener-socket-count: /' >&2 || true
  run_ssh "if command -v ss >/dev/null 2>&1; then ss -H -ltnp | awk '\$4 ~ /:${GATEWAY_PORT}\$/ {print}'; else echo unavailable; fi" \
    | sed 's/^/[diag-ss] /' >&2 || true
  run_ssh "$REMOTE_PATH_EXPORT; $OPENCLAW_REMOTE_BIN logs --plain --limit $FAIL_DIAGNOSTIC_LOG_LIMIT" \
    | sed 's/^/[diag-openclaw-log] /' >&2 || true
  run_ssh "journalctl --user -u openclaw-gateway --no-pager -n $FAIL_DIAGNOSTIC_JOURNAL_LINES" \
    | sed 's/^/[diag-journal] /' >&2 || true
  printf '%s\n' "--- End remote gateway diagnostics ---" >&2
}

resolve_remote_environment() {
  OPENCLAW_REMOTE_BIN=$(run_ssh "$REMOTE_PATH_EXPORT; command -v $OPENCLAW_BIN 2>/dev/null || true" | head -n 1)
  if [[ -z "$OPENCLAW_REMOTE_BIN" ]]; then
    if run_ssh "test -x ~/.npm-global/bin/openclaw"; then
      OPENCLAW_REMOTE_BIN="~/.npm-global/bin/openclaw"
    else
      fail "openclaw binary not found on remote host"
    fi
  fi

  if run_ssh "command -v timeout >/dev/null 2>&1"; then
    REMOTE_HAS_TIMEOUT=true
  fi

  log "Using OpenClaw binary: $OPENCLAW_REMOTE_BIN"
}

run_openclaw() {
  local args="$1"
  run_ssh "$REMOTE_PATH_EXPORT; $OPENCLAW_REMOTE_BIN $args"
}

run_openclaw_timed() {
  local timeout_seconds="$1"
  shift
  local args="$*"
  local timeout_prefix=""
  if [[ "$REMOTE_HAS_TIMEOUT" == "true" ]]; then
    timeout_prefix="timeout ${timeout_seconds}s "
    run_ssh "$REMOTE_PATH_EXPORT; ${timeout_prefix}${OPENCLAW_REMOTE_BIN} ${args}"
    return
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" run_ssh "$REMOTE_PATH_EXPORT; ${OPENCLAW_REMOTE_BIN} ${args}"
  else
    warn "Neither remote nor local timeout is available; command may block"
    run_ssh "$REMOTE_PATH_EXPORT; ${OPENCLAW_REMOTE_BIN} ${args}"
  fi
}

run_agent() {
  local message="$1"
  local session_id="${2:-$OPENCLAW_SESSION_ID}"
  local message_escaped
  local timeout_prefix=""
  local agent_args=""
  if [[ "$REMOTE_HAS_TIMEOUT" == "true" ]]; then
    timeout_prefix="timeout ${AGENT_TIMEOUT_SECONDS}s "
  fi

  if [[ "$OPENCLAW_USE_LOCAL" == "true" ]]; then
    agent_args="agent --local --agent $OPENCLAW_AGENT --session-id $session_id --timeout $AGENT_TIMEOUT_SECONDS"
  else
    agent_args="agent --agent $OPENCLAW_AGENT --channel $OPENCLAW_CHANNEL --session-id $session_id --timeout $AGENT_TIMEOUT_SECONDS"
  fi

  message_escaped=$(printf '%q' "$message")
  if [[ "$REMOTE_HAS_TIMEOUT" == "true" ]]; then
    run_ssh "$REMOTE_PATH_EXPORT; ${timeout_prefix}${OPENCLAW_REMOTE_BIN} ${agent_args} --message $message_escaped"
    return
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${AGENT_TIMEOUT_SECONDS}s" run_ssh "$REMOTE_PATH_EXPORT; ${OPENCLAW_REMOTE_BIN} ${agent_args} --message $message_escaped"
  else
    warn "Neither remote nor local timeout is available; agent call may block"
    run_ssh "$REMOTE_PATH_EXPORT; ${OPENCLAW_REMOTE_BIN} ${agent_args} --message $message_escaped"
  fi
}

start_log_follow() {
  if [[ "$LOG_FOLLOW_ENABLED" != "true" ]]; then
    log "SKIP: live OpenClaw log follow disabled (LOG_FOLLOW_ENABLED=$LOG_FOLLOW_ENABLED)"
    return 0
  fi

  : > "$LOG_FOLLOW_OUTPUT"
  log "== Starting live OpenClaw logs follow =="
  (
    run_ssh "$REMOTE_PATH_EXPORT; $OPENCLAW_REMOTE_BIN logs --follow --plain --interval 1000 --timeout $LOG_FOLLOW_TIMEOUT_MS" \
      | sed 's/^/[openclaw-log] /'
  ) | tee -a "$LOG_FOLLOW_OUTPUT" >&2 &
  LOG_FOLLOW_PID=$!

  sleep 1
  if ! kill -0 "$LOG_FOLLOW_PID" 2>/dev/null; then
    warn "openclaw logs --follow exited early; continuing without live follow"
    LOG_FOLLOW_PID=""
    return 0
  fi

  log "PASS: following OpenClaw logs in background (pid ${LOG_FOLLOW_PID}, file ${LOG_FOLLOW_OUTPUT})"
}

stop_log_follow() {
  if [[ -n "$LOG_FOLLOW_PID" ]] && kill -0 "$LOG_FOLLOW_PID" 2>/dev/null; then
    kill "$LOG_FOLLOW_PID" 2>/dev/null || true
    wait "$LOG_FOLLOW_PID" 2>/dev/null || true
  fi
}

cleanup() {
  stop_log_follow
}

check_service_active() {
  local service_name="$1"
  if ! run_ssh "systemctl cat ${service_name} >/dev/null 2>&1"; then
    log "SKIP: ${service_name}.service not found"
    return 0
  fi
  if ! run_ssh "systemctl is-active --quiet ${service_name}"; then
    fail "${service_name}.service is installed but not active"
  fi
  log "PASS: ${service_name}.service is active"
}

check_gateway_restart_integrity() {
  if [[ "$GATEWAY_RESTART_CHECK_ENABLED" != "true" ]]; then
    log "SKIP: gateway restart integrity check disabled"
    return 0
  fi

  log "== Gateway restart integrity check =="

  local before_pid
  local after_pid
  local listener_count
  local listener_pid_count
  local waited_seconds=0

  before_pid=$(run_ssh "systemctl --user show openclaw-gateway -p MainPID --value 2>/dev/null || echo 0" | tr -d '[:space:]')

  if ! run_openclaw_timed "$HEALTH_TIMEOUT_SECONDS" "gateway restart" >/dev/null; then
    fail "openclaw gateway restart failed"
  fi

  sleep "$GATEWAY_RESTART_WAIT_SECONDS"

  if ! run_ssh "systemctl --user is-active --quiet openclaw-gateway"; then
    fail "openclaw-gateway.service is not active after restart"
  fi

  after_pid=$(run_ssh "systemctl --user show openclaw-gateway -p MainPID --value 2>/dev/null || echo 0" | tr -d '[:space:]')
  if [[ -z "$after_pid" || "$after_pid" == "0" ]]; then
    fail "openclaw-gateway MainPID is empty after restart"
  fi

  if [[ -n "$before_pid" && "$before_pid" != "0" && "$before_pid" == "$after_pid" ]]; then
    warn "Gateway PID unchanged after restart (${after_pid}); checking listener state"
  fi

  while true; do
    listener_count=$(run_ssh "if command -v ss >/dev/null 2>&1; then ss -H -ltn | awk '\$4 ~ /:${GATEWAY_PORT}\$/ {count++} END{print count+0}'; else echo unavailable; fi" | tr -d '[:space:]')
    if [[ "$listener_count" == "unavailable" || "$listener_count" -ge 1 ]]; then
      break
    fi
    if [[ "$waited_seconds" -ge "$GATEWAY_LISTENER_RETRY_SECONDS" ]]; then
      break
    fi
    sleep 1
    waited_seconds=$((waited_seconds + 1))
  done

  if [[ "$listener_count" == "unavailable" ]]; then
    warn "ss not available on remote host; skipping listener count validation"
  elif [[ "$listener_count" -lt 1 ]]; then
    fail "Expected at least one listener on port ${GATEWAY_PORT}, found ${listener_count}"
  fi

  listener_pid_count=$(run_ssh "if command -v ss >/dev/null 2>&1; then ss -H -ltnp | awk '\$4 ~ /:${GATEWAY_PORT}\$/ { if (match(\$0, /pid=[0-9]+/)) { pid = substr(\$0, RSTART + 4, RLENGTH - 4); pids[pid] = 1 } } END { count = 0; for (pid in pids) count++; print count+0 }'; else echo unavailable; fi" | tr -d '[:space:]')
  if [[ "$listener_pid_count" == "unavailable" ]]; then
    warn "ss -p not available on remote host; skipping listener PID validation"
  elif [[ "$listener_pid_count" -ne 1 ]]; then
    fail "Expected one process bound to port ${GATEWAY_PORT}, found ${listener_pid_count}"
  fi

  log "PASS: gateway restart verified (before PID=${before_pid:-unknown}, after PID=${after_pid}, listeners=${listener_count}, pids=${listener_pid_count})"
}

check_openclaw_health() {
  log "== OpenClaw health checks =="

  check_service_active "hailo-ollama"
  check_service_active "hailo-sanitize-proxy"
  check_gateway_restart_integrity

  local status_output
  if ! status_output=$(run_openclaw_timed "$HEALTH_TIMEOUT_SECONDS" "status --all"); then
    fail "openclaw status --all failed"
  fi
  if ! printf '%s' "$status_output" | grep -qi "Gateway service"; then
    fail "openclaw status output missing 'Gateway service' section"
  fi
  log "PASS: openclaw status --all completed"

  if ! run_openclaw_timed "$HEALTH_TIMEOUT_SECONDS" "gateway status" >/dev/null; then
    fail "openclaw gateway status failed"
  fi
  log "PASS: openclaw gateway status completed"

  local health_output
  if health_output=$(run_openclaw_timed "$HEALTH_TIMEOUT_SECONDS" "health" 2>&1); then
    log "PASS: openclaw health completed"
  else
    warn "openclaw health returned non-zero"
    printf '%s\n' "$health_output"
  fi
}

check_simple_openclaw_queries() {
  log "== OpenClaw simple query tests =="

  local response1
  if ! response1=$(run_agent "Reply with only OK." "${OPENCLAW_SESSION_ID}-simple-1"); then
    fail "Simple query #1 command failed or timed out"
  fi
  if ! printf '%s' "$response1" | grep -Eiq '(^|[^a-z0-9])ok([^a-z0-9]|$)'; then
    fail "Simple query #1 did not return OK"
  fi
  log "PASS: simple query #1 returned OK"

  local response2
  if ! response2=$(run_agent "What is 2+2? Reply with only the answer." "${OPENCLAW_SESSION_ID}-simple-2"); then
    fail "Simple query #2 command failed or timed out"
  fi
  if ! printf '%s' "$response2" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)'; then
    fail "Simple query #2 did not return expected answer"
  fi
  log "PASS: simple query #2 returned expected answer"
}

check_moltbook_tool() {
  log "== Moltbook tool test =="
  local state_file="~/.config/moltbook/heartbeat_state.json"

  if [[ "$MOLT_TEST_ENABLED" != "true" ]]; then
    log "SKIP: Moltbook tool test disabled (set MOLT_TEST_ENABLED=true to enable)"
    return 0
  fi

  if ! run_ssh "test -f ~/.config/moltbook/credentials.json"; then
    log "SKIP: ~/.config/moltbook/credentials.json not found"
    return 0
  fi

  local before
  before=$(run_ssh "test -f $state_file && stat -c %Y $state_file || echo 0")

  if ! run_agent "Use the molt_tools skill to run check_moltbook.py now. Reply with only OK once finished." "${OPENCLAW_SESSION_ID}-molt"; then
    fail "molt_tools/check_moltbook.py invocation failed or timed out"
  fi

  local after
  after=$(run_ssh "test -f $state_file && stat -c %Y $state_file || echo 0")

  if [[ "$after" -le "$before" ]]; then
    fail "molt_tools/check_moltbook.py did not update heartbeat_state.json"
  fi

  log "PASS: check_moltbook.py updated heartbeat_state.json"
}

check_rag_tool() {
  log "== RAG tool test =="
  local rag_query="~/.openclaw/rag_query.sh"
  local docs_source_file="~/.openclaw/workspace/skills/rag/.docs_source"
  local rag_query_py="~/.openclaw/rag/rag_query.py"

  if ! run_ssh "test -x $rag_query && test -f $rag_query_py"; then
    log "SKIP: RAG scripts not found ($rag_query / $rag_query_py)"
    return 0
  fi

  local rag_docs_dir
  rag_docs_dir=$(run_ssh "if test -s $docs_source_file; then head -n 1 $docs_source_file; else echo ~/.openclaw/rag_documents; fi" | head -n 1)
  if [[ -z "$rag_docs_dir" ]]; then
    rag_docs_dir="~/.openclaw/rag_documents"
  fi

  local rag_docs_dir_escaped
  rag_docs_dir_escaped=$(printf '%q' "$rag_docs_dir")

  local token_file
  local token
  local ts
  ts=$(date +%s)
  token=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)
  token_file="${rag_docs_dir}/tool_test_${ts}.md"

  local token_file_escaped
  token_file_escaped=$(printf '%q' "$token_file")

  run_ssh "mkdir -p ${rag_docs_dir_escaped} && printf 'MAGIC_TOKEN=%s\n' '$token' > ${token_file_escaped}"

  local direct_response
  if ! direct_response=$(run_ssh "bash -lc 'source ~/.openclaw/rag/venv/bin/activate && set -a && source ~/.openclaw/rag/.env && set +a && python3 ~/.openclaw/rag/rag_query.py \"Return only the token inside file tool_test_${ts}.md\"'"); then
    fail "Direct rag_query.py invocation failed"
  fi

  if ! printf '%s' "$direct_response" | grep -q "$token"; then
    fail "Direct rag_query.py output did not include expected token"
  fi

  log "PASS: direct rag_query.py returned expected token"

  if [[ "$RAG_AGENT_TEST_ENABLED" != "true" ]]; then
    log "SKIP: OpenClaw-agent RAG test disabled (set RAG_AGENT_TEST_ENABLED=true to enable)"
    return 0
  fi

  local response
  if ! response=$(run_agent "Use the RAG tool to read the document tool_test_${ts}.md from its configured docs source directory. Return ONLY the token inside that file." "${OPENCLAW_SESSION_ID}-rag"); then
    fail "RAG tool invocation failed or timed out"
  fi

  if ! printf '%s' "$response" | grep -q "$token"; then
    fail "RAG tool response did not include expected token"
  fi

  log "PASS: RAG tool returned expected token"
}

main() {
  log "Running tool verification over SSH (${SSH_USER}@${SSH_HOST}:${SSH_PORT})"
  trap cleanup EXIT INT TERM
  resolve_remote_environment
  start_log_follow

  check_openclaw_health
  check_simple_openclaw_queries

  check_moltbook_tool
  check_rag_tool

  log "All tests finished."
}

main "$@"
