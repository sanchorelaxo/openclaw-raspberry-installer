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
FLAVORS_TO_TEST=${FLAVORS_TO_TEST:-picoclaw zeroclaw nanobot moltis ironclaw openclaw}

SSH_CMD=(ssh -o ConnectTimeout=10 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}")

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

declare -a QUERY_TIMING_FLAVORS=()
declare -A QUERY_TIMING_QUERY1_SECONDS=()
declare -A QUERY_TIMING_QUERY2_SECONDS=()
declare -A QUERY_TIMING_TOTAL_SECONDS=()

TIMED_LAST_SECONDS=0

run_timed_remote_command() {
  local __output_var="$1"
  shift

  local started ended output status
  started=$(date +%s)

  set +e
  output=$(run_ssh "$@")
  status=$?
  set -e

  ended=$(date +%s)
  TIMED_LAST_SECONDS=$((ended - started))

  printf -v "$__output_var" '%s' "$output"
  return "$status"
}

add_query_timing_flavor() {
  local flavor="$1"
  local existing
  for existing in "${QUERY_TIMING_FLAVORS[@]}"; do
    [[ "$existing" == "$flavor" ]] && return 0
  done
  QUERY_TIMING_FLAVORS+=("$flavor")
}

record_flavor_query_timing() {
  local flavor="$1"
  local query1_seconds="$2"
  local query2_seconds="$3"
  local total_seconds=$((query1_seconds + query2_seconds))

  QUERY_TIMING_QUERY1_SECONDS["$flavor"]="$query1_seconds"
  QUERY_TIMING_QUERY2_SECONDS["$flavor"]="$query2_seconds"
  QUERY_TIMING_TOTAL_SECONDS["$flavor"]="$total_seconds"
  add_query_timing_flavor "$flavor"
}

print_query_timing_table() {
  if [[ "${#QUERY_TIMING_FLAVORS[@]}" -eq 0 ]]; then
    warn "No flavor query timing data collected"
    return
  fi

  log ""
  log "=== Flavor query timing comparison (seconds) ==="
  printf '%-10s | %9s | %9s | %9s\n' "Flavor" "Query #1" "Query #2" "Total"
  printf '%-10s-+-%9s-+-%9s-+-%9s\n' "----------" "---------" "---------" "---------"

  local flavor
  for flavor in "${QUERY_TIMING_FLAVORS[@]}"; do
    printf '%-10s | %9s | %9s | %9s\n' \
      "$flavor" \
      "${QUERY_TIMING_QUERY1_SECONDS[$flavor]:-N/A}" \
      "${QUERY_TIMING_QUERY2_SECONDS[$flavor]:-N/A}" \
      "${QUERY_TIMING_TOTAL_SECONDS[$flavor]:-N/A}"
  done
}

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
    ironclaw)
      run_ssh "cat > '$runtime_path' <<'EOF'
{
  \"schemaVersion\": 1,
  \"flavor\": \"ironclaw\",
  \"gatewayUrl\": \"ws://127.0.0.1:18789\",
  \"ollamaUrl\": \"http://127.0.0.1:8081/v1/chat/completions\",
  \"ollamaModel\": \"$TEST_HAILO_MODEL\",
  \"activeMode\": \"ironclaw-local\",
  \"extraModes\": [
    {
      \"id\": \"ironclaw-local\",
      \"title\": \"IronClaw Local\",
      \"subtitle\": \"IronClaw + local Hailo model\",
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

preload_minimal_flavor_config() {
  local flavor="$1"
  local base_url="http://127.0.0.1:8081/v1"

  case "$flavor" in
    picoclaw)
      run_ssh "mkdir -p ~/.picoclaw ~/.config/picoclaw"
      run_ssh "cat > ~/.picoclaw/config.json <<'EOF'
{
  \"agents\": {
    \"defaults\": {
      \"workspace\": \"~/.picoclaw/workspace\",
      \"restrict_to_workspace\": true,
      \"model\": \"$TEST_HAILO_MODEL\",
      \"max_tokens\": 2048,
      \"temperature\": 0.7,
      \"max_tool_iterations\": 20
    }
  },
  \"providers\": {
    \"ollama\": {
      \"api_key\": \"hailo-local\",
      \"api_base\": \"$base_url\"
    }
  },
  \"gateway\": {
    \"host\": \"127.0.0.1\",
    \"port\": 18790
  }
}
EOF"
      run_ssh 'cp ~/.picoclaw/config.json ~/.config/picoclaw/config.json'
      ;;
    zeroclaw)
      run_ssh 'mkdir -p ~/.zeroclaw'
      run_ssh "cat > ~/.zeroclaw/config.toml <<'EOF'
api_key = \"hailo-local\"
default_provider = \"custom:$base_url\"
default_model = \"$TEST_HAILO_MODEL\"
default_temperature = 0.7

[gateway]
host = \"127.0.0.1\"
port = 8080
require_pairing = true

[heartbeat]
enabled = false
interval_minutes = 30
EOF"
      ;;
    nanobot)
      run_ssh 'mkdir -p ~/.nanobot ~/.nanobot/workspace'
      run_ssh "cat > ~/.nanobot/config.json <<'EOF'
{
  \"agents\": {
    \"defaults\": {
      \"workspace\": \"~/.nanobot/workspace\",
      \"model\": \"$TEST_HAILO_MODEL\",
      \"max_tokens\": 2048,
      \"temperature\": 0.7,
      \"max_tool_iterations\": 20,
      \"memory_window\": 50
    }
  },
  \"providers\": {
    \"custom\": {
      \"api_key\": \"hailo-local\",
      \"api_base\": \"$base_url\"
    }
  },
  \"gateway\": {
    \"host\": \"127.0.0.1\",
    \"port\": 18790
  },
  \"tools\": {
    \"restrict_to_workspace\": true
  }
}
EOF"
      ;;
    moltis)
      run_ssh 'mkdir -p ~/.config/moltis ~/.moltis'
      run_ssh "cat > ~/.config/moltis/moltis.toml <<'EOF'
[providers]
offered = [\"ollama\"]

[providers.ollama]
enabled = true
base_url = \"$base_url\"
models = [\"$TEST_HAILO_MODEL\"]
fetch_models = false

[chat]
priority_models = [\"$TEST_HAILO_MODEL\"]
EOF"
      ;;
    ironclaw)
      run_ssh 'mkdir -p ~/.ironclaw'
      run_ssh "cat > ~/.ironclaw/.env <<'EOF'
DATABASE_URL=postgresql://localhost/ironclaw
OPENAI_BASE_URL=$base_url
OPENAI_API_KEY=hailo-local
OPENAI_MODEL=$TEST_HAILO_MODEL
LLM_BACKEND=openai_compatible
EOF"
      ;;
    openclaw)
      # OpenClaw config/auth are managed separately in installer flow.
      ;;
    *)
      fail "Unsupported flavor for minimal config preload: $flavor"
      ;;
  esac
}

run_checks_for_current_profile_flavor() {
  log "-- check_profile_shape"
  check_profile_shape
  log "-- check_flavor_binary_and_mode_alignment"
  check_flavor_binary_and_mode_alignment
  log "-- check_flavor_minimal_config_preload"
  check_flavor_minimal_config_preload
  log "-- check_flavor_preflight_sanity"
  check_flavor_preflight_sanity
  log "-- check_facade_runtime_support"
  check_facade_runtime_support
  log "-- check_hailo_proxy_matrix"
  check_hailo_proxy_matrix
  log "-- check_facade_chat_intermediary"
  check_facade_chat_intermediary
  log "-- check_flavor_health_and_simple_queries"
  check_flavor_health_and_simple_queries
}

check_profile_shape() {
  require_remote_file "$RUNTIME_PROFILE_REL"

  local profile_summary
  profile_summary=$(json_read_remote "$RUNTIME_PROFILE_REL" 'flavor=obj.get("flavor"); active=obj.get("activeMode"); url=obj.get("ollamaUrl"); model=obj.get("ollamaModel"); extra=obj.get("extraModes") or []; print(f"flavor={flavor}\nactiveMode={active}\nollamaUrl={url}\nollamaModel={model}\nextraCount={len(extra)}")')
  log "$profile_summary"

  local flavor
  flavor=$(printf '%s\n' "$profile_summary" | awk -F= '/^flavor=/{print $2}')
  [[ "$flavor" =~ ^(openclaw|picoclaw|zeroclaw|nanobot|moltis|ironclaw)$ ]] || fail "Invalid flavor in runtime profile: $flavor"

  local url
  url=$(printf '%s\n' "$profile_summary" | awk -F= '/^ollamaUrl=/{print $2}')
  [[ "$url" == http://127.0.0.1:8081/* || "$url" == http://127.0.0.1:8000/* ]] || fail "Unexpected ollamaUrl in runtime profile: $url"

  pass "Runtime profile exists and has expected shape"
}

check_flavor_minimal_config_preload() {
  local flavor
  flavor=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(obj.get("flavor",""))' | tr -d '[:space:]')

  log "Validating minimal config preload for flavor=$flavor"

  case "$flavor" in
    openclaw)
      run_ssh 'test -f ~/.openclaw/openclaw.json' || fail "OpenClaw config missing: ~/.openclaw/openclaw.json"
      run_ssh 'test -f ~/.openclaw/agents/main/agent/auth-profiles.json' || fail "OpenClaw auth profile missing"
      run_ssh "python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser('~/.openclaw/openclaw.json')))
providers=((cfg.get('models') or {}).get('providers') or {})
if 'ollama' not in providers:
    raise SystemExit(1)
print('openclaw_provider|ok')
PY" || fail "OpenClaw minimal config missing models.providers.ollama"
      ;;
    picoclaw)
      run_ssh 'test -f ~/.picoclaw/config.json' || fail "PicoClaw config missing: ~/.picoclaw/config.json"
      run_ssh 'test -f ~/.config/picoclaw/config.json' || fail "PicoClaw config mirror missing: ~/.config/picoclaw/config.json"
      local picoclaw_cfg_probe
      picoclaw_cfg_probe=$(run_ssh "python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser('~/.picoclaw/config.json')))
providers=(cfg.get('providers') or {})
ollama=(providers.get('ollama') or {})
defaults=((cfg.get('agents') or {}).get('defaults') or {})
if 'ollama' not in providers:
    raise SystemExit(1)
if 'model' not in defaults:
    raise SystemExit(2)
base=str(ollama.get('api_base') or '').strip()
print('picoclaw_ollama_api_base|'+(base if base else '<empty>'))
print('picoclaw_default_model|'+str(defaults.get('model')))
PY") || fail "PicoClaw minimal config missing required providers/agents structure"
      log "$picoclaw_cfg_probe"
      printf '%s\n' "$picoclaw_cfg_probe" | grep -q 'picoclaw_ollama_api_base|<empty>' && warn "PicoClaw ollama api_base is empty; installer minimal local wiring may not have been applied on this Pi yet"
      ;;
    zeroclaw)
      run_ssh 'test -f ~/.zeroclaw/config.toml' || fail "ZeroClaw config missing: ~/.zeroclaw/config.toml"
      run_ssh "grep -Eq '^default_provider\s*=\s*\".*\"' ~/.zeroclaw/config.toml" || fail "ZeroClaw config missing default_provider"
      run_ssh "grep -Eq '^default_model\s*=\s*\".*\"' ~/.zeroclaw/config.toml" || fail "ZeroClaw config missing default_model"
      ;;
    nanobot)
      run_ssh 'test -f ~/.nanobot/config.json' || fail "Nanobot config missing: ~/.nanobot/config.json"
      run_ssh "python3 - <<'PY'
import json, os
cfg=json.load(open(os.path.expanduser('~/.nanobot/config.json')))
base=((cfg.get('providers') or {}).get('custom') or {}).get('api_base')
model=((cfg.get('agents') or {}).get('defaults') or {}).get('model')
if not base or not model:
    raise SystemExit(1)
print('nanobot_config|ok')
PY" || fail "Nanobot minimal config missing provider base/model"
      ;;
    moltis)
      run_ssh 'test -f ~/.config/moltis/moltis.toml' || fail "Moltis config missing: ~/.config/moltis/moltis.toml"
      run_ssh "grep -Eq '^base_url\s*=\s*\".*\"' ~/.config/moltis/moltis.toml" || fail "Moltis config missing providers.ollama.base_url"
      run_ssh "grep -Eq '^models\s*=\s*\[' ~/.config/moltis/moltis.toml" || fail "Moltis config missing providers.ollama.models"
      ;;
    ironclaw)
      run_ssh 'test -f ~/.ironclaw/.env' || fail "IronClaw env missing: ~/.ironclaw/.env"
      run_ssh "grep -q '^OPENAI_BASE_URL=' ~/.ironclaw/.env" || fail "IronClaw env missing OPENAI_BASE_URL"
      run_ssh "grep -q '^OPENAI_MODEL=' ~/.ironclaw/.env" || fail "IronClaw env missing OPENAI_MODEL"
      run_ssh "grep -q '^LLM_BACKEND=openai_compatible' ~/.ironclaw/.env" || fail "IronClaw env missing LLM_BACKEND=openai_compatible"
      ;;
    *)
      fail "Unknown flavor for minimal config preload checks: $flavor"
      ;;
  esac

  pass "Flavor minimal config preload checks passed"
}

check_flavor_preflight_sanity() {
  local flavor
  flavor=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(obj.get("flavor",""))' | tr -d '[:space:]')

  log "Running preflight troubleshooting sanity checks for flavor=$flavor"

  run_ssh 'ss -ltn | grep -Eq "(:8000|:8081)"' || fail "Expected local Hailo listeners (8000/8081) are not up"

  case "$flavor" in
    openclaw)
      run_ssh 'PATH=$HOME/.npm-global/bin:$PATH; openclaw status --all >/tmp/openclaw_preflight_status.out 2>&1' || fail "OpenClaw preflight status failed"
      run_ssh "grep -qi 'Gateway service' /tmp/openclaw_preflight_status.out" || fail "OpenClaw preflight missing gateway service status"
      ;;
    picoclaw)
      run_ssh '~/.local/bin/picoclaw status >/tmp/picoclaw_preflight_status.out 2>&1' || fail "PicoClaw preflight status failed"
      run_ssh "grep -qi 'Config:' /tmp/picoclaw_preflight_status.out" || fail "PicoClaw preflight status missing config info"
      ;;
    zeroclaw)
      run_ssh '~/.local/bin/zeroclaw status >/tmp/zeroclaw_preflight_status.out 2>&1' || fail "ZeroClaw preflight status failed"
      run_ssh "grep -Eiq '(provider|status|gateway)' /tmp/zeroclaw_preflight_status.out" || fail "ZeroClaw preflight status missing expected sections"
      ;;
    nanobot)
      run_ssh '~/.local/bin/nanobot status >/tmp/nanobot_preflight_status.out 2>&1' || fail "Nanobot preflight status failed"
      run_ssh "grep -Eiq '(Config:|Model:)' /tmp/nanobot_preflight_status.out" || fail "Nanobot preflight status missing expected info"
      ;;
    moltis)
      run_ssh '~/.local/bin/moltis --log-level error doctor >/tmp/moltis_preflight_doctor.out 2>&1' || fail "Moltis preflight doctor failed"
      run_ssh "grep -Eiq '(providers|ollama)' /tmp/moltis_preflight_doctor.out" || fail "Moltis preflight doctor output missing provider info"
      ;;
    ironclaw)
      run_ssh '~/.local/bin/ironclaw --help >/tmp/ironclaw_preflight_help.out 2>&1' || fail "IronClaw preflight help failed"
      run_ssh "grep -Eiq '(onboard|help|agent|gateway)' /tmp/ironclaw_preflight_help.out" || fail "IronClaw preflight help missing expected commands"
      ;;
    *)
      fail "Unknown flavor for preflight sanity checks: $flavor"
      ;;
  esac

  pass "Flavor preflight troubleshooting sanity checks passed"
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
    ironclaw)
      run_ssh "test -x ~/.local/bin/ironclaw || command -v ironclaw >/dev/null 2>&1" || fail "IronClaw binary missing"
      local extra_count
      extra_count=$(json_read_remote "$RUNTIME_PROFILE_REL" 'print(len(obj.get("extraModes") or []))' | tr -d '[:space:]')
      [[ "$extra_count" -ge 1 ]] || fail "IronClaw profile missing conditional extra modes"
      pass "IronClaw flavor aligned with runtime profile and binary"
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

      local response1 response2 openclaw_query1_seconds openclaw_query2_seconds
      run_timed_remote_command response1 'PATH=$HOME/.npm-global/bin:$PATH; openclaw agent --local --agent main --session-id flavortest-openclaw-1 --timeout 120 --message "Reply with only OK."' || fail "OpenClaw simple query #1 failed"
      openclaw_query1_seconds=$TIMED_LAST_SECONDS
      printf '%s\n' "$response1" | grep -Eiq '(^|[^a-z0-9])ok([^a-z0-9]|$)' || fail "OpenClaw simple query #1 did not return OK"
      log "OpenClaw query #1 completed in ${openclaw_query1_seconds}s"

      run_timed_remote_command response2 'PATH=$HOME/.npm-global/bin:$PATH; openclaw agent --local --agent main --session-id flavortest-openclaw-2 --timeout 120 --message "What is 2+2? Reply with only the answer."' || fail "OpenClaw simple query #2 failed"
      openclaw_query2_seconds=$TIMED_LAST_SECONDS
      printf '%s\n' "$response2" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "OpenClaw simple query #2 did not return expected answer"
      log "OpenClaw query #2 completed in ${openclaw_query2_seconds}s"

      record_flavor_query_timing "$flavor" "$openclaw_query1_seconds" "$openclaw_query2_seconds"

      pass "OpenClaw health + simple query checks passed"
      ;;
    picoclaw)
      log "== PicoClaw health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/picoclaw || command -v picoclaw >/dev/null 2>&1' || fail "PicoClaw binary missing for health checks"

      local pico_status
      pico_status=$(run_ssh '~/.local/bin/picoclaw status') || fail "picoclaw status failed"
      printf '%s\n' "$pico_status" | grep -qi 'Config:' || fail "picoclaw status output missing config info"

      local pico_probe
      pico_probe=$(run_ssh "python3 - <<'PY'
import json, os, re, time, urllib.request

cfg_path = os.path.expanduser('~/.picoclaw/config.json')
cfg = json.load(open(cfg_path))

providers = cfg.get('providers') or {}
ollama = providers.get('ollama') or {}
base_url = str(ollama.get('api_base') or '').rstrip('/')
defaults = ((cfg.get('agents') or {}).get('defaults') or {})
model = str(defaults.get('model') or '').strip()

if not base_url or not model:
    raise SystemExit(3)

if base_url.endswith('/v1/chat/completions'):
    endpoint = base_url
elif base_url.endswith('/v1'):
    endpoint = f'{base_url}/chat/completions'
else:
    endpoint = f'{base_url}/v1/chat/completions'

print(f'picoclaw_base_url|{base_url}')
print(f'picoclaw_endpoint|{endpoint}')
print(f'picoclaw_model|{model}')

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
    started = time.monotonic()
    status, body = post(prompt)
    elapsed_seconds = int(time.monotonic() - started)
    text = response_text(body)
    normalized = str(text).strip().lower()
    print(f'{label}_elapsed_seconds|{elapsed_seconds}')
    print(f'{label}_status|{status}')
    print(f'{label}_preview|{normalized[:80].replace(chr(10), chr(32))}')
    if status != 200:
        raise SystemExit(10)
    if not re.search(pattern, normalized):
        raise SystemExit(11)
PY") || fail "PicoClaw config-based chat probe failed"

      log "$pico_probe"

      local pico_query1_seconds pico_query2_seconds
      pico_query1_seconds=$(printf '%s\n' "$pico_probe" | awk -F'|' '/^ok_elapsed_seconds\|/{print $2}' | tr -d '[:space:]')
      pico_query2_seconds=$(printf '%s\n' "$pico_probe" | awk -F'|' '/^math_elapsed_seconds\|/{print $2}' | tr -d '[:space:]')
      [[ "$pico_query1_seconds" =~ ^[0-9]+$ ]] || fail "PicoClaw query #1 timing missing from probe output"
      [[ "$pico_query2_seconds" =~ ^[0-9]+$ ]] || fail "PicoClaw query #2 timing missing from probe output"
      log "PicoClaw query #1 completed in ${pico_query1_seconds}s"
      log "PicoClaw query #2 completed in ${pico_query2_seconds}s"

      record_flavor_query_timing "$flavor" "$pico_query1_seconds" "$pico_query2_seconds"

      pass "PicoClaw health + simple query checks passed"
      ;;
    zeroclaw)
      log "== ZeroClaw health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/zeroclaw || command -v zeroclaw >/dev/null 2>&1' || fail "ZeroClaw binary missing for health checks"

      local zero_status
      zero_status=$(run_ssh '~/.local/bin/zeroclaw status') || fail "zeroclaw status failed"
      printf '%s\n' "$zero_status" | grep -Eiq '(provider|status|gateway)' || fail "zeroclaw status output missing expected sections"

      local zero_response1 zero_response2 attempt zero_query1_seconds zero_query2_seconds
      zero_query1_seconds=0
      zero_query2_seconds=0

      for attempt in 1 2 3; do
        run_timed_remote_command zero_response1 '~/.local/bin/zeroclaw agent --provider "custom:http://127.0.0.1:8081/v1" --model qwen2:1.5b --message "What is 2+2? Reply with only the answer."' || fail "ZeroClaw simple query #1 failed"
        zero_query1_seconds=$((zero_query1_seconds + TIMED_LAST_SECONDS))
        if printf '%s\n' "$zero_response1" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)'; then
          break
        fi
        [[ "$attempt" -lt 3 ]] && warn "ZeroClaw simple query #1 attempt $attempt did not match expected answer; retrying..."
      done
      printf '%s\n' "$zero_response1" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "ZeroClaw simple query #1 did not return expected answer"
      log "ZeroClaw query #1 completed in ${zero_query1_seconds}s"

      for attempt in 1 2 3; do
        run_timed_remote_command zero_response2 '~/.local/bin/zeroclaw agent --provider "custom:http://127.0.0.1:8081/v1" --model qwen2:1.5b --message "What is 3+3? Reply with only the answer."' || fail "ZeroClaw simple query #2 failed"
        zero_query2_seconds=$((zero_query2_seconds + TIMED_LAST_SECONDS))
        if printf '%s\n' "$zero_response2" | grep -Eiq '(^|[^a-z0-9])(6|six)([^a-z0-9]|$)'; then
          break
        fi
        [[ "$attempt" -lt 3 ]] && warn "ZeroClaw simple query #2 attempt $attempt did not match expected answer; retrying..."
      done
      printf '%s\n' "$zero_response2" | grep -Eiq '(^|[^a-z0-9])(6|six)([^a-z0-9]|$)' || fail "ZeroClaw simple query #2 did not return expected answer"
      log "ZeroClaw query #2 completed in ${zero_query2_seconds}s"

      record_flavor_query_timing "$flavor" "$zero_query1_seconds" "$zero_query2_seconds"

      pass "ZeroClaw health + simple query checks passed"
      ;;
    nanobot)
      log "== Nanobot health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/nanobot || command -v nanobot >/dev/null 2>&1' || fail "Nanobot binary missing for health checks"

      local nanobot_status
      nanobot_status=$(run_ssh '~/.local/bin/nanobot status') || fail "nanobot status failed"
      printf '%s\n' "$nanobot_status" | grep -Eiq '(Config:|Model:)' || fail "nanobot status output missing expected info"

      local nanobot_response1 nanobot_response2 nanobot_query1_seconds nanobot_query2_seconds
      run_timed_remote_command nanobot_response1 '~/.local/bin/nanobot agent --message "Reply with only OK."' || fail "Nanobot simple query #1 failed"
      nanobot_query1_seconds=$TIMED_LAST_SECONDS
      printf '%s\n' "$nanobot_response1" | grep -Eiq '(^|[^a-z0-9])ok([^a-z0-9]|$)' || fail "Nanobot simple query #1 did not return OK"
      log "Nanobot query #1 completed in ${nanobot_query1_seconds}s"

      run_timed_remote_command nanobot_response2 '~/.local/bin/nanobot agent --message "What is 2+2? Reply with only the answer."' || fail "Nanobot simple query #2 failed"
      nanobot_query2_seconds=$TIMED_LAST_SECONDS
      printf '%s\n' "$nanobot_response2" | grep -Eiq '(^|[^a-z0-9])(4|four)([^a-z0-9]|$)' || fail "Nanobot simple query #2 did not return expected answer"
      log "Nanobot query #2 completed in ${nanobot_query2_seconds}s"

      record_flavor_query_timing "$flavor" "$nanobot_query1_seconds" "$nanobot_query2_seconds"

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
import json, os, re, time, urllib.request

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
    started = time.monotonic()
    status, body = post(prompt)
    elapsed_seconds = int(time.monotonic() - started)
    text = response_text(body)
    normalized = str(text).strip().lower()
    print(f'{label}_elapsed_seconds|{elapsed_seconds}')
    print(f'{label}_status|{status}')
    print(f'{label}_preview|{normalized[:80].replace(chr(10), chr(32))}')
    if status != 200:
        raise SystemExit(10)
    if not re.search(pattern, normalized):
        raise SystemExit(11)
PY") || fail "Moltis config-based chat probe failed"

      log "$moltis_probe"

      local moltis_query1_seconds moltis_query2_seconds
      moltis_query1_seconds=$(printf '%s\n' "$moltis_probe" | awk -F'|' '/^ok_elapsed_seconds\|/{print $2}' | tr -d '[:space:]')
      moltis_query2_seconds=$(printf '%s\n' "$moltis_probe" | awk -F'|' '/^math_elapsed_seconds\|/{print $2}' | tr -d '[:space:]')
      [[ "$moltis_query1_seconds" =~ ^[0-9]+$ ]] || fail "Moltis query #1 timing missing from probe output"
      [[ "$moltis_query2_seconds" =~ ^[0-9]+$ ]] || fail "Moltis query #2 timing missing from probe output"
      log "Moltis query #1 completed in ${moltis_query1_seconds}s"
      log "Moltis query #2 completed in ${moltis_query2_seconds}s"

      record_flavor_query_timing "$flavor" "$moltis_query1_seconds" "$moltis_query2_seconds"

      pass "Moltis health + simple query checks passed"
      ;;
    ironclaw)
      log "== IronClaw health + simple query checks =="
      run_ssh 'test -x ~/.local/bin/ironclaw || command -v ironclaw >/dev/null 2>&1' || fail "IronClaw binary missing for health checks"

      local ironclaw_help
      ironclaw_help=$(run_ssh '~/.local/bin/ironclaw --help 2>&1') || fail "ironclaw --help failed"
      printf '%s\n' "$ironclaw_help" | grep -Eiq '(onboard|help|agent|gateway)' || fail "ironclaw help output missing expected commands"

      local ironclaw_probe
      ironclaw_probe=$(run_ssh "python3 - <<'PY'
import json, re, time, urllib.request

endpoint='http://127.0.0.1:8081/v1/chat/completions'
model='$TEST_HAILO_MODEL'

def post(prompt):
    payload={
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'stream': False,
    }
    req=urllib.request.Request(endpoint, data=json.dumps(payload).encode(), method='POST', headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read().decode(errors='replace')

def extract_text(body):
    try:
        obj=json.loads(body)
        return str(((obj.get('choices') or [{}])[0].get('message') or {}).get('content',''))
    except Exception:
        return body

checks=[
    ('ok', 'Reply with only OK.', r'(^|[^a-z0-9])ok([^a-z0-9]|$)'),
    ('math', 'What is 2+2? Reply with only the answer.', r'(^|[^a-z0-9])(4|four)([^a-z0-9]|$)'),
]

for label,prompt,pattern in checks:
    started=time.monotonic()
    status,body=post(prompt)
    elapsed=int(time.monotonic()-started)
    text=extract_text(body).strip().lower()
    print(f'{label}_elapsed_seconds|{elapsed}')
    print(f'{label}_status|{status}')
    print(f'{label}_preview|{text[:80]}')
    if status != 200:
        raise SystemExit(10)
    if not re.search(pattern, text):
        raise SystemExit(11)
PY") || fail "IronClaw local-Hailo probe failed"

      log "$ironclaw_probe"

      local ironclaw_query1_seconds ironclaw_query2_seconds
      ironclaw_query1_seconds=$(printf '%s\n' "$ironclaw_probe" | awk -F'|' '/^ok_elapsed_seconds\|/{print $2}' | tr -d '[:space:]')
      ironclaw_query2_seconds=$(printf '%s\n' "$ironclaw_probe" | awk -F'|' '/^math_elapsed_seconds\|/{print $2}' | tr -d '[:space:]')
      [[ "$ironclaw_query1_seconds" =~ ^[0-9]+$ ]] || fail "IronClaw query #1 timing missing from probe output"
      [[ "$ironclaw_query2_seconds" =~ ^[0-9]+$ ]] || fail "IronClaw query #2 timing missing from probe output"
      record_flavor_query_timing "$flavor" "$ironclaw_query1_seconds" "$ironclaw_query2_seconds"

      pass "IronClaw health + simple query checks passed"
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
    for flavor in $FLAVORS_TO_TEST; do
      log "==== Testing flavor: $flavor ===="
      write_runtime_profile_for_flavor "$flavor"
      preload_minimal_flavor_config "$flavor"
      run_checks_for_current_profile_flavor
    done
  else
    run_checks_for_current_profile_flavor
  fi

  print_query_timing_table

  pass "All cross-flavor checks passed"
}

main "$@"
