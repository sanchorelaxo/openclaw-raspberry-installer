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
import sys
import time
import urllib.request
import urllib.error

LISTEN_PORT = 8081
UPSTREAM = "http://127.0.0.1:8000"
UPSTREAM_TIMEOUT = 300  # seconds — generation is slow (~8 tok/s)

MINIMAL_SYSTEM_PROMPT = (
    "You are a helpful personal assistant. "
    "Answer the user's questions concisely and helpfully. "
    "If you don't know something, say so."
)

ALLOWED_CHAT_FIELDS = {
    "model", "messages", "temperature", "top_p", "n", "stream",
    "max_tokens", "max_completion_tokens", "presence_penalty",
    "frequency_penalty", "seed",
}
ALLOWED_MESSAGE_FIELDS = {"role", "content"}


def sanitize_chat_body(body_bytes):
    """Strip unsupported fields from /v1/chat/completions request."""
    try:
        data = json.loads(body_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body_bytes
    if not isinstance(data, dict):
        return body_bytes

    sanitized = {k: v for k, v in data.items() if k in ALLOWED_CHAT_FIELDS}

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
        sanitized["messages"] = simplify_messages(sanitized["messages"])

    return json.dumps(sanitized).encode("utf-8")


def simplify_messages(messages):
    """Replace OpenClaw's massive system prompt with a minimal one."""
    if not messages:
        return messages
    other_msgs = [m for m in messages if m.get("role") != "system"]
    if len(other_msgs) > 4:
        other_msgs = other_msgs[-4:]
    original_sys_len = sum(
        len(m.get("content", "")) for m in messages if m.get("role") == "system"
    )
    if original_sys_len > len(MINIMAL_SYSTEM_PROMPT):
        sys.stderr.write(
            "hailo-sanitize-proxy: replaced system prompt (%d -> %d chars)\n"
            % (original_sys_len, len(MINIMAL_SYSTEM_PROMPT))
        )
        sys.stderr.flush()
    return [{"role": "system", "content": MINIMAL_SYSTEM_PROMPT}] + other_msgs


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
            total_chars += len(content)
            choice["message"] = {
                "role": msg.get("role", "assistant"),
                "content": content,
                "refusal": None,
            }

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
    if resp.get("choices"):
        content = resp["choices"][0].get("message", {}).get("content", "")

    parts = []
    # role chunk
    parts.append("data: %s\n\n" % json.dumps({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": model, "system_fingerprint": fp,
        "choices": [{"index": 0, "delta": {"role": "assistant", "content": "", "refusal": None},
                     "logprobs": None, "finish_reason": None}],
    }))
    # content chunk
    if content:
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
        original_body = body
        if is_chat and body:
            try:
                client_wants_stream = json.loads(body).get("stream", False)
            except Exception:
                pass
            body = sanitize_chat_body(body)

        url = "%s%s" % (UPSTREAM, self.path)
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

            if is_chat and client_wants_stream:
                sse_data = to_sse(data)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.send_header("Content-Length", str(len(sse_data)))
                self.end_headers()
                self.wfile.write(sse_data)
                self.wfile.flush()
                sys.stderr.write(
                    "hailo-sanitize-proxy: %s %s -> 200 SSE (%d bytes)\n"
                    % (method, path, len(sse_data))
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
