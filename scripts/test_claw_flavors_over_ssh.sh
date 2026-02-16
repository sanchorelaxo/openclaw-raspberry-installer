#!/usr/bin/env bash
set -euo pipefail

SSH_HOST=${SSH_HOST:-raspberrypi}
SSH_USER=${SSH_USER:-sanchobot}
SSH_PORT=${SSH_PORT:-22}
REMOTE_REPO_DIR=${REMOTE_REPO_DIR:-/home/sanchobot/openclaw-raspberry-installer}
RUNTIME_PROFILE_REL=${RUNTIME_PROFILE_REL:-templates/unified-chat-runtime.json}
FACADE_REL=${FACADE_REL:-templates/unified-chat-facade.html}
RUN_ALL_FLAVORS=${RUN_ALL_FLAVORS:-false}
TEST_HAILO_MODEL=${TEST_HAILO_MODEL:-qwen2:1.5b}

SSH_CMD=(ssh -o ConnectTimeout=10 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}")

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

run_ssh() {
  "${SSH_CMD[@]}" "$@"
}

require_remote_file() {
  local rel="$1"
  run_ssh "test -f '$REMOTE_REPO_DIR/$rel'" || fail "Missing remote file: $REMOTE_REPO_DIR/$rel"
}

json_read_remote() {
  local rel="$1"
  local py="$2"
  run_ssh "python3 - <<'PY'
import json
p='$REMOTE_REPO_DIR/$rel'
obj=json.load(open(p))
$py
PY"
}

write_runtime_profile_for_flavor() {
  local flavor="$1"
  local runtime_path="$REMOTE_REPO_DIR/$RUNTIME_PROFILE_REL"

  case "$flavor" in
    openclaw)
      run_ssh "cat > '$runtime_path' <<'EOF'
{
  \"schemaVersion\": 1,
  \"flavor\": \"openclaw\",
  \"gatewayUrl\": \"ws://127.0.0.1:18789\",
  \"ollamaUrl\": \"http://127.0.0.1:8081/v1/chat/completions\",
  \"ollamaModel\": \"$TEST_HAILO_MODEL\",
  \"activeMode\": \"openclaw-dashboard\",
  \"extraModes\": []
}
EOF"
      ;;
    picoclaw)
      run_ssh "cat > '$runtime_path' <<'EOF'
{
  \"schemaVersion\": 1,
  \"flavor\": \"picoclaw\",
  \"gatewayUrl\": \"ws://127.0.0.1:18789\",
  \"ollamaUrl\": \"http://127.0.0.1:8081/v1/chat/completions\",
  \"ollamaModel\": \"$TEST_HAILO_MODEL\",
  \"activeMode\": \"picoclaw-local\",
  \"extraModes\": [
    {
      \"id\": \"picoclaw-local\",
      \"title\": \"PicoClaw Local\",
      \"subtitle\": \"PicoClaw + local Hailo model\",
      \"kind\": \"http-chat\",
      \"endpoint\": \"http://127.0.0.1:8081/v1/chat/completions\",
      \"model\": \"$TEST_HAILO_MODEL\"
    }
  ]
}
EOF"
      ;;
    zeroclaw)
      run_ssh "cat > '$runtime_path' <<'EOF'
{
  \"schemaVersion\": 1,
  \"flavor\": \"zeroclaw\",
  \"gatewayUrl\": \"ws://127.0.0.1:18789\",
  \"ollamaUrl\": \"http://127.0.0.1:8081/v1/chat/completions\",
  \"ollamaModel\": \"$TEST_HAILO_MODEL\",
  \"activeMode\": \"zeroclaw-local\",
  \"extraModes\": [
    {
      \"id\": \"zeroclaw-local\",
      \"title\": \"ZeroClaw Local\",
      \"subtitle\": \"ZeroClaw + local Hailo model\",
      \"kind\": \"http-chat\",
      \"endpoint\": \"http://127.0.0.1:8081/v1/chat/completions\",
      \"model\": \"$TEST_HAILO_MODEL\"
    }
  ]
}
EOF"
      ;;
    *)
      fail "Unsupported flavor for runtime profile write: $flavor"
      ;;
  esac
}

run_checks_for_current_profile_flavor() {
  check_profile_shape
  check_facade_runtime_support
  check_hailo_proxy_matrix
  check_flavor_binary_and_mode_alignment
  check_flavor_health_and_simple_queries
}

check_profile_shape() {
  require_remote_file "$RUNTIME_PROFILE_REL"

  local profile_summary
  profile_summary=$(json_read_remote "$RUNTIME_PROFILE_REL" 'flavor=obj.get("flavor"); active=obj.get("activeMode"); url=obj.get("ollamaUrl"); model=obj.get("ollamaModel"); extra=obj.get("extraModes") or []; print(f"flavor={flavor}\nactiveMode={active}\nollamaUrl={url}\nollamaModel={model}\nextraCount={len(extra)}")')
  log "$profile_summary"

  local flavor
  flavor=$(printf '%s\n' "$profile_summary" | awk -F= '/^flavor=/{print $2}')
  [[ "$flavor" =~ ^(openclaw|picoclaw|zeroclaw)$ ]] || fail "Invalid flavor in runtime profile: $flavor"

  local url
  url=$(printf '%s\n' "$profile_summary" | awk -F= '/^ollamaUrl=/{print $2}')
  [[ "$url" == http://127.0.0.1:8081/* || "$url" == http://127.0.0.1:8000/* ]] || fail "Unexpected ollamaUrl in runtime profile: $url"

  pass "Runtime profile exists and has expected shape"
}

check_facade_runtime_support() {
  require_remote_file "$FACADE_REL"
  run_ssh "grep -q 'loadRuntimeProfile' '$REMOTE_REPO_DIR/$FACADE_REL'" || fail "Facade missing loadRuntimeProfile()"
  run_ssh "grep -q 'http-chat' '$REMOTE_REPO_DIR/$FACADE_REL'" || fail "Facade missing http-chat mode support"
  pass "Facade contains runtime profile + conditional mode logic"
}

check_hailo_proxy_matrix() {
  local matrix
  matrix=$(run_ssh 'python3 - <<"PY"
import json, urllib.request

def post(url, payload):
    data=json.dumps(payload).encode()
    req=urllib.request.Request(url, data=data, method="POST", headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, r.read().decode(errors="replace")
    except Exception as e:
        if hasattr(e, "code"):
            try:
                body=e.read().decode(errors="replace")
            except Exception:
                body=str(e)
            return e.code, body
        return 599, str(e)

base="http://127.0.0.1:8000"
proxy="http://127.0.0.1:8081"
min_payload={"model":"qwen2:1.5b","messages":[{"role":"user","content":"Reply OK"}],"stream":False}
oc_like={"model":"qwen2:1.5b","messages":[{"role":"system","content":"You are helper"},{"role":"user","content":"hi"}],"stream":True,"stream_options":{"include_usage":True},"store":True,"tools":[{"type":"function","function":{"name":"read_file","description":"read files","parameters":{"type":"object","properties":{}}}}],"max_completion_tokens":2048}
show_payload={"name":"qwen2:1.5b"}

rows=[]
for name,url,p in [
  ("direct_min", base+"/v1/chat/completions", min_payload),
  ("proxy_min", proxy+"/v1/chat/completions", min_payload),
  ("direct_oc_like", base+"/v1/chat/completions", oc_like),
  ("proxy_oc_like", proxy+"/v1/chat/completions", oc_like),
  ("direct_show", base+"/api/show", show_payload),
  ("proxy_show", proxy+"/api/show", show_payload),
]:
    status, body = post(url,p)
    rows.append((name,status,body[:120].replace("\n"," ")))

for n,s,b in rows:
    print(f"{n}|{s}|{b}")
PY')
  log "$matrix"

  local direct_oc_status direct_show_status proxy_oc_status proxy_show_status
  direct_oc_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^direct_oc_like\|/{print $2}')
  direct_show_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^direct_show\|/{print $2}')
  proxy_oc_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^proxy_oc_like\|/{print $2}')
  proxy_show_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^proxy_show\|/{print $2}')

  [[ "$proxy_oc_status" == "200" ]] || fail "Proxy OpenClaw-like chat failed (status=$proxy_oc_status)"
  [[ "$proxy_show_status" == "200" ]] || fail "Proxy /api/show failed (status=$proxy_show_status)"

  if [[ "$direct_oc_status" != "200" || "$direct_show_status" != "200" ]]; then
    pass "Proxy required signal confirmed for OpenClaw-like traffic"
  else
    warn "Direct endpoint also passed OpenClaw-like checks; proxy may be optional"
  fi
}

check_flavor_binary_and_mode_alignment() {
  local flavor
  flavor=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(obj.get("flavor",""))' | tr -d '[:space:]')

  case "$flavor" in
    openclaw)
      run_ssh "test -x ~/.npm-global/bin/openclaw || command -v openclaw >/dev/null 2>&1" || fail "OpenClaw binary missing"
      pass "OpenClaw flavor aligned with installed binary"
      ;;
    picoclaw)
      run_ssh "test -x ~/.local/bin/picoclaw || command -v picoclaw >/dev/null 2>&1" || fail "PicoClaw binary missing"
      local extra_count
      extra_count=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(len(obj.get("extraModes") or []))' | tr -d '[:space:]')
      [[ "$extra_count" -ge 1 ]] || fail "PicoClaw profile missing conditional extra modes"
      pass "PicoClaw flavor aligned with runtime profile and binary"
      ;;
    zeroclaw)
      run_ssh "test -x ~/.local/bin/zeroclaw || command -v zeroclaw >/dev/null 2>&1" || fail "ZeroClaw binary missing"
      local extra_count
      extra_count=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(len(obj.get("extraModes") or []))' | tr -d '[:space:]')
      [[ "$extra_count" -ge 1 ]] || fail "ZeroClaw profile missing conditional extra modes"
      pass "ZeroClaw flavor aligned with runtime profile and binary"
      ;;
    *)
      fail "Unknown flavor from profile: $flavor"
      ;;
  esac
}

check_flavor_health_and_simple_queries() {
  local flavor
  flavor=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(obj.get("flavor",""))' | tr -d '[:space:]')

  case "$flavor" in
    openclaw)
      log "== OpenClaw health + simple query checks =="
      run_ssh 'test -x ~/.npm-global/bin/openclaw || command -v openclaw >/dev/null 2>&1' || fail "OpenClaw binary missing for health checks"

      run_ssh 'PATH=$HOME/.npm-global/bin:$PATH; openclaw status --all >/tmp/openclaw_status.out 2>&1' || fail "openclaw status --all failed"
      run_ssh "grep -qi 'Gateway service' /tmp/openclaw_status.out" || fail "openclaw status output missing 'Gateway service'"

      run_ssh 'PATH=$HOME/.npm-global/bin:$PATH; openclaw health >/tmp/openclaw_health.out 2>&1 || true'

      local response1 response2
      response1=$(run_ssh 'PATH=$HOME/.npm-global/bin:$PATH; openclaw agent --local --agent main --session-id flavortest-openclaw-1 --timeout 120 --message "Reply with only OK."') || fail "OpenClaw simple query #1 failed"
      printf '%s\n' "$response1" | grep -Eiq '(^|[^a-z0-9])ok([^a-z0-9]|$)' || fail "OpenClaw simple query #1 did not return OK"

      response2=$(run_ssh 'PATH=$HOME/.npm-global/bin:$PATH; openclaw agent --local --agent main --session-id flavortest-openclaw-2 --timeout 120 --message "What is 2+2? Reply with only the answer."') || fail "OpenClaw simple query #2 failed"
      printf '%s\n' "$response2" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "OpenClaw simple query #2 did not return expected answer"

      pass "OpenClaw health + simple query checks passed"
      ;;
    picoclaw)
      log "== PicoClaw health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/picoclaw || command -v picoclaw >/dev/null 2>&1' || fail "PicoClaw binary missing for health checks"

      local pico_status
      pico_status=$(run_ssh '~/.local/bin/picoclaw status') || fail "picoclaw status failed"
      printf '%s\n' "$pico_status" | grep -qi 'Config:' || fail "picoclaw status output missing config info"

      local pico_response1 pico_response2
      pico_response1=$(run_ssh '~/.local/bin/picoclaw agent --message "Reply with only OK."') || fail "PicoClaw simple query #1 failed"
      printf '%s\n' "$pico_response1" | grep -Eiq '(^|[^a-z0-9])ok([^a-z0-9]|$)' || fail "PicoClaw simple query #1 did not return OK"

      pico_response2=$(run_ssh '~/.local/bin/picoclaw agent --message "What is 2+2? Reply with only the answer."') || fail "PicoClaw simple query #2 failed"
      printf '%s\n' "$pico_response2" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "PicoClaw simple query #2 did not return expected answer"

      pass "PicoClaw health + simple query checks passed"
      ;;
    zeroclaw)
      log "== ZeroClaw health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/zeroclaw || command -v zeroclaw >/dev/null 2>&1' || fail "ZeroClaw binary missing for health checks"

      local zero_status
      zero_status=$(run_ssh '~/.local/bin/zeroclaw status') || fail "zeroclaw status failed"
      printf '%s\n' "$zero_status" | grep -Eiq '(provider|status|gateway)' || fail "zeroclaw status output missing expected sections"

      local zero_response1 zero_response2 attempt

      for attempt in 1 2 3; do
        zero_response1=$(run_ssh '~/.local/bin/zeroclaw agent --provider "custom:http://127.0.0.1:8081/v1" --model qwen2:1.5b --message "What is 2+2? Reply with only the answer."') || fail "ZeroClaw simple query #1 failed"
        if printf '%s\n' "$zero_response1" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)'; then
          break
        fi
        [[ "$attempt" -lt 3 ]] && warn "ZeroClaw simple query #1 attempt $attempt did not match expected answer; retrying..."
      done
      printf '%s\n' "$zero_response1" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "ZeroClaw simple query #1 did not return expected answer"

      for attempt in 1 2 3; do
        zero_response2=$(run_ssh '~/.local/bin/zeroclaw agent --provider "custom:http://127.0.0.1:8081/v1" --model qwen2:1.5b --message "What is 3+3? Reply with only the answer."') || fail "ZeroClaw simple query #2 failed"
        if printf '%s\n' "$zero_response2" | grep -Eiq '(^|[^a-z0-9])(6|six)([^a-z0-9]|$)'; then
          break
        fi
        [[ "$attempt" -lt 3 ]] && warn "ZeroClaw simple query #2 attempt $attempt did not match expected answer; retrying..."
      done
      printf '%s\n' "$zero_response2" | grep -Eiq '(^|[^a-z0-9])(6|six)([^a-z0-9]|$)' || fail "ZeroClaw simple query #2 did not return expected answer"

      pass "ZeroClaw health + simple query checks passed"
      ;;
    *)
      fail "Unknown flavor from profile: $flavor"
      ;;
  esac
}

main() {
  log "Running cross-flavor verification over SSH (${SSH_USER}@${SSH_HOST}:${SSH_PORT})"

  if [[ "$RUN_ALL_FLAVORS" == "true" ]]; then
    local flavor
    for flavor in openclaw picoclaw zeroclaw; do
      log "==== Testing flavor: $flavor ===="
      write_runtime_profile_for_flavor "$flavor"
      run_checks_for_current_profile_flavor
    done
  else
    run_checks_for_current_profile_flavor
  fi

  pass "All cross-flavor checks passed"
}

main "$@"
