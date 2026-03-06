# Qwen3.5 Script Quick Guide

This directory contains the end-to-end helper scripts for:
1) exporting Qwen3.5-0.8B to ONNX,
2) optionally running export safely in background,
3) compiling ONNX to a Hailo HEF.

## 1) `export_qwen35_to_onnx.sh`
Exports `Qwen/Qwen3.5-0.8B` to ONNX and saves tokenizer files.

### Basic usage
```bash
bash scripts/export_qwen35_to_onnx.sh
```

### Useful env vars
```bash
MODEL_HF_ID=Qwen/Qwen3.5-0.8B
OUTPUT_DIR=$PWD/onnx_export/qwen3.5-0.8b
EXPORT_ONNX_PATH=$OUTPUT_DIR/model.onnx
```

### Expected output
- ONNX: `onnx_export/qwen3.5-0.8b/model.onnx`
- Tokenizer/config files in the same output directory

---

## 2) `run_qwen35_export_safe.sh`
Runs export detached with persistent logs/state (good for long runs).

### Commands
```bash
bash scripts/run_qwen35_export_safe.sh start
bash scripts/run_qwen35_export_safe.sh status
bash scripts/run_qwen35_export_safe.sh tail
bash scripts/run_qwen35_export_safe.sh stop
```

### Runtime files
- PID/state/logs under: `.run/qwen35_export/`

---

## 3) `compile_qwen35_h10_over_ssh.sh`
Compiles ONNX to HEF using Hailo DFC (x86 host), and can optionally copy/test on Raspberry Pi.

### Minimal local compile (no remote steps)
```bash
PYTHON_BIN=$PWD/venv_hailo_dfc312/bin/python \
ONNX_PATH=$PWD/onnx_export/qwen3.5-0.8b/model.onnx \
COPY_TO_REMOTE=no RUN_REMOTE_TEST=no \
bash scripts/compile_qwen35_h10_over_ssh.sh
```

### Compile + remote copy/smoke test
```bash
PYTHON_BIN=$PWD/venv_hailo_dfc312/bin/python \
ONNX_PATH=$PWD/onnx_export/qwen3.5-0.8b/model.onnx \
SSH_HOST=raspberrypi SSH_USER=sanchobot \
bash scripts/compile_qwen35_h10_over_ssh.sh
```

### Common env vars
```bash
DFC_GPU_INDEX=0                  # or "all" or "0,1"
CUDA_SAMPLE_ENABLE=yes
CUDA_SAMPLE_INTERVAL_SEC=120
TRANSLATE_HEARTBEAT_SEC=30
TRANSLATE_STACK_DUMP_ENABLE=yes
```

### Expected output
- HEF: `artifacts/qwen3.5-0.8b/qwen3.5-0.8b.hef`
- Runtime profile JSON in the same artifacts directory

---

## Typical flow
1. Export ONNX (`export_qwen35_to_onnx.sh` or safe wrapper).
2. Compile HEF (`compile_qwen35_h10_over_ssh.sh`).
3. Enable remote copy/test only when Pi runtime deps are ready.
