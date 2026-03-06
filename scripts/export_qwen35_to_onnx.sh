#!/usr/bin/env bash
set -euo pipefail

# Export Qwen3.5-0.8B from HuggingFace to ONNX format using venv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$REPO_ROOT/venv_onnx_export"

MODEL_HF_ID="${MODEL_HF_ID:-Qwen/Qwen3.5-0.8B}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/onnx_export/qwen3.5-0.8b}"
EXPORT_ONNX_PATH="${EXPORT_ONNX_PATH:-$OUTPUT_DIR/model.onnx}"

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

setup_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
  fi
  
  log "Installing dependencies into venv..."
  "$VENV_DIR/bin/pip" install --upgrade pip
  # Install from main branch (shallow clone for speed) to get latest model support
  "$VENV_DIR/bin/pip" install "git+https://github.com/huggingface/transformers.git@main" --no-deps
  # Install required deps including optimum with ONNX support
  "$VENV_DIR/bin/pip" install torch accelerate onnx onnxscript \
    optimum onnxruntime \
    huggingface-hub tokenizers safetensors numpy pyyaml regex tqdm coloredlogs
}

export_model() {
  log "Exporting $MODEL_HF_ID to ONNX via legacy exporter..."
  mkdir -p "$OUTPUT_DIR"
  
  "$VENV_DIR/bin/python" - <<PY
import os
import warnings
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from transformers.utils import logging as hf_logging

warnings.filterwarnings('ignore')
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
hf_logging.set_verbosity_error()
hf_logging.disable_progress_bar()

def short_err(e):
    msg = str(e).replace("\n", " ").replace("\r", " ")
    if len(msg) > 600:
        msg = msg[:600] + "..."
    return f"{type(e).__name__}: {msg}"

if hasattr(torch.backends, "cuda"):
    try:
        torch.backends.cuda.enable_flash_sdp(False)
        torch.backends.cuda.enable_mem_efficient_sdp(False)
        torch.backends.cuda.enable_math_sdp(True)
    except Exception:
        pass

model_id = "$MODEL_HF_ID"
output_path = "$EXPORT_ONNX_PATH"
output_dir = os.path.dirname(output_path)

print(f"Loading model: {model_id}")
model = AutoModelForCausalLM.from_pretrained(
    model_id,
    dtype=torch.float32,
    device_map=None,
    low_cpu_mem_usage=False,
    trust_remote_code=True,
    attn_implementation="eager"
)
model.eval()

print(f"Loading tokenizer...")
tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)

# Create dummy inputs
dummy_input = tokenizer("Hello", return_tensors="pt")
input_ids = dummy_input['input_ids']
attention_mask = dummy_input['attention_mask']

print(f"Exporting to ONNX with legacy TorchScript exporter...")

# Force legacy TorchScript-based exporter (PyTorch 2.6+)
# by setting torch.onnx.dynamo_export = None or using scripting
try:
    # Try scripting the model first to handle control flow
    print("Attempting torch.jit.script...")
    scripted = torch.jit.script(model, example_inputs=(input_ids, attention_mask))
    torch.onnx.export(
        scripted,
        (input_ids, attention_mask),
        output_path,
        input_names=['input_ids', 'attention_mask'],
        output_names=['logits'],
        opset_version=14,
        do_constant_folding=True
    )
    print(f"Scripted ONNX export complete!")
except Exception as e1:
    print(f"Scripting failed: {short_err(e1)}")
    print("Falling back to tracing with strict=False...")
    try:
        # Use trace with strict=False for control flow
        with torch.no_grad():
            traced = torch.jit.trace(
                lambda ids, mask: model(input_ids=ids, attention_mask=mask, use_cache=False).logits,
                (input_ids, attention_mask),
                strict=False
            )
        torch.onnx.export(
            traced,
            (input_ids, attention_mask),
            output_path,
            input_names=['input_ids', 'attention_mask'],
            output_names=['logits'],
            dynamic_axes={
                'input_ids': {0: 'batch_size', 1: 'sequence_length'},
                'attention_mask': {0: 'batch_size', 1: 'sequence_length'},
                'logits': {0: 'batch_size', 1: 'sequence_length'}
            },
            opset_version=14,
            do_constant_folding=True
        )
        print(f"Traced ONNX export complete!")
    except Exception as e2:
        print(f"Tracing also failed: {short_err(e2)}")
        print("Trying minimal export without cache...")
        # Final fallback: simple forward
        class SimpleWrapper(torch.nn.Module):
            def __init__(self, base_model):
                super().__init__()
                self.base = base_model
            def forward(self, input_ids, attention_mask):
                return self.base(input_ids=input_ids, attention_mask=attention_mask, use_cache=False).logits
        
        wrapped = SimpleWrapper(model)
        wrapped.eval()
        
        # Try to export wrapped model
        torch.onnx.export(
            wrapped,
            (input_ids, attention_mask),
            output_path,
            input_names=['input_ids', 'attention_mask'],
            output_names=['logits'],
            opset_version=14,
            do_constant_folding=True
        )
        print(f"Wrapped ONNX export complete!")

print(f"ONNX export successful: {output_path}")
print(f"File size: {os.path.getsize(output_path) / (1024*1024):.1f} MB")

tokenizer.save_pretrained(output_dir)
print(f"Tokenizer config saved to: {output_dir}")
PY

  [[ -f "$EXPORT_ONNX_PATH" ]] || fail "Export failed - ONNX file not found"
  ls -lh "$EXPORT_ONNX_PATH"
}

print_summary() {
  log ""
  log "=== Export Complete ==="
  log "ONNX file: $EXPORT_ONNX_PATH"
  log ""
  log "Next: Run compile script with:"
  log "  ONNX_PATH=$EXPORT_ONNX_PATH \\"
  log "  SSH_HOST=raspberrypi SSH_USER=sanchobot \\"
  log "  ENABLE_THINKING_MODE=yes SAMPLING_PARAMS_MODE=4 \\"
  log "  bash scripts/compile_qwen35_h10_over_ssh.sh"
}

main() {
  setup_venv
  export_model
  print_summary
}

main "$@"
