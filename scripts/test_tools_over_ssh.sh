#!/usr/bin/env bash
set -euo pipefail

SSH_HOST=${SSH_HOST:-raspberrypi}
SSH_USER=${SSH_USER:-sanchobot}
SSH_PORT=${SSH_PORT:-22}
OPENCLAW_BIN=${OPENCLAW_BIN:-openclaw}
OPENCLAW_AGENT=${OPENCLAW_AGENT:-main}
OPENCLAW_SESSION_ID=${OPENCLAW_SESSION_ID:-tooltest-$(date +%s)}

SSH_CMD=(ssh -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}")
REMOTE_PATH_EXPORT='export PATH=$HOME/.npm-global/bin:$PATH'

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_ssh() {
  "${SSH_CMD[@]}" "$@"
}

run_agent() {
  local message="$1"
  local message_escaped
  message_escaped=$(printf '%q' "$message")
  run_ssh "$REMOTE_PATH_EXPORT; $OPENCLAW_BIN agent --agent $OPENCLAW_AGENT --session-id $OPENCLAW_SESSION_ID --message $message_escaped"
}

check_moltbook_tool() {
  log "== Moltbook tool test =="
  local state_file="~/.config/moltbook/heartbeat_state.json"

  if ! run_ssh "test -f ~/.config/moltbook/credentials.json"; then
    log "SKIP: ~/.config/moltbook/credentials.json not found"
    return 0
  fi

  local before
  before=$(run_ssh "test -f $state_file && stat -c %Y $state_file || echo 0")

  run_agent "Use the molt_tools skill to run check_moltbook.py now. Reply with only OK once finished."

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

  if ! run_ssh "test -x $rag_query"; then
    log "SKIP: $rag_query not found or not executable"
    return 0
  fi

  local token_file
  local token
  local ts
  ts=$(date +%s)
  token=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)
  token_file="~/.openclaw/rag_documents/tool_test_${ts}.txt"

  run_ssh "mkdir -p ~/.openclaw/rag_documents && printf '%s\n' '$token' > $token_file"

  local response
  response=$(run_agent "Use the RAG tool to read the document tool_test_${ts}.txt in the RAG documents directory. Return ONLY the token inside that file.")

  if ! printf '%s' "$response" | grep -q "$token"; then
    fail "RAG tool response did not include expected token"
  fi

  log "PASS: RAG tool returned expected token"
}

main() {
  log "Running tool verification over SSH (${SSH_USER}@${SSH_HOST}:${SSH_PORT})"
  run_ssh "$REMOTE_PATH_EXPORT; command -v $OPENCLAW_BIN" >/dev/null

  check_moltbook_tool
  check_rag_tool

  log "All tests finished."
}

main "$@"
