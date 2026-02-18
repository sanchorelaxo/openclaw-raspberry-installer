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
    nanobot)
      run_ssh "cat > '$runtime_path' <<'EOF'
{
  \"schemaVersion\": 1,
  \"flavor\": \"nanobot\",
  \"gatewayUrl\": \"ws://127.0.0.1:18789\",
  \"ollamaUrl\": \"http://127.0.0.1:8081/v1/chat/completions\",
  \"ollamaModel\": \"$TEST_HAILO_MODEL\",
  \"activeMode\": \"nanobot-local\",
  \"extraModes\": [
    {
      \"id\": \"nanobot-local\",
      \"title\": \"Nanobot Local\",
      \"subtitle\": \"Nanobot + local Hailo model\",
      \"kind\": \"http-chat\",
      \"endpoint\": \"http://127.0.0.1:8081/v1/chat/completions\",
      \"model\": \"$TEST_HAILO_MODEL\"
    }
  ]
}
EOF"
      ;;
    moltis)
      run_ssh "cat > '$runtime_path' <<'EOF'
{
  \"schemaVersion\": 1,
  \"flavor\": \"moltis\",
  \"gatewayUrl\": \"ws://127.0.0.1:18789\",
  \"ollamaUrl\": \"http://127.0.0.1:8081/v1/chat/completions\",
  \"ollamaModel\": \"$TEST_HAILO_MODEL\",
  \"activeMode\": \"moltis-local\",
  \"extraModes\": [
    {
      \"id\": \"moltis-local\",
      \"title\": \"Moltis Local\",
      \"subtitle\": \"Moltis + local Hailo model\",
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
  check_facade_chat_intermediary
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
  [[ "$flavor" =~ ^(openclaw|picoclaw|zeroclaw|nanobot|moltis)$ ]] || fail "Invalid flavor in runtime profile: $flavor"

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

check_facade_chat_intermediary() {
  local probe
  probe=$(run_ssh "python3 - <<'PY'
import json, re, urllib.request

runtime_path = '$REMOTE_REPO_DIR/$RUNTIME_PROFILE_REL'
facade_url = 'http://127.0.0.1:8787/$FACADE_REL'

def get(url):
    req = urllib.request.Request(url, method='GET')
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, r.read().decode(errors='replace')
    except Exception as e:
        if hasattr(e, 'code'):
            try:
                body = e.read().decode(errors='replace')
            except Exception:
                body = str(e)
            return e.code, body
        return 599, str(e)

def post(url, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method='POST', headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode(errors='replace')
    except Exception as e:
        if hasattr(e, 'code'):
            try:
                body = e.read().decode(errors='replace')
            except Exception:
                body = str(e)
            return e.code, body
        return 599, str(e)

def response_text(body):
    try:
        obj = json.loads(body)
    except Exception:
        return body
    if not isinstance(obj, dict):
        return body
    choices = obj.get('choices')
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            msg = first.get('message')
            if isinstance(msg, dict):
                return str(msg.get('content', ''))
            return str(first.get('text', ''))
    return str(obj)

facade_status, facade_body = get(facade_url)
print(f'facade_status|{facade_status}')
print(f'facade_body_preview|{facade_body[:80].replace(chr(10), chr(32))}')

if facade_status != 200:
    raise SystemExit(2)

cfg = json.load(open(runtime_path))
endpoint = cfg.get('ollamaUrl')
model = cfg.get('ollamaModel')
active = cfg.get('activeMode')

for mode in cfg.get('extraModes') or []:
    if not isinstance(mode, dict):
        continue
    if mode.get('id') == active and mode.get('kind') == 'http-chat':
        endpoint = mode.get('endpoint') or endpoint
        model = mode.get('model') or model
        break

if not endpoint or not model:
    raise SystemExit(3)

print(f'facade_chat_endpoint|{endpoint}')
print(f'facade_chat_model|{model}')

tests = [
    ('ok', 'Reply with only OK.', r'(^|[^a-z0-9])ok([^a-z0-9]|$)'),
    ('math', 'What is 2+2? Reply with only the answer.', r'(^|[^a-z0-9])(4|four)([^a-z0-9]|$)'),
]

for label, prompt, pattern in tests:
    status, body = post(endpoint, {
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'stream': False,
    })
    text = response_text(body)
    normalized = str(text).strip().lower()
    print(f'{label}_status|{status}')
    print(f'{label}_preview|{normalized[:80].replace(chr(10), chr(32))}')
    if status != 200:
        raise SystemExit(10)
    if not re.search(pattern, normalized):
        raise SystemExit(11)
PY") || fail "Facade chat intermediary checks failed"

  log "$probe"
  pass "Facade HTTP chat intermediary checks passed"
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

def get(url):
    req=urllib.request.Request(url, method="GET")
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
api_chat_payload={"model":"qwen2:1.5b","messages":[{"role":"user","content":"Reply OK"}],"stream":False}
oc_like={"model":"qwen2:1.5b","messages":[{"role":"system","content":"You are helper"},{"role":"user","content":"hi"}],"stream":True,"stream_options":{"include_usage":True},"store":True,"tools":[{"type":"function","function":{"name":"read_file","description":"read files","parameters":{"type":"object","properties":{}}}}],"max_completion_tokens":2048}
show_payload={"name":"qwen2:1.5b"}

rows=[]
for name,url,p in [
  ("direct_min", base+"/v1/chat/completions", min_payload),
  ("proxy_min", proxy+"/v1/chat/completions", min_payload),
  ("direct_api_chat", base+"/api/chat", api_chat_payload),
  ("proxy_oc_like", proxy+"/v1/chat/completions", oc_like),
  ("proxy_show", proxy+"/api/show", show_payload),
]:
    status, body = post(url,p)
    rows.append((name,status,body[:120].replace("\n"," ")))

for name, url in [
  ("proxy_models", proxy+"/v1/models"),
]:
    status, body = get(url)
    rows.append((name, status, body[:120].replace("\n", " ")))

for n,s,b in rows:
    print(f"{n}|{s}|{b}")
PY')
  log "$matrix"

  local direct_api_chat_status proxy_min_status proxy_oc_status proxy_show_status proxy_models_status
  direct_api_chat_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^direct_api_chat\|/{print $2}')
  proxy_min_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^proxy_min\|/{print $2}')
  proxy_oc_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^proxy_oc_like\|/{print $2}')
  proxy_show_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^proxy_show\|/{print $2}')
  proxy_models_status=$(printf '%s\n' "$matrix" | awk -F'|' '/^proxy_models\|/{print $2}')

  [[ "$proxy_min_status" == "200" ]] || fail "Proxy minimal chat failed (status=$proxy_min_status)"
  [[ "$proxy_oc_status" == "200" ]] || fail "Proxy OpenClaw-like chat failed (status=$proxy_oc_status)"
  [[ "$proxy_show_status" == "200" ]] || fail "Proxy /api/show failed (status=$proxy_show_status)"
  [[ "$proxy_models_status" == "200" ]] || fail "Proxy /v1/models failed (status=$proxy_models_status)"

  [[ "$direct_api_chat_status" == "200" ]] || warn "Direct /api/chat returned non-200 (status=$direct_api_chat_status)"
  pass "Proxy OpenClaw-like compatibility checks passed"
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
    nanobot)
      run_ssh "test -x ~/.local/bin/nanobot || command -v nanobot >/dev/null 2>&1" || fail "Nanobot binary missing"
      local extra_count
      extra_count=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(len(obj.get("extraModes") or []))' | tr -d '[:space:]')
      [[ "$extra_count" -ge 1 ]] || fail "Nanobot profile missing conditional extra modes"
      pass "Nanobot flavor aligned with runtime profile and binary"
      ;;
    moltis)
      run_ssh "test -x ~/.local/bin/moltis || command -v moltis >/dev/null 2>&1" || fail "Moltis binary missing"
      local extra_count
      extra_count=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(len(obj.get("extraModes") or []))' | tr -d '[:space:]')
      [[ "$extra_count" -ge 1 ]] || fail "Moltis profile missing conditional extra modes"
      pass "Moltis flavor aligned with runtime profile and binary"
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

      log "OpenClaw local queries may take ~20-40s each on Hailo; waiting for completion..."

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
    nanobot)
      log "== Nanobot health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/nanobot || command -v nanobot >/dev/null 2>&1' || fail "Nanobot binary missing for health checks"

      local nanobot_status
      nanobot_status=$(run_ssh '~/.local/bin/nanobot status') || fail "nanobot status failed"
      printf '%s\n' "$nanobot_status" | grep -Eiq '(Config:|Model:)' || fail "nanobot status output missing expected info"

      local nanobot_response1 nanobot_response2
      nanobot_response1=$(run_ssh '~/.local/bin/nanobot agent --message "Reply with only OK."') || fail "Nanobot simple query #1 failed"
      printf '%s\n' "$nanobot_response1" | grep -Eiq '(^|[^a-z0-9])ok([^a-z0-9]|$)' || fail "Nanobot simple query #1 did not return OK"

      nanobot_response2=$(run_ssh '~/.local/bin/nanobot agent --message "What is 2+2? Reply with only the answer."') || fail "Nanobot simple query #2 failed"
      printf '%s\n' "$nanobot_response2" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "Nanobot simple query #2 did not return expected answer"

      pass "Nanobot health + simple query checks passed"
      ;;
    moltis)
      log "== Moltis health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/moltis || command -v moltis >/dev/null 2>&1' || fail "Moltis binary missing for health checks"

      local moltis_doctor
      moltis_doctor=$(run_ssh '~/.local/bin/moltis --log-level error doctor 2>&1') || fail "moltis doctor failed"
      printf '%s\n' "$moltis_doctor" | grep -Eiq '(providers|ollama)' || fail "moltis doctor output missing provider info"

      local moltis_probe
      moltis_probe=$(run_ssh "python3 - <<'PY'
import json, os, re, urllib.request

try:
    import tomllib
except Exception:
    import tomli as tomllib

cfg_path = os.path.expanduser('~/.config/moltis/moltis.toml')
cfg = tomllib.load(open(cfg_path, 'rb'))

ollama = ((cfg.get('providers') or {}).get('ollama') or {})
base_url = str(ollama.get('base_url') or '').rstrip('/')
models = ollama.get('models') or []
model = models[0] if isinstance(models, list) and models else None

if not base_url or not model:
    raise SystemExit(3)

if base_url.endswith('/v1/chat/completions'):
    endpoint = base_url
elif base_url.endswith('/v1'):
    endpoint = f'{base_url}/chat/completions'
else:
    endpoint = f'{base_url}/v1/chat/completions'

print(f'moltis_base_url|{base_url}')
print(f'moltis_endpoint|{endpoint}')
print(f'moltis_model|{model}')

def post(prompt):
    payload = {
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'stream': False,
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(endpoint, data=data, method='POST', headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode(errors='replace')
    except Exception as e:
        if hasattr(e, 'code'):
            try:
                body = e.read().decode(errors='replace')
            except Exception:
                body = str(e)
            return e.code, body
        return 599, str(e)

def response_text(body):
    try:
        obj = json.loads(body)
    except Exception:
        return body
    if not isinstance(obj, dict):
        return body
    choices = obj.get('choices')
    if isinstance(choices, list) and choices:
        first = choices[0]
        if isinstance(first, dict):
            msg = first.get('message')
            if isinstance(msg, dict):
                return str(msg.get('content', ''))
            return str(first.get('text', ''))
    return str(obj)

tests = [
    ('ok', 'Reply with only OK.', r'(^|[^a-z0-9])ok([^a-z0-9]|$)'),
    ('math', 'What is 2+2? Reply with only the answer.', r'(^|[^a-z0-9])(4|four)([^a-z0-9]|$)'),
]

for label, prompt, pattern in tests:
    status, body = post(prompt)
    text = response_text(body)
    normalized = str(text).strip().lower()
    print(f'{label}_status|{status}')
    print(f'{label}_preview|{normalized[:80].replace(chr(10), chr(32))}')
    if status != 200:
        raise SystemExit(10)
    if not re.search(pattern, normalized):
        raise SystemExit(11)
PY") || fail "Moltis config-based chat probe failed"

      log "$moltis_probe"

      pass "Moltis health + simple query checks passed"
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
    for flavor in openclaw picoclaw zeroclaw nanobot moltis; do
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
