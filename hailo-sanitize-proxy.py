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

Listens on port 8081, forwards to hailo-ollama on port 8000.
"""

import http.server
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error

LISTEN_PORT = 8081
UPSTREAM = "http://127.0.0.1:8000"
WORKSPACE_SKILLS_DIR = os.path.expanduser("~/.openclaw/workspace/skills")
SKILL_DETAIL_NAMES = {"molt_tools"}
MAX_SKILL_DETAIL_CHARS = 2000
UPSTREAM_TIMEOUT = 300  # seconds — generation is slow (~8 tok/s)

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


def sanitize_chat_body(body_bytes):
    """Strip unsupported fields from /v1/chat/completions request."""
    try:
        data = json.loads(body_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body_bytes
    if not isinstance(data, dict):
        return body_bytes

    sanitized = {k: v for k, v in data.items() if k in ALLOWED_CHAT_FIELDS}
    tools_payload = sanitized.pop("tools", None)
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

    if "messages" in sanitized:
        tool_prompt = build_tool_prompt(tools_payload)
        sanitized["messages"] = simplify_messages(sanitized["messages"], tool_prompt)

    return json.dumps(sanitized).encode("utf-8")


def simplify_messages(messages, tool_prompt=None):
    """Replace OpenClaw's massive system prompt with a minimal one."""
    if not messages:
        return messages
    other_msgs = [m for m in messages if m.get("role") != "system"]
    if len(other_msgs) > 4:
        other_msgs = other_msgs[-4:]
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
    skills_block = extract_skills_block("\n\n".join(original_sys_msgs))
    if not skills_block:
        skills_block = build_skills_block_from_workspace()
    if tool_prompt:
        system_content = f"{system_content}\n\n{tool_prompt}"
    if skills_block:
        system_content = f"{system_content}\n\nAvailable skills:\n{skills_block}"
    skill_details = build_skill_details_from_workspace()
    if skill_details:
        system_content = f"{system_content}\n\n{skill_details}"
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
        params = fn.get("parameters", {})
        props = params.get("properties", {}) if isinstance(params, dict) else {}
        args = ", ".join(sorted(props.keys())) if isinstance(props, dict) else ""
        label = f"- {name}"
        if desc:
            label += f": {desc}"
        if args:
            label += f" (args: {args})"
        lines.append(label)
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


def build_skill_details_from_workspace():
    if not os.path.isdir(WORKSPACE_SKILLS_DIR):
        return ""
    sections = []
    for entry in sorted(os.listdir(WORKSPACE_SKILLS_DIR)):
        if entry not in SKILL_DETAIL_NAMES:
            continue
        skill_md = os.path.join(WORKSPACE_SKILLS_DIR, entry, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        try:
            with open(skill_md, "r", encoding="utf-8") as f:
                content = f.read().strip()
        except Exception:
            continue
        if not content:
            continue
        if len(content) > MAX_SKILL_DETAIL_CHARS:
            content = content[:MAX_SKILL_DETAIL_CHARS].rstrip() + "\n..."
        sections.append(f"## Skill: {entry}\n{content}")
    if not sections:
        return ""
    return "Skill details (use exec to run scripts as described):\n" + "\n\n".join(sections)


def parse_tool_call(content):
    if not content or not isinstance(content, str):
        return None
    raw = content.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw.replace("json", "", 1).strip()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    name = payload.get("tool") or payload.get("name") or payload.get("tool_name")
    args = payload.get("arguments") or payload.get("args") or {}
    if not name:
        return None
    if not isinstance(args, dict):
        return None
    return {"name": name, "arguments": args}


def sanitize_response(data):
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
            tool_call = parse_tool_call(content)
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


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def _proxy(self, method):
        path = self.path.rstrip("/")
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        # Fake /api/show
        if path == "/api/show" and method == "POST":
            resp_body = fake_api_show(body)
            self._send_json(200, resp_body)
            sys.stderr.write("hailo-sanitize-proxy: %s %s -> 200 (faked)\n" % (method, path))
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
            body = sanitize_chat_body(body)

        upstream_path = "/v1/chat/completions" if is_completion else self.path
        url = "%s%s" % (UPSTREAM, upstream_path)
        req = urllib.request.Request(url, data=body if body else None, method=method)
        for header in self.headers:
            lower = header.lower()
            if lower not in ("host", "content-length", "transfer-encoding"):
                req.add_header(header, self.headers[header])
        if body:
            req.add_header("Content-Length", str(len(body)))

        try:
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
            data = resp.read()

            if is_chat:
                data = sanitize_response(data)
            if is_completion:
                data = convert_chat_to_completion(data)

            if is_chat and client_wants_stream and not is_completion:
                sse_data = to_sse(data)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.send_header("Content-Length", str(len(sse_data)))
                sys.stderr.write(
                    "hailo-sanitize-proxy: %s %s -> %d SSE (%d bytes)\n"
                    % (method, path, resp.status, len(sse_data))
                )
            else:
                self._send_json(resp.status, data)
                sys.stderr.write(
                    "hailo-sanitize-proxy: %s %s -> %d (%d bytes)\n"
                    % (method, path, resp.status, len(data))
                )
            sys.stderr.flush()
        except urllib.error.HTTPError as e:
            err_data = e.read()
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
                "hailo-sanitize-proxy: %s %s -> %d ERROR\n" % (method, path, e.code)
            )
            sys.stderr.flush()
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                msg = ("Proxy error: %s" % e).encode("utf-8")
                self._send_json(502, msg)
            except BrokenPipeError:
                pass
            sys.stderr.write(
                "hailo-sanitize-proxy: %s %s -> 502 EXCEPTION: %s\n" % (method, path, e)
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
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
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
