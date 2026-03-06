#!/usr/bin/env bash
set -euo pipefail

# Compile + deploy helper for Qwen3.5-0.8B on Hailo-10H.
#
# IMPORTANT:
# - Compile is expected to run on an x86 Linux host with Hailo DFC installed.
# - Raspberry Pi is used for remote artifact deployment and smoke testing.
# - Hailo-Ollama does not currently provide a public "upload custom model" flow,
#   so this script validates HEF loading on-device via hailo_platform.
#
# Example:
#   ONNX_PATH=/abs/path/qwen3.5-0.8b.onnx \
#   SSH_HOST=raspberrypi SSH_USER=sanchobot \
#   ENABLE_THINKING_MODE=yes \
#   INSTALL_QWEN_CODE=no \
#   SAMPLING_PARAMS_MODE=4 \
#   VIDEO_PREPRECESSOR_LONGEST_EDGE=469762048 \
#   bash scripts/compile_qwen35_h10_over_ssh.sh

MODEL_HF_ID=${MODEL_HF_ID:-Qwen/Qwen3.5-0.8B}
MODEL_NAME=${MODEL_NAME:-qwen3.5-0.8b}
ONNX_PATH=${ONNX_PATH:-}
CALIB_NPY=${CALIB_NPY:-}
USE_QUANTIZATION=${USE_QUANTIZATION:-no}
PYTHON_BIN=${PYTHON_BIN:-python3}
# Supports single index ("0"), comma list ("0,1"), or "all" NVIDIA CUDA GPUs.
DFC_GPU_INDEX=${DFC_GPU_INDEX:-0}
CUDA_SAMPLE_ENABLE=${CUDA_SAMPLE_ENABLE:-yes}
CUDA_SAMPLE_INTERVAL_SEC=${CUDA_SAMPLE_INTERVAL_SEC:-120}
CUDA_SAMPLE_MAX_SAMPLES=${CUDA_SAMPLE_MAX_SAMPLES:-24}
TRANSLATE_HEARTBEAT_SEC=${TRANSLATE_HEARTBEAT_SEC:-30}
TRANSLATE_STACK_DUMP_ENABLE=${TRANSLATE_STACK_DUMP_ENABLE:-yes}
TRANSLATE_STACK_DUMP_SEC=${TRANSLATE_STACK_DUMP_SEC:-120}

HOST_OUTPUT_DIR=${HOST_OUTPUT_DIR:-"$PWD/artifacts/$MODEL_NAME"}
HEF_OUTPUT_PATH=${HEF_OUTPUT_PATH:-"$HOST_OUTPUT_DIR/${MODEL_NAME}.hef"}
LOCAL_RUNTIME_PROFILE_PATH=""

# User-requested knobs
ENABLE_THINKING_MODE=${ENABLE_THINKING_MODE:-}
INSTALL_QWEN_CODE=${INSTALL_QWEN_CODE:-no}
SAMPLING_PARAMS_MODE=${SAMPLING_PARAMS_MODE:-1}
VIDEO_PREPRECESSOR_LONGEST_EDGE=${VIDEO_PREPRECESSOR_LONGEST_EDGE:-469762048}
VIDEO_PREPROCESSOR_LONGEST_EDGE=${VIDEO_PREPROCESSOR_LONGEST_EDGE:-$VIDEO_PREPRECESSOR_LONGEST_EDGE}

# SSH knobs
SSH_HOST=${SSH_HOST:-raspberrypi}
SSH_USER=${SSH_USER:-sanchobot}
SSH_PORT=${SSH_PORT:-22}
REMOTE_DIR=${REMOTE_DIR:-"/home/${SSH_USER}/hailo_custom_models/${MODEL_NAME}"}
REMOTE_RUNTIME_PROFILE_NAME=${REMOTE_RUNTIME_PROFILE_NAME:-"${MODEL_NAME}_runtime_profile.json"}
COPY_TO_REMOTE=${COPY_TO_REMOTE:-yes}
RUN_REMOTE_TEST=${RUN_REMOTE_TEST:-yes}

SSH_CMD=(ssh -o ConnectTimeout=10 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}")
SCP_CMD=(scp -P "$SSH_PORT")

SAMPLE_MODE_LABEL=""
SAMPLE_TEMPERATURE=""
SAMPLE_TOP_P=""
SAMPLE_TOP_K=""
SAMPLE_MIN_P=""
SAMPLE_PRESENCE_PENALTY=""
SAMPLE_REPETITION_PENALTY=""
ENABLE_THINKING_JSON="false"
declare -A STAGE_SECONDS=()
declare -a STAGE_ORDER=()

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

format_duration_seconds() {
  local total_seconds
  total_seconds=${1:-0}
  local minutes seconds
  minutes=$((total_seconds / 60))
  seconds=$((total_seconds % 60))
  printf '%02dm%02ds' "$minutes" "$seconds"
}

run_timed_stage() {
  local stage_name
  stage_name="$1"
  shift

  local started_at finished_at elapsed rc
  started_at=$(date +%s)
  STAGE_ORDER+=("$stage_name")
  log ">>> [stage] $stage_name START $(date -Is)"

  if "$@"; then
    finished_at=$(date +%s)
    elapsed=$((finished_at - started_at))
    STAGE_SECONDS["$stage_name"]=$elapsed
    log "<<< [stage] $stage_name DONE in ${elapsed}s ($(format_duration_seconds "$elapsed"))"
  else
    rc=$?
    finished_at=$(date +%s)
    elapsed=$((finished_at - started_at))
    STAGE_SECONDS["$stage_name"]=$elapsed
    log "<<< [stage] $stage_name FAIL rc=$rc after ${elapsed}s ($(format_duration_seconds "$elapsed"))"
    return "$rc"
  fi
}

start_cuda_usage_sampler() {
  local stage_name
  stage_name="$1"

  CUDA_SAMPLER_PID=""

  if [[ "$CUDA_SAMPLE_ENABLE" != "yes" ]]; then
    log "[cuda_sample] disabled (CUDA_SAMPLE_ENABLE=$CUDA_SAMPLE_ENABLE)"
    return 0
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "[cuda_sample] nvidia-smi not found; skipping CUDA usage sampling."
    return 0
  fi

  local sample_interval max_samples
  sample_interval="$CUDA_SAMPLE_INTERVAL_SEC"
  max_samples="$CUDA_SAMPLE_MAX_SAMPLES"

  if ! [[ "$sample_interval" =~ ^[0-9]+$ ]] || [[ "$sample_interval" -lt 1 ]]; then
    warn "[cuda_sample] Invalid CUDA_SAMPLE_INTERVAL_SEC=$sample_interval. Using 5."
    sample_interval=5
  fi
  if ! [[ "$max_samples" =~ ^[0-9]+$ ]] || [[ "$max_samples" -lt 1 ]]; then
    warn "[cuda_sample] Invalid CUDA_SAMPLE_MAX_SAMPLES=$max_samples. Using 24."
    max_samples=24
  fi

  (
    local sample_idx timestamp sample_line
    sample_idx=1
    while [[ "$sample_idx" -le "$max_samples" ]]; do
      timestamp=$(date -Is)
      sample_line=$(nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader 2>/dev/null | tr '\n' '|' | sed 's/|$//')
      if [[ -n "$sample_line" ]]; then
        log "[cuda_sample][$stage_name][$sample_idx/$max_samples][$timestamp] visible=${CUDA_VISIBLE_DEVICES:-<unset>} :: $sample_line"
      fi
      sample_idx=$((sample_idx + 1))
      sleep "$sample_interval"
    done
  ) &

  CUDA_SAMPLER_PID=$!
  log "[cuda_sample] started sampler pid=$CUDA_SAMPLER_PID interval=${sample_interval}s max_samples=$max_samples"
}

stop_cuda_usage_sampler() {
  local sampler_pid
  sampler_pid="${1:-}"

  if [[ -z "$sampler_pid" ]]; then
    return 0
  fi

  if kill -0 "$sampler_pid" 2>/dev/null; then
    kill "$sampler_pid" 2>/dev/null || true
  fi
  wait "$sampler_pid" 2>/dev/null || true
  log "[cuda_sample] stopped sampler pid=$sampler_pid"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

normalize_yes_no() {
  local raw
  raw=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    y|yes|true|1) printf 'yes' ;;
    n|no|false|0) printf 'no' ;;
    *) fail "Expected yes/no style value, got: ${1:-<empty>}" ;;
  esac
}

configure_gpu_selection() {
  if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    log "Using CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    return
  fi

  local resolved_cuda_devices
  if [[ "$DFC_GPU_INDEX" == "all" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
      local -a nvidia_gpu_indices=()
      mapfile -t nvidia_gpu_indices < <(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr -d ' ')
      if [[ ${#nvidia_gpu_indices[@]} -gt 0 ]]; then
        local IFS=,
        resolved_cuda_devices="${nvidia_gpu_indices[*]}"
      else
        resolved_cuda_devices=""
      fi
    else
      resolved_cuda_devices=""
    fi
  else
    resolved_cuda_devices="$DFC_GPU_INDEX"
  fi

  if [[ -z "$resolved_cuda_devices" ]]; then
    warn "Could not resolve NVIDIA CUDA devices from DFC_GPU_INDEX=$DFC_GPU_INDEX. Hailo SDK will auto-select if available."
  else
    export CUDA_VISIBLE_DEVICES="$resolved_cuda_devices"
    log "Set CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES (override via CUDA_VISIBLE_DEVICES or DFC_GPU_INDEX)"
  fi

  if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -Eiq 'Intel.*(Iris|GT2)'; then
    warn "Intel Iris/Xe iGPU detected, but Hailo DFC uses CUDA_VISIBLE_DEVICES (NVIDIA CUDA only). Intel iGPU cannot be used in this compile path."
  fi
}

run_ssh() {
  "${SSH_CMD[@]}" "$@"
}

resolve_sampling_profile() {
  case "$SAMPLING_PARAMS_MODE" in
    1)
      SAMPLE_MODE_LABEL="non-thinking-text"
      SAMPLE_TEMPERATURE="1.0"
      SAMPLE_TOP_P="1.00"
      SAMPLE_TOP_K="20"
      SAMPLE_MIN_P="0.0"
      SAMPLE_PRESENCE_PENALTY="2.0"
      SAMPLE_REPETITION_PENALTY="1.0"
      [[ -z "$ENABLE_THINKING_MODE" ]] && ENABLE_THINKING_MODE="no"
      ;;
    2)
      SAMPLE_MODE_LABEL="non-thinking-vl"
      SAMPLE_TEMPERATURE="0.7"
      SAMPLE_TOP_P="0.80"
      SAMPLE_TOP_K="20"
      SAMPLE_MIN_P="0.0"
      SAMPLE_PRESENCE_PENALTY="1.5"
      SAMPLE_REPETITION_PENALTY="1.0"
      [[ -z "$ENABLE_THINKING_MODE" ]] && ENABLE_THINKING_MODE="no"
      ;;
    3)
      SAMPLE_MODE_LABEL="thinking-text"
      SAMPLE_TEMPERATURE="1.0"
      SAMPLE_TOP_P="0.95"
      SAMPLE_TOP_K="20"
      SAMPLE_MIN_P="0.0"
      SAMPLE_PRESENCE_PENALTY="1.5"
      SAMPLE_REPETITION_PENALTY="1.0"
      [[ -z "$ENABLE_THINKING_MODE" ]] && ENABLE_THINKING_MODE="yes"
      ;;
    4)
      SAMPLE_MODE_LABEL="thinking-vl-or-precise-coding"
      SAMPLE_TEMPERATURE="0.6"
      SAMPLE_TOP_P="0.95"
      SAMPLE_TOP_K="20"
      SAMPLE_MIN_P="0.0"
      SAMPLE_PRESENCE_PENALTY="0.0"
      SAMPLE_REPETITION_PENALTY="1.0"
      [[ -z "$ENABLE_THINKING_MODE" ]] && ENABLE_THINKING_MODE="yes"
      ;;
    *)
      fail "SAMPLING_PARAMS_MODE must be 1,2,3,4 (got: $SAMPLING_PARAMS_MODE)"
      ;;
  esac

  ENABLE_THINKING_MODE=$(normalize_yes_no "$ENABLE_THINKING_MODE")
  INSTALL_QWEN_CODE=$(normalize_yes_no "$INSTALL_QWEN_CODE")
  COPY_TO_REMOTE=$(normalize_yes_no "$COPY_TO_REMOTE")
  RUN_REMOTE_TEST=$(normalize_yes_no "$RUN_REMOTE_TEST")
  USE_QUANTIZATION=$(normalize_yes_no "$USE_QUANTIZATION")
  CUDA_SAMPLE_ENABLE=$(normalize_yes_no "$CUDA_SAMPLE_ENABLE")
  TRANSLATE_STACK_DUMP_ENABLE=$(normalize_yes_no "$TRANSLATE_STACK_DUMP_ENABLE")

  if [[ "$ENABLE_THINKING_MODE" == "yes" ]]; then
    ENABLE_THINKING_JSON="true"
  else
    ENABLE_THINKING_JSON="false"
  fi
}

write_runtime_profile() {
  mkdir -p "$HOST_OUTPUT_DIR"
  LOCAL_RUNTIME_PROFILE_PATH="$HOST_OUTPUT_DIR/${MODEL_NAME}_runtime_profile.json"

  cat > "$LOCAL_RUNTIME_PROFILE_PATH" <<EOF
{
  "model_hf_id": "$MODEL_HF_ID",
  "sampling_params_mode": $SAMPLING_PARAMS_MODE,
  "sampling_params_mode_label": "$SAMPLE_MODE_LABEL",
  "enable_thinking": $ENABLE_THINKING_JSON,
  "sampling_params": {
    "temperature": $SAMPLE_TEMPERATURE,
    "top_p": $SAMPLE_TOP_P,
    "top_k": $SAMPLE_TOP_K,
    "min_p": $SAMPLE_MIN_P,
    "presence_penalty": $SAMPLE_PRESENCE_PENALTY,
    "repetition_penalty": $SAMPLE_REPETITION_PENALTY
  },
  "video_preprecessor_longest_edge": $VIDEO_PREPRECESSOR_LONGEST_EDGE,
  "video_preprocessor_longest_edge": $VIDEO_PREPROCESSOR_LONGEST_EDGE,
  "notes": [
    "Defaults come from Qwen3.5-0.8B README sampling/video recommendations.",
    "Qwen3.5-0.8B custom HEF integration into hailo-ollama is not a public flow at this time.",
    "This profile is intended for consistent runtime settings in your own serving stack."
  ]
}
EOF

  log "Wrote runtime profile: $LOCAL_RUNTIME_PROFILE_PATH"
}

verify_local_prereqs() {
  require_cmd "$PYTHON_BIN"

  local host_arch
  host_arch=$(uname -m 2>/dev/null || echo "unknown")
  if [[ "$host_arch" == "aarch64" || "$host_arch" == "arm64" ]]; then
    warn "Host architecture is $host_arch. Per Hailo guidance, DFC compilation is typically done on x86 Linux."
  fi

  if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1; then
import importlib.util
if importlib.util.find_spec("hailo_sdk_client") is None:
    raise SystemExit(1)
PY
    fail "hailo_sdk_client Python package not found. Install Hailo DFC SDK on this host first."
  fi

  if [[ -z "$ONNX_PATH" ]]; then
    fail "ONNX_PATH is required. Export Qwen3.5-0.8B to ONNX first, then rerun."
  fi

  [[ -f "$ONNX_PATH" ]] || fail "ONNX file not found: $ONNX_PATH"

  if [[ "$USE_QUANTIZATION" == "yes" ]]; then
    [[ -n "$CALIB_NPY" ]] || fail "USE_QUANTIZATION=yes requires CALIB_NPY=<path>."
    [[ -f "$CALIB_NPY" ]] || fail "Calibration npy not found: $CALIB_NPY"
  fi

  mkdir -p "$HOST_OUTPUT_DIR"
}

compile_hef() {
  log "Compiling HEF for hw_arch=hailo10h ..."

  export MODEL_NAME
  export ONNX_PATH
  export HEF_OUTPUT_PATH
  export USE_QUANTIZATION
  export CALIB_NPY
  export TRANSLATE_HEARTBEAT_SEC
  export TRANSLATE_STACK_DUMP_ENABLE
  export TRANSLATE_STACK_DUMP_SEC

  local sampler_pid
  start_cuda_usage_sampler "compile_hef"
  sampler_pid="${CUDA_SAMPLER_PID:-}"

  if "$PYTHON_BIN" - <<'PY'
import os
import time
import threading
import faulthandler
from hailo_sdk_client import ClientRunner


def log_step(message):
    print(f"[compile_py] {message}", flush=True)


def parse_positive_int_env(name, default):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
        if value < 1:
            raise ValueError()
        return value
    except Exception:
        log_step(f"Invalid {name}={raw!r}; using {default}")
        return default


model_name = os.environ["MODEL_NAME"]
onnx_path = os.environ["ONNX_PATH"]
out_path = os.environ["HEF_OUTPUT_PATH"]
use_quantization = os.environ.get("USE_QUANTIZATION", "no") == "yes"
calib_path = os.environ.get("CALIB_NPY", "")
translate_heartbeat_sec = parse_positive_int_env("TRANSLATE_HEARTBEAT_SEC", 30)
translate_stack_dump_enable = os.environ.get("TRANSLATE_STACK_DUMP_ENABLE", "yes") == "yes"
translate_stack_dump_sec = parse_positive_int_env("TRANSLATE_STACK_DUMP_SEC", 120)

t_runner = time.time()
log_step("Creating ClientRunner(hw_arch='hailo10h')")
runner = ClientRunner(hw_arch="hailo10h")
log_step(f"ClientRunner ready in {time.time() - t_runner:.2f}s")

t_translate = time.time()
log_step(f"translate_onnx_model start: {onnx_path}")
log_step(
    "translate debug config: "
    f"heartbeat={translate_heartbeat_sec}s "
    f"stack_dump_enable={translate_stack_dump_enable} "
    f"stack_dump_interval={translate_stack_dump_sec}s"
)

translate_done = threading.Event()
translate_heartbeat_count = 0


def translate_heartbeat_loop():
    global translate_heartbeat_count
    while not translate_done.wait(translate_heartbeat_sec):
        translate_heartbeat_count += 1
        log_step(
            f"translate_onnx_model heartbeat #{translate_heartbeat_count} "
            f"elapsed={time.time() - t_translate:.1f}s"
        )


heartbeat_thread = threading.Thread(
    target=translate_heartbeat_loop,
    name="translate-heartbeat",
    daemon=True,
)
heartbeat_thread.start()

if translate_stack_dump_enable:
    faulthandler.enable()
    faulthandler.dump_traceback_later(translate_stack_dump_sec, repeat=True)
    log_step(f"faulthandler periodic traceback enabled every {translate_stack_dump_sec}s")

try:
    runner.translate_onnx_model(onnx_path, model_name)
finally:
    translate_done.set()
    heartbeat_thread.join(timeout=1)
    if translate_stack_dump_enable:
        faulthandler.cancel_dump_traceback_later()

log_step(f"translate_onnx_model done in {time.time() - t_translate:.2f}s")

if use_quantization:
    import numpy as np

    t_load_calib = time.time()
    log_step(f"Loading calibration data: {calib_path}")
    calib = np.load(calib_path)

    log_step(f"Calibration data loaded in {time.time() - t_load_calib:.2f}s")
    t_quant = time.time()
    log_step("runner.quantize start")
    runner.quantize(calib)
    log_step(f"runner.quantize done in {time.time() - t_quant:.2f}s")
else:
    t_opt = time.time()
    log_step("runner.optimize_full_precision start")
    runner.optimize_full_precision()
    log_step(f"runner.optimize_full_precision done in {time.time() - t_opt:.2f}s")

t_compile = time.time()
log_step("runner.compile start")
hef = runner.compile()
log_step(f"runner.compile done in {time.time() - t_compile:.2f}s")

t_write = time.time()
with open(out_path, "wb") as f:
    f.write(hef)
log_step(f"HEF write done in {time.time() - t_write:.2f}s")

log_step(f"HEF written to: {out_path}")
PY
  then
    :
  else
    local py_rc=$?
    stop_cuda_usage_sampler "$sampler_pid"
    return "$py_rc"
  fi

  stop_cuda_usage_sampler "$sampler_pid"

  [[ -s "$HEF_OUTPUT_PATH" ]] || fail "HEF output missing or empty: $HEF_OUTPUT_PATH"
  log "Compile complete: $HEF_OUTPUT_PATH"
}

remote_preflight() {
  log "Running remote preflight on ${SSH_USER}@${SSH_HOST}:${SSH_PORT} ..."

  run_ssh "command -v python3 >/dev/null" || fail "python3 is missing on remote Pi"
  run_ssh "command -v hailortcli >/dev/null" || fail "hailortcli is missing on remote Pi"
  run_ssh "python3 - <<'PY'
import importlib.util
if importlib.util.find_spec('hailo_platform') is None:
    raise SystemExit(1)
PY" || fail "Python package hailo_platform is missing on remote Pi"

  if ! run_ssh "lspci 2>/dev/null | grep -qi Hailo"; then
    warn "Remote lspci did not show a Hailo device."
  fi

  run_ssh "test -e /dev/hailo0" || fail "Remote /dev/hailo0 is missing"

  if run_ssh "dpkg -l | grep -q '^ii  hailo-all'"; then
    warn "Remote host has hailo-all installed. For Hailo-10H, hailo-h10-all is recommended."
  fi

  if ! run_ssh "dpkg -l | grep -q '^ii  hailo-h10-all'"; then
    warn "Remote host does not show hailo-h10-all as installed."
  fi

  run_ssh "lsmod | grep -E 'hailo1x_pci|hailo_pci' || true"
}

copy_to_remote() {
  local remote_hef_path
  remote_hef_path="$REMOTE_DIR/$(basename "$HEF_OUTPUT_PATH")"

  run_ssh "mkdir -p '$REMOTE_DIR'"
  "${SCP_CMD[@]}" "$HEF_OUTPUT_PATH" "${SSH_USER}@${SSH_HOST}:$remote_hef_path"
  "${SCP_CMD[@]}" "$LOCAL_RUNTIME_PROFILE_PATH" "${SSH_USER}@${SSH_HOST}:$REMOTE_DIR/$REMOTE_RUNTIME_PROFILE_NAME"

  log "Copied HEF to: $remote_hef_path"
  log "Copied runtime profile to: $REMOTE_DIR/$REMOTE_RUNTIME_PROFILE_NAME"
}

install_qwen_code_remote() {
  if [[ "$INSTALL_QWEN_CODE" != "yes" ]]; then
    log "Skipping Qwen Code install (INSTALL_QWEN_CODE=$INSTALL_QWEN_CODE)"
    return
  fi

  log "Installing Qwen Code on remote host ..."

  run_ssh "command -v npm >/dev/null" || fail "npm not found on remote host (required for Qwen Code install)"
  run_ssh "export PATH=\$HOME/.npm-global/bin:\$PATH; if ! command -v qwen >/dev/null 2>&1; then npm install -g @qwen-code/qwen-code@latest; fi"
  run_ssh "export PATH=\$HOME/.npm-global/bin:\$PATH; qwen --version"

  log "Qwen Code install check complete"
}

remote_hef_smoke_test() {
  if [[ "$RUN_REMOTE_TEST" != "yes" ]]; then
    log "Skipping remote HEF smoke test (RUN_REMOTE_TEST=$RUN_REMOTE_TEST)"
    return
  fi

  local remote_hef_path
  remote_hef_path="$REMOTE_DIR/$(basename "$HEF_OUTPUT_PATH")"

  log "Running remote HEF smoke test ..."
  run_ssh "python3 - <<'PY'
from hailo_platform import HEF, VDevice, HailoStreamInterface, ConfigureParams

hef_path = '$remote_hef_path'
hef = HEF(hef_path)
inputs = [x.name for x in hef.get_input_vstream_infos()]
outputs = [x.name for x in hef.get_output_vstream_infos()]

params = VDevice.create_params()
with VDevice(params) as target:
    cfg = ConfigureParams.create_from_hef(hef, interface=HailoStreamInterface.PCIe)
    network_groups = target.configure(hef, cfg)

print('HEF_LOAD_OK')
print('inputs=', inputs)
print('outputs=', outputs)
print('network_groups=', len(network_groups))
PY"

  log "Remote smoke test complete"
}

print_timing_summary() {
  local total_seconds stage_name elapsed
  total_seconds=0

  log ""
  log "=== Timing Summary ==="
  for stage_name in "${STAGE_ORDER[@]}"; do
    elapsed=${STAGE_SECONDS["$stage_name"]:-0}
    total_seconds=$((total_seconds + elapsed))
    printf ' - %-28s %6ss (%s)\n' "$stage_name" "$elapsed" "$(format_duration_seconds "$elapsed")"
  done
  log "Total measured stage time: ${total_seconds}s ($(format_duration_seconds "$total_seconds"))"
}

print_summary() {
  log ""
  log "=== Done ==="
  log "Model: $MODEL_HF_ID"
  log "HEF:   $HEF_OUTPUT_PATH"
  log "DFC_GPU_INDEX: $DFC_GPU_INDEX"
  log "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-<unset>}"
  log "CUDA sampling: enable=$CUDA_SAMPLE_ENABLE interval=${CUDA_SAMPLE_INTERVAL_SEC}s max_samples=$CUDA_SAMPLE_MAX_SAMPLES"
  log "Translate debug: heartbeat=${TRANSLATE_HEARTBEAT_SEC}s stack_dump_enable=$TRANSLATE_STACK_DUMP_ENABLE stack_dump_interval=${TRANSLATE_STACK_DUMP_SEC}s"
  log "Mode:  $SAMPLE_MODE_LABEL (SAMPLING_PARAMS_MODE=$SAMPLING_PARAMS_MODE)"
  log "Thinking mode: $ENABLE_THINKING_MODE"
  log "Install Qwen Code: $INSTALL_QWEN_CODE"
  log "video_preprecessor_longest_edge: $VIDEO_PREPRECESSOR_LONGEST_EDGE"
  log "Runtime profile: $LOCAL_RUNTIME_PROFILE_PATH"
  if [[ "$COPY_TO_REMOTE" == "yes" ]]; then
    log "Remote path: $REMOTE_DIR"
  fi

  print_timing_summary
}

main() {
  run_timed_stage "resolve_sampling_profile" resolve_sampling_profile
  run_timed_stage "write_runtime_profile" write_runtime_profile
  run_timed_stage "verify_local_prereqs" verify_local_prereqs
  run_timed_stage "configure_gpu_selection" configure_gpu_selection
  run_timed_stage "compile_hef" compile_hef

  if [[ "$COPY_TO_REMOTE" == "yes" ]]; then
    run_timed_stage "remote_preflight" remote_preflight
    run_timed_stage "copy_to_remote" copy_to_remote
    run_timed_stage "install_qwen_code_remote" install_qwen_code_remote
    run_timed_stage "remote_hef_smoke_test" remote_hef_smoke_test
  fi

  print_summary
}

main "$@"
