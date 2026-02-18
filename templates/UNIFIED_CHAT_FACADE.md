# Unified Chat Facade (OpenClaw Dashboard + OpenClaw WebChat + Ollama)

This facade gives you one chat composer with a mode toggle:

- OpenClaw Dashboard session
- OpenClaw WebChat session
- Ollama/Hailo OpenAI-compatible endpoint

UI file: `templates/unified-chat-facade.html`

## 1) Run OpenClaw and model services

```bash
openclaw gateway --port 18789
```

```bash
# if using the local Hailo chain
sudo systemctl status hailo-ollama hailo-sanitize-proxy
```

## 2) Serve the facade HTML

Installer now provisions a systemd service for the facade server:

```bash
sudo systemctl status unified-chat-facade
sudo journalctl -u unified-chat-facade -f
```

Open:

`http://127.0.0.1:8787/templates/unified-chat-facade.html`

Manual fallback (from repo root):

```bash
python3 -m http.server 8787
```

## 3) Allow this origin in OpenClaw (if needed)

OpenClaw can reject non-same-origin websocket clients.
If needed, add your origin to `gateway.controlUi.allowedOrigins` in `~/.openclaw/openclaw.json`:

```json5
{
  gateway: {
    controlUi: {
      allowedOrigins: ["http://127.0.0.1:8787"]
    }
  }
}
```

Then restart (or let hot reload apply, depending on your gateway settings).

## 4) Facade settings

In the left panel, configure:

- **Gateway WS URL**: `ws://127.0.0.1:18789`
- **Dashboard session key** and **WebChat session key** (separate conversations)
- **Ollama URL**: e.g. `http://127.0.0.1:8081/v1/chat/completions`
- **Ollama model**: e.g. `qwen2.5:1.5b`

## Dynamic token support

Each backend supports either:

1. Static token in UI
2. Dynamic token URL (fetched on connect/send)

Expected dynamic token endpoint response:

```json
{ "token": "..." }
```

or

```json
{ "value": "..." }
```

or a raw JSON string token:

```json
"..."
```

### Example token endpoint (minimal Flask)

```python
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.get("/openclaw-token")
def openclaw_token():
    return jsonify({"token": os.environ.get("OPENCLAW_GATEWAY_TOKEN", "")})

@app.get("/ollama-token")
def ollama_token():
    return jsonify({"token": os.environ.get("OLLAMA_TOKEN", "")})

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8899)
```

Use these URLs in the facade:

- `http://127.0.0.1:8899/openclaw-token`
- `http://127.0.0.1:8899/ollama-token`

## Notes

- OpenClaw Dashboard + OpenClaw WebChat are both gateway chat surfaces; the facade separates them by `sessionKey`.
- Ollama mode is direct chat endpoint usage (not embedding the full Open WebUI app chrome).
- Settings are persisted in browser `localStorage` under `unifiedChatFacade.settings.v1`.

## Troubleshooting

### `OpenClaw history load failed: missing scope: operator.read`

This means the gateway accepted the socket but the client did not present authorized operator scopes.

Use the latest `unified-chat-facade.html` (it now sends signed device identity + `operator.read/operator.write` scopes), then:

1. Hard refresh the page (`Ctrl+Shift+R`)
2. Enter Gateway token
3. Click **Save settings**

If a new device needs approval, run on the gateway host:

```bash
/home/sanchobot/.npm-global/bin/openclaw devices list
/home/sanchobot/.npm-global/bin/openclaw devices approve <requestId>
```

### `origin not allowed`

Add your facade origin to `gateway.controlUi.allowedOrigins` and restart gateway.
