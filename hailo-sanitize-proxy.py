#!/usr/bin/env python3
"""
Sanitizing reverse proxy for hailo-ollama.

Sits between OpenClaw and hailo-ollama on port 8000.
Uses OpenAI-compatible /v1/chat/completions endpoint.

Key functions:
1. Strip unsupported request fields (tools, stream_options, store)
2. Replace massive system prompt with minimal one (2048-token context)
3. Force stream:false, convert response to SSE if client requested streaming
4. Fix response: nanosecond timestamps, missing usage/system_fingerprint
5. Fake /api/show to avoid hailo-ollama DTO crash
6. Expose /v1/models for OpenAI-compatible model discovery clients

Listens on port 8081, forwards to hailo-ollama on port 8000.
"""

import http.server
import json
import os
import re
import sys
import time
import itertools
import urllib.request
import urllib.error

LISTEN_PORT = 8081
UPSTREAM = "http://127.0.0.1:8000"
DEFAULT_MODEL_ID = os.environ.get("HAILO_MODEL", "qwen2:1.5b")
WORKSPACE_SKILLS_DIR = os.path.expanduser("~/.openclaw/workspace/skills")
MAX_TOOL_DESCRIPTION_CHARS = 120
MAX_TOOL_COUNT_IN_PROMPT = 8
UPSTREAM_TIMEOUT = 300  # seconds — generation is slow (~8 tok/s)
CORS_ALLOWED_ORIGINS = {
    item.strip()
    for item in os.environ.get(
        "HAILO_PROXY_ALLOWED_ORIGINS",
        "http://localhost:8787,http://127.0.0.1:8787",
    ).split(",")
    if item.strip()
}
CORS_ALLOW_NO_ORIGIN = os.environ.get("HAILO_PROXY_ALLOW_NO_ORIGIN", "1").strip().lower() not in {
    "0", "false", "no", "off"
}
CORS_ALLOW_METHODS = "GET, POST, OPTIONS"
CORS_ALLOW_HEADERS = os.environ.get(
    "HAILO_PROXY_CORS_ALLOW_HEADERS",
    "Authorization, Content-Type, X-Requested-With",
)
ALLOWED_HOSTS = {
    item.strip().lower()
    for item in os.environ.get(
        "HAILO_PROXY_ALLOWED_HOSTS",
        "127.0.0.1:8081,localhost:8081,[::1]:8081,127.0.0.1,localhost,[::1]",
    ).split(",")
    if item.strip()
}


def _env_int(name, default):
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


TRACE_ENABLED = os.environ.get("HAILO_PROXY_TRACE", "1").strip().lower() not in {
    "0", "false", "no", "off"
}
TRACE_DIR = os.environ.get("HAILO_PROXY_TRACE_DIR", "/tmp/hailo-proxy-traces")
TRACE_MAX_BYTES = _env_int("HAILO_PROXY_TRACE_MAX_BYTES", 250000)
MAX_PROXY_COMPLETION_TOKENS = _env_int("HAILO_PROXY_MAX_TOKENS", 128)
MAX_HISTORY_MESSAGES = _env_int("HAILO_PROXY_MAX_HISTORY_MESSAGES", 1)
_TRACE_SEQ = itertools.count(1)

MINIMAL_SYSTEM_PROMPT = (
    "You are a helpful personal assistant. "
    "Answer the user's questions concisely and helpfully. "
    "If you don't know something, say so."
)

ALLOWED_CHAT_FIELDS = {
    "model", "messages", "temperature", "top_p", "n", "stream",
    "max_tokens", "max_completion_tokens", "presence_penalty",
    "frequency_penalty", "seed", "tools", "tool_choice",
    "parallel_tool_calls",
}
ALLOWED_MESSAGE_FIELDS = {
    "role", "content", "tool_calls", "name", "tool_call_id"
}
TOOL_INTENT_TOKENS = (
    " use ", " tool", "skill", "/rag", "rag ", "molt", "run ", "execute"
)

# Tools the 1.5B model can't invoke correctly — suppress these.
# File tools: model generates absolute paths outside sandbox → always fails.
# Session tools: model can't format array arguments correctly.
# Search/process: model loops endlessly on these.
# Only "exec" is allowed through (proxy can normalize the command).
BLOCKED_TOOL_NAMES = {
    "read", "write", "edit", "search", "process",
    "sessions_list", "sessions_history", "sessions_send",
    "sessions_spawn", "session_status",
}


def _next_trace_id():
    return f"{int(time.time() * 1000)}-{next(_TRACE_SEQ):06d}"


def _ensure_trace_dir():
    if not TRACE_ENABLED:
        return
    try:
        os.makedirs(TRACE_DIR, exist_ok=True)
    except Exception:
        pass


def _parse_json_dict(body_bytes):
    try:
        data = json.loads(body_bytes)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _json_preview(value, limit=220):
    try:
        text = json.dumps(value, ensure_ascii=False)
    except Exception:
        text = str(value)
    if len(text) > limit:
        return text[:limit].rstrip() + "..."
    return text


def _summarize_request_body(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return f"non-json body_bytes={len(body_bytes)}"
    keys = sorted(data.keys())
    model = data.get("model")
    stream = data.get("stream")
    max_tokens = data.get("max_tokens")
    max_completion_tokens = data.get("max_completion_tokens")
    msg_count = 0
    role_counts = {}
    content_chars = 0
    if isinstance(data.get("messages"), list):
        msg_count = len(data["messages"])
        for msg in data["messages"]:
            if not isinstance(msg, dict):
                continue
            role = msg.get("role", "unknown")
            role_counts[role] = role_counts.get(role, 0) + 1
            content = msg.get("content", "")
            if isinstance(content, list):
                for part in content:
                    if isinstance(part, dict):
                        content_chars += len(str(part.get("text", "")))
                    else:
                        content_chars += len(str(part))
            else:
                content_chars += len(str(content))
    tools_count = len(data.get("tools", [])) if isinstance(data.get("tools"), list) else 0
    return (
        f"model={model} stream={stream} keys={','.join(keys)} "
        f"messages={msg_count} roles={_json_preview(role_counts, 100)} chars={content_chars} "
        f"max_tokens={max_tokens} max_completion_tokens={max_completion_tokens} tools={tools_count}"
    )


def _summarize_response_body(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return f"non-json body_bytes={len(body_bytes)}"
    choices = data.get("choices") if isinstance(data.get("choices"), list) else []
    content_preview = ""
    if choices and isinstance(choices[0], dict):
        msg = choices[0].get("message")
        if isinstance(msg, dict):
            content_preview = _json_preview(msg.get("content", ""), 140)
        else:
            content_preview = _json_preview(choices[0].get("text", ""), 140)
    usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    return (
        f"id={data.get('id')} model={data.get('model')} object={data.get('object')} "
        f"choices={len(choices)} content_preview={content_preview} usage={_json_preview(usage, 140)}"
    )


def _extract_tool_names(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return set()
    tools = data.get("tools")
    if not isinstance(tools, list):
        return set()
    names = set()
    for item in tools:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "function":
            continue
        fn = item.get("function")
        if not isinstance(fn, dict):
            continue
        name = fn.get("name")
        if isinstance(name, str) and name:
            names.add(name)
    return names


def _extract_latest_user_text(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return ""
    messages = data.get("messages")
    if not isinstance(messages, list):
        return ""
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "user":
            continue
        content = msg.get("content", "")
        if isinstance(content, list):
            parts = []
            for part in content:
                if isinstance(part, dict):
                    if part.get("type") == "text":
                        parts.append(str(part.get("text", "")))
                elif isinstance(part, str):
                    parts.append(part)
            return "\n".join(parts)
        return str(content)
    return ""


def _has_explicit_tool_intent(text):
    normalized = f" {str(text or '').strip().lower()} "
    if not normalized.strip():
        return False
    return any(token in normalized for token in TOOL_INTENT_TOKENS)


def _write_trace(trace_id, suffix, body_bytes):
    if not TRACE_ENABLED:
        return
    _ensure_trace_dir()
    try:
        payload = body_bytes if isinstance(body_bytes, (bytes, bytearray)) else str(body_bytes).encode("utf-8", errors="replace")
        if len(payload) > TRACE_MAX_BYTES:
            marker = (
                f"\n\n...TRUNCATED... original_bytes={len(payload)} limit={TRACE_MAX_BYTES}\n"
            ).encode("utf-8")
            payload = payload[:TRACE_MAX_BYTES] + marker
        path = os.path.join(TRACE_DIR, f"{trace_id}-{suffix}")
        with open(path, "wb") as f:
            f.write(payload)
    except Exception:
        pass


def sanitize_chat_body(body_bytes, tool_prompt_enabled=True):
    """Strip unsupported fields from /v1/chat/completions request."""
    try:
        data = json.loads(body_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body_bytes
    if not isinstance(data, dict):
        return body_bytes

    sanitized = {
        k: v for k, v in data.items() if k in ALLOWED_CHAT_FIELDS and v is not None
    }
    tools_payload = sanitized.pop("tools", None)
    if not tool_prompt_enabled:
        tools_payload = None
    if tools_payload is not None:
        try:
            with open("/tmp/hailo-proxy-tools.json", "w", encoding="utf-8") as f:
                json.dump(tools_payload, f, indent=2)
        except Exception:
            pass

    if "messages" in sanitized and isinstance(sanitized["messages"], list):
        clean_msgs = []
        for msg in sanitized["messages"]:
            if not isinstance(msg, dict):
                continue
            clean_msg = {k: v for k, v in msg.items() if k in ALLOWED_MESSAGE_FIELDS}
            if isinstance(clean_msg.get("content"), list):
                parts = []
                for part in clean_msg["content"]:
                    if isinstance(part, dict) and part.get("type") == "text":
                        parts.append(part.get("text", ""))
                    elif isinstance(part, str):
                        parts.append(part)
                clean_msg["content"] = "\n".join(parts)
            if clean_msg.get("content") is None:
                clean_msg["content"] = ""
            clean_msgs.append(clean_msg)
        sanitized["messages"] = clean_msgs

    sanitized["stream"] = False

    max_tokens = sanitized.get("max_tokens")
    max_completion_tokens = sanitized.get("max_completion_tokens")
    if isinstance(max_tokens, int) and max_tokens > 0:
        sanitized["max_tokens"] = min(max_tokens, MAX_PROXY_COMPLETION_TOKENS)
    elif isinstance(max_completion_tokens, int) and max_completion_tokens > 0:
        sanitized["max_tokens"] = min(max_completion_tokens, MAX_PROXY_COMPLETION_TOKENS)
    else:
        sanitized["max_tokens"] = MAX_PROXY_COMPLETION_TOKENS
    sanitized.pop("max_completion_tokens", None)

    if isinstance(sanitized.get("n"), int) and sanitized["n"] > 1:
        sanitized["n"] = 1

    if "messages" in sanitized:
        tool_prompt = build_tool_prompt(tools_payload)
        sanitized["messages"] = simplify_messages(sanitized["messages"], tool_prompt)

    return json.dumps(sanitized).encode("utf-8")


def simplify_messages(messages, tool_prompt=None):
    """Replace OpenClaw's massive system prompt with a minimal one."""
    if not messages:
        return messages
    # Keep only user messages to avoid confusing the model with orphaned
    # tool/assistant messages (which cause "I can't help with that" refusals).
    user_msgs = [m for m in messages if m.get("role") == "user"]
    if len(user_msgs) > MAX_HISTORY_MESSAGES:
        user_msgs = user_msgs[-MAX_HISTORY_MESSAGES:]
    other_msgs = user_msgs
    original_sys_msgs = [m.get("content", "") for m in messages if m.get("role") == "system"]
    original_sys_len = sum(len(c) for c in original_sys_msgs)
    if original_sys_len > len(MINIMAL_SYSTEM_PROMPT):
        sys.stderr.write(
            "hailo-sanitize-proxy: replaced system prompt (%d -> %d chars)\n"
            % (original_sys_len, len(MINIMAL_SYSTEM_PROMPT))
        )
        sys.stderr.flush()
        if original_sys_msgs:
            dump_path = "/tmp/hailo-proxy-system-prompt.txt"
            try:
                with open(dump_path, "w", encoding="utf-8") as f:
                    f.write("\n\n".join(original_sys_msgs))
            except Exception:
                pass
    system_content = MINIMAL_SYSTEM_PROMPT
    skills_block = build_skills_block_from_workspace()
    if tool_prompt:
        system_content = f"{system_content}\n\n{tool_prompt}"
    if skills_block:
        system_content = f"{system_content}\n\nAvailable skills:\n{skills_block}"
    try:
        with open("/tmp/hailo-proxy-sanitized-system-prompt.txt", "w", encoding="utf-8") as f:
            f.write(system_content)
    except Exception:
        pass
    return [{"role": "system", "content": system_content}] + other_msgs


def build_tool_prompt(tools_payload):
    if not tools_payload or not isinstance(tools_payload, list):
        return ""
    lines = [
        "Tool usage:",
        "- If a tool is needed, respond ONLY with JSON:",
        '  {"tool": "<name>", "arguments": { ... }}',
        "- Otherwise, respond normally.",
        "Available tools:",
    ]
    tool_count = 0
    for tool in tools_payload:
        if not isinstance(tool, dict):
            continue
        if tool.get("type") != "function":
            continue
        fn = tool.get("function", {})
        name = fn.get("name")
        if not name:
            continue
        desc = fn.get("description", "").strip().replace("\n", " ")
        if len(desc) > MAX_TOOL_DESCRIPTION_CHARS:
            desc = desc[:MAX_TOOL_DESCRIPTION_CHARS].rstrip() + "..."
        params = fn.get("parameters", {})
        props = params.get("properties", {}) if isinstance(params, dict) else {}
        args = ", ".join(sorted(props.keys())) if isinstance(props, dict) else ""
        label = f"- {name}"
        if desc:
            label += f": {desc}"
        if args:
            label += f" (args: {args})"
        lines.append(label)
        tool_count += 1
        if tool_count >= MAX_TOOL_COUNT_IN_PROMPT:
            lines.append("- ...")
            break
    return "\n".join(lines)


def extract_skills_block(system_text):
    if not system_text:
        return ""
    match = re.search(r"<available_skills>(.*?)</available_skills>", system_text, re.DOTALL)
    if not match:
        return ""
    block = match.group(1).strip()
    if not block:
        return ""
    return block


def build_skills_block_from_workspace():
    if not os.path.isdir(WORKSPACE_SKILLS_DIR):
        return ""
    skills = []
    for entry in sorted(os.listdir(WORKSPACE_SKILLS_DIR)):
        skill_dir = os.path.join(WORKSPACE_SKILLS_DIR, entry)
        skill_md = os.path.join(skill_dir, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        name = None
        desc = ""
        try:
            with open(skill_md, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
            if lines and lines[0].strip() == "---":
                for line in lines[1:]:
                    if line.strip() == "---":
                        break
                    if line.startswith("name:"):
                        name = line.split(":", 1)[1].strip()
                    elif line.startswith("description:"):
                        desc = line.split(":", 1)[1].strip()
        except Exception:
            continue
        if not name:
            name = entry
        skills.append({
            "name": name,
            "description": desc,
            "location": skill_md,
        })
    if not skills:
        return ""
    parts = ["<available_skills>"]
    for skill in skills:
        parts.append("  <skill>")
        parts.append(f"    <name>{skill['name']}</name>")
        if skill["description"]:
            parts.append(f"    <description>{skill['description']}</description>")
        parts.append(f"    <location>{skill['location']}</location>")
        parts.append("  </skill>")
    parts.append("</available_skills>")
    return "\n".join(parts)


def parse_tool_call(content, allowed_names=None):
    if not content or not isinstance(content, str):
        return None
    raw = content.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw.replace("json", "", 1).strip()

    payload = None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        start = raw.find("{")
        if start != -1:
            depth = 0
            end = -1
            for idx, ch in enumerate(raw[start:], start=start):
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = idx + 1
                        break
            if end != -1:
                candidate = raw[start:end]
                try:
                    payload = json.loads(candidate)
                except json.JSONDecodeError:
                    return None
            else:
                return None
        else:
            name_match = re.search(
                r'"(?:tool|name|tool_name|skill)"\s*:\s*"([^"]+)"', raw
            )
            if not name_match:
                return None
            payload = {"tool": name_match.group(1), "arguments": {}}

            command_match = re.search(r'"command"\s*:\s*"([^"]+)"', raw)
            file_path_match = re.search(
                r'"(?:file_path|path)"\s*:\s*"([^"]+)"', raw
            )
            message_match = re.search(r'"message"\s*:\s*"([^"]+)"', raw)
            session_key_match = re.search(r'"sessionKey"\s*:\s*"([^"]+)"', raw)

            if command_match:
                payload["arguments"]["command"] = command_match.group(1)
            if file_path_match:
                payload["arguments"]["file_path"] = file_path_match.group(1)
            if message_match:
                payload["arguments"]["message"] = message_match.group(1)
            if session_key_match:
                payload["arguments"]["sessionKey"] = session_key_match.group(1)
    if not isinstance(payload, dict):
        return None
    name = payload.get("tool") or payload.get("name") or payload.get("tool_name") or payload.get("skill")
    args = payload.get("arguments") or payload.get("args") or {}
    if not name:
        return None
    if allowed_names is not None and name not in allowed_names:
        try:
            sys.stderr.write(
                "hailo-sanitize-proxy: forwarding unknown tool name from model: %s\n"
                % name
            )
            sys.stderr.flush()
        except Exception:
            pass
    if not isinstance(args, dict):
        return None
    return {"name": name, "arguments": args}


def normalize_exec_command(command):
    if not isinstance(command, str):
        return ""
    cmd = command.strip()
    if cmd.startswith(". "):
        cmd = cmd[2:].strip()
    if cmd.endswith(".py") and not cmd.startswith("python"):
        cmd = f"python3 {cmd}"
    return cmd


def _has_rag_intent(text):
    norm = str(text or "").lower()
    return "rag" in norm


def remap_tool_call(tool_call, latest_user_text, allowed_tool_names):
    if not tool_call or not isinstance(tool_call, dict):
        return tool_call

    name = tool_call.get("name")
    args = tool_call.get("arguments") if isinstance(tool_call.get("arguments"), dict) else {}

    # Block internal tools the small model can't use correctly
    if name in BLOCKED_TOOL_NAMES:
        try:
            sys.stderr.write(
                "hailo-sanitize-proxy: suppressing blocked tool call: %s\n" % name
            )
            sys.stderr.flush()
        except Exception:
            pass
        return None

    if name == "exec":
        cmd = normalize_exec_command(args.get("command", ""))
        if cmd:
            tool_call["arguments"] = {"command": cmd}
        return tool_call

    return tool_call


def sanitize_response(
    data,
    allowed_tool_names=None,
    tool_calls_enabled=True,
    latest_user_text="",
):
    """Fix hailo-ollama response for OpenAI SDK compatibility."""
    try:
        resp = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return data
    if not isinstance(resp, dict):
        return data

    created = resp.get("created", 0)
    if isinstance(created, int) and created > 1e15:
        resp["created"] = int(created // 1000000000)
    elif not created:
        resp["created"] = int(time.time())

    resp.setdefault("object", "chat.completion")
    resp.setdefault("system_fingerprint", "hailo-ollama")

    total_chars = 0
    if "choices" in resp:
        for choice in resp["choices"]:
            choice.setdefault("finish_reason", "stop")
            choice.setdefault("logprobs", None)
            msg = choice.get("message", {})
            content = msg.get("content", "")
            tool_call = None
            if tool_calls_enabled:
                tool_call = parse_tool_call(content, allowed_names=allowed_tool_names)
                tool_call = remap_tool_call(
                    tool_call,
                    latest_user_text=latest_user_text,
                    allowed_tool_names=allowed_tool_names,
                )
            total_chars += len(content)
            choice["message"] = {
                "role": msg.get("role", "assistant"),
                "content": content,
                "refusal": None,
            }
            if tool_call:
                choice["message"]["content"] = ""
                choice["message"]["tool_calls"] = [
                    {
                        "id": f"call_{int(time.time() * 1000)}",
                        "type": "function",
                        "function": {
                            "name": tool_call["name"],
                            "arguments": json.dumps(tool_call["arguments"]),
                        },
                    }
                ]

    if "usage" not in resp:
        est_tokens = max(1, total_chars // 4)
        resp["usage"] = {
            "prompt_tokens": 100,
            "completion_tokens": est_tokens,
            "total_tokens": 100 + est_tokens,
        }

    return json.dumps(resp).encode("utf-8")


def to_sse(data):
    """Convert a non-streaming response to SSE format for the OpenAI SDK."""
    try:
        resp = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return b"data: " + data + b"\n\ndata: [DONE]\n\n"

    cid = resp.get("id", "chatcmpl-0")
    model = resp.get("model", "unknown")
    created = resp.get("created", int(time.time()))
    fp = resp.get("system_fingerprint", "hailo-ollama")
    usage = resp.get("usage", {})
    content = ""
    tool_calls = None
    if resp.get("choices"):
        msg = resp["choices"][0].get("message", {})
        content = msg.get("content", "")
        tool_calls = msg.get("tool_calls")

    parts = []
    # role chunk
    parts.append("data: %s\n\n" % json.dumps({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": model, "system_fingerprint": fp,
        "choices": [{"index": 0, "delta": {"role": "assistant", "content": "", "refusal": None},
                     "logprobs": None, "finish_reason": None}],
    }))
    # tool call chunk
    if tool_calls:
        parts.append("data: %s\n\n" % json.dumps({
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model, "system_fingerprint": fp,
            "choices": [{"index": 0, "delta": {"tool_calls": tool_calls},
                         "logprobs": None, "finish_reason": None}],
        }))
    # content chunk
    if content and not tool_calls:
        parts.append("data: %s\n\n" % json.dumps({
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model, "system_fingerprint": fp,
            "choices": [{"index": 0, "delta": {"content": content},
                         "logprobs": None, "finish_reason": None}],
        }))
    # finish chunk
    parts.append("data: %s\n\n" % json.dumps({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": model, "system_fingerprint": fp,
        "choices": [{"index": 0, "delta": {}, "logprobs": None, "finish_reason": "stop"}],
        "usage": usage,
    }))
    parts.append("data: [DONE]\n\n")
    return "".join(parts).encode("utf-8")


def convert_chat_to_completion(data):
    try:
        resp = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return data
    if not isinstance(resp, dict):
        return data
    choice = None
    if resp.get("choices"):
        choice = resp["choices"][0]
    text = ""
    finish_reason = None
    if choice:
        msg = choice.get("message", {})
        text = msg.get("content", "") or ""
        finish_reason = choice.get("finish_reason")
    completion = {
        "id": resp.get("id", "cmpl-0"),
        "object": "text_completion",
        "created": resp.get("created", int(time.time())),
        "model": resp.get("model", "unknown"),
        "choices": [
            {
                "index": 0,
                "text": text,
                "logprobs": None,
                "finish_reason": finish_reason or "stop",
            }
        ],
    }
    if "usage" in resp:
        completion["usage"] = resp["usage"]
    return json.dumps(completion).encode("utf-8")


def fake_api_show(body_bytes):
    """Return a fake /api/show response to avoid hailo-ollama's DTO crash."""
    try:
        data = json.loads(body_bytes)
    except Exception:
        data = {}
    model = data.get("name", data.get("model", "qwen2:1.5b"))
    return json.dumps({
        "modelfile": "FROM %s" % model,
        "parameters": "stop <|im_end|>",
        "template": "{{ .System }}{{ .Prompt }}",
        "details": {
            "parent_model": "", "format": "gguf", "family": "qwen2",
            "families": ["qwen2"], "parameter_size": "1.5B",
            "quantization_level": "Q4_0",
        },
        "model_info": {},
    }).encode("utf-8")


def _unique_model_ids(values):
    seen = set()
    ordered = []
    for value in values:
        if not isinstance(value, str):
            continue
        model_id = value.strip()
        if not model_id:
            continue
        if model_id in seen:
            continue
        seen.add(model_id)
        ordered.append(model_id)
    return ordered


def discover_upstream_model_ids():
    """Discover models from upstream `/api/tags` with local fallback."""
    tags_url = "%s/api/tags" % UPSTREAM
    discovered = []

    try:
        req = urllib.request.Request(tags_url, method="GET")
        with urllib.request.urlopen(req, timeout=8) as resp:
            payload = json.loads(resp.read())
    except Exception:
        payload = None

    if isinstance(payload, dict):
        rows = payload.get("models")
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    name = row.get("name") or row.get("model") or row.get("id")
                else:
                    name = row
                if isinstance(name, str):
                    discovered.append(name)

        rows = payload.get("data")
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    name = row.get("id") or row.get("name") or row.get("model")
                else:
                    name = row
                if isinstance(name, str):
                    discovered.append(name)

    models = _unique_model_ids(discovered)
    if not models:
        models = [DEFAULT_MODEL_ID]
    return models


def fake_v1_models_list():
    now = int(time.time())
    models = [
        {
            "id": model_id,
            "object": "model",
            "created": now,
            "owned_by": "hailo-ollama",
        }
        for model_id in discover_upstream_model_ids()
    ]
    return json.dumps({"object": "list", "data": models}).encode("utf-8")


def fake_v1_model(model_id):
    now = int(time.time())
    return json.dumps(
        {
            "id": model_id,
            "object": "model",
            "created": now,
            "owned_by": "hailo-ollama",
        }
    ).encode("utf-8")


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_OPTIONS(self):
        trace_id = _next_trace_id()
        started = time.time()
        path = self.path.rstrip("/")
        if not self._validate_request_security(trace_id, "OPTIONS", path, started):
            return
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: OPTIONS %s -> 204 preflight duration_ms=%d\n"
            % (trace_id, path, int((time.time() - started) * 1000))
        )
        sys.stderr.flush()

    def _origin_header(self):
        origin = self.headers.get("Origin")
        return origin.strip() if origin else ""

    def _host_header(self):
        host = self.headers.get("Host")
        return host.strip().lower() if host else ""

    def _is_origin_allowed(self, origin):
        if not origin:
            return CORS_ALLOW_NO_ORIGIN
        return origin in CORS_ALLOWED_ORIGINS

    def _is_host_allowed(self, host):
        if not host:
            return False
        return host in ALLOWED_HOSTS

    def _deny_request(self, trace_id, method, path, started, reason, details):
        payload = json.dumps({"error": reason, "details": details}).encode("utf-8")
        self._send_json(403, payload)
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: %s %s -> 403 denied reason=%s details=%s duration_ms=%d\n"
            % (trace_id, method, path, reason, details, int((time.time() - started) * 1000))
        )
        sys.stderr.flush()

    def _validate_request_security(self, trace_id, method, path, started):
        host = self._host_header()
        if not self._is_host_allowed(host):
            self._deny_request(trace_id, method, path, started, "forbidden host", host or "(missing)")
            return False

        origin = self._origin_header()
        if not self._is_origin_allowed(origin):
            self._deny_request(trace_id, method, path, started, "forbidden origin", origin or "(missing)")
            return False

        return True

    def _send_cors_headers(self):
        origin = self._origin_header()
        if not origin:
            return
        if origin not in CORS_ALLOWED_ORIGINS:
            return
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", CORS_ALLOW_METHODS)
        self.send_header("Access-Control-Allow-Headers", CORS_ALLOW_HEADERS)
        self.send_header("Access-Control-Max-Age", "86400")

    def end_headers(self):
        self._send_cors_headers()
        super().end_headers()

    def _proxy(self, method):
        trace_id = _next_trace_id()
        started = time.time()
        path = self.path.rstrip("/")
        if not self._validate_request_security(trace_id, method, path, started):
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        allowed_tool_names = _extract_tool_names(body) if body else set()
        latest_user_text = _extract_latest_user_text(body) if body else ""
        allow_tool_calls = _has_explicit_tool_intent(latest_user_text)

        _write_trace(trace_id, "client-request.raw", body)
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: IN %s %s bytes=%d summary=%s\n"
            % (trace_id, method, path, len(body), _summarize_request_body(body))
        )
        if body:
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: TOOL_INTENT enabled=%s latest_user=%s\n"
                % (trace_id, allow_tool_calls, _json_preview(latest_user_text, 180))
            )
        sys.stderr.flush()

        # Fake /api/show
        if path == "/api/show" and method == "POST":
            resp_body = fake_api_show(body)
            _write_trace(trace_id, "proxy-response.fake-api-show", resp_body)
            self._send_json(200, resp_body)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 200 faked duration_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            return

        # OpenAI-compatible model discovery for clients (Nanobot, Moltis, etc.)
        if path == "/v1/models" and method == "GET":
            resp_body = fake_v1_models_list()
            _write_trace(trace_id, "proxy-response.fake-v1-models", resp_body)
            self._send_json(200, resp_body)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 200 faked model list duration_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            return

        if path.startswith("/v1/models/") and method == "GET":
            model_id = path.split("/v1/models/", 1)[1].strip()
            if not model_id:
                self._send_json(404, b'{"error":"model not found"}')
                return
            resp_body = fake_v1_model(model_id)
            _write_trace(trace_id, "proxy-response.fake-v1-model", resp_body)
            self._send_json(200, resp_body)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 200 faked model detail duration_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            return

        # Detect streaming + sanitize for chat completions
        client_wants_stream = False
        is_chat = path == "/v1/chat/completions" and method == "POST"
        is_completion = path == "/v1/completions" and method == "POST"
        original_body = body
        if is_completion and body:
            try:
                payload = json.loads(body)
            except (json.JSONDecodeError, UnicodeDecodeError):
                payload = None
            if isinstance(payload, dict):
                prompt = payload.get("prompt", "")
                model = payload.get("model")
                chat_payload = {
                    "model": model,
                    "messages": [{"role": "user", "content": prompt or ""}],
                    "temperature": payload.get("temperature"),
                    "top_p": payload.get("top_p"),
                    "max_tokens": payload.get("max_tokens"),
                    "stream": False,
                }
                body = json.dumps(chat_payload).encode("utf-8")
                is_chat = True
        if is_chat and body:
            try:
                client_wants_stream = json.loads(body).get("stream", False)
            except Exception:
                pass
            body = sanitize_chat_body(body, tool_prompt_enabled=allow_tool_calls)

        upstream_path = "/v1/chat/completions" if is_completion else self.path

        _write_trace(trace_id, "upstream-request.body", body)
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: UPSTREAM %s %s body_bytes=%d summary=%s\n"
            % (trace_id, method, upstream_path, len(body), _summarize_request_body(body))
        )
        sys.stderr.flush()

        url = "%s%s" % (UPSTREAM, upstream_path)
        req = urllib.request.Request(url, data=body if body else None, method=method)
        for header in self.headers:
            lower = header.lower()
            if lower not in (
                "host",
                "content-length",
                "transfer-encoding",
                "origin",
                "access-control-request-method",
                "access-control-request-headers",
            ):
                req.add_header(header, self.headers[header])
        if body:
            req.add_header("Content-Length", str(len(body)))

        try:
            upstream_started = time.time()
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
            data = resp.read()
            _write_trace(trace_id, "upstream-response.raw", data)

            upstream_ms = int((time.time() - upstream_started) * 1000)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: UPSTREAM-RESP %s %s status=%d duration_ms=%d bytes=%d summary=%s\n"
                % (trace_id, method, upstream_path, resp.status, upstream_ms, len(data), _summarize_response_body(data))
            )
            sys.stderr.flush()

            if is_chat:
                data = sanitize_response(
                    data,
                    allowed_tool_names=allowed_tool_names,
                    tool_calls_enabled=allow_tool_calls,
                    latest_user_text=latest_user_text,
                )
            if is_completion:
                data = convert_chat_to_completion(data)

            _write_trace(trace_id, "proxy-response.final", data)

            if is_chat and client_wants_stream and not is_completion:
                sse_data = to_sse(data)
                _write_trace(trace_id, "proxy-response.sse", sse_data)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.send_header("Content-Length", str(len(sse_data)))
                self.end_headers()
                self.wfile.write(sse_data)
                self.wfile.flush()
                sys.stderr.write(
                    "hailo-sanitize-proxy[%s]: %s %s -> %d SSE (%d bytes) duration_ms=%d\n"
                    % (trace_id, method, path, resp.status, len(sse_data), int((time.time() - started) * 1000))
                )
            else:
                self._send_json(resp.status, data)
                sys.stderr.write(
                    "hailo-sanitize-proxy[%s]: %s %s -> %d (%d bytes) duration_ms=%d\n"
                    % (trace_id, method, path, resp.status, len(data), int((time.time() - started) * 1000))
                )
            sys.stderr.flush()
        except urllib.error.HTTPError as e:
            err_data = e.read()
            _write_trace(trace_id, "upstream-response.error", err_data)
            if is_chat and e.code == 500:
                try:
                    ts = int(time.time())
                    with open(f"/tmp/hailo-proxy-500-raw-{ts}.json", "wb") as f:
                        f.write(original_body or b"")
                    with open(f"/tmp/hailo-proxy-500-sanitized-{ts}.json", "wb") as f:
                        f.write(body or b"")
                except Exception:
                    pass
            self.send_response(e.code)
            for h, v in e.headers.items():
                if h.lower() not in ("transfer-encoding",):
                    self.send_header(h, v)
            self.end_headers()
            self.wfile.write(err_data)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> %d ERROR duration_ms=%d summary=%s\n"
                % (trace_id, method, path, e.code, int((time.time() - started) * 1000), _summarize_response_body(err_data))
            )
            sys.stderr.flush()
        except TimeoutError:
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 504 TIMEOUT after_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            try:
                self._send_json(504, b'{"error":"upstream timeout"}')
            except BrokenPipeError:
                pass
        except BrokenPipeError:
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> client disconnected (broken pipe) after_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
        except Exception as e:
            try:
                msg = ("Proxy error: %s" % e).encode("utf-8")
                self._send_json(502, msg)
            except BrokenPipeError:
                pass
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 502 EXCEPTION after_ms=%d: %s\n"
                % (trace_id, method, path, int((time.time() - started) * 1000), e)
            )
            sys.stderr.flush()

    def _send_json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


def main():
    _ensure_trace_dir()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
    server.daemon_threads = True
    print(
        "hailo-sanitize-proxy: listening on 127.0.0.1:%d -> %s"
        % (LISTEN_PORT, UPSTREAM),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
