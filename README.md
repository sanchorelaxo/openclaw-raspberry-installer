# OpenClaw Raspberry Pi 5 GenAI Kit Installer

Automated installer for local AI assistants on Raspberry Pi 5 + Hailo-10H (AI HAT+ 2), with selectable flavor: OpenClaw, PicoClaw, ZeroClaw, Nanobot, or Moltis.

## Quick navigation

- [What this repo does](#what-this-repo-does)
- [Supported flavors](#supported-flavors)
- [Target hardware and prerequisites](#target-hardware-and-prerequisites)
- [Quick start](#quick-start)
  - [Online install](#online-install-recommended)
  - [Offline install](#offline-install)
- [Installer phases](#installer-phases)
- [Service architecture and ports](#service-architecture-and-ports)
- [Configuration flags (`.env.example`)](#configuration-flags-envexample)
- [Unified chat facade](#unified-chat-facade)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [License](#license)

## What this repo does

This project installs and configures a local assistant stack on Raspberry Pi:

1. System/runtime dependencies (Node, Docker, etc.)
2. Hailo GenAI stack (`hailo-ollama`) and optional sanitizing proxy
3. Selected assistant flavor (`openclaw`, `picoclaw`, `zeroclaw`, `nanobot`, or `moltis`)
4. Optional OpenClaw-only extras (molt_tools, channel setup, RAG)
5. Validation and SSH test scripts

For the main entrypoint see [`install-openclaw-rpi5.sh`](./install-openclaw-rpi5.sh).

## Supported flavors

- **`openclaw`** (default): full OpenClaw flow including OpenClaw-specific phases.
- **`picoclaw`**: full PicoClaw install/build + local Hailo model wiring.
- **`zeroclaw`**: full ZeroClaw install/build + local Hailo model wiring.
- **`nanobot`**: Nanobot install + local Hailo OpenAI-compatible wiring.
- **`moltis`**: Moltis install + local Hailo OpenAI-compatible wiring.
- **`ironclaw`**: IronClaw install/build + local Hailo OpenAI-compatible wiring.

Set via environment:

```bash
CLAW_FLAVOR=openclaw ./install-openclaw-rpi5.sh
CLAW_FLAVOR=picoclaw ./install-openclaw-rpi5.sh
CLAW_FLAVOR=zeroclaw ./install-openclaw-rpi5.sh
CLAW_FLAVOR=nanobot ./install-openclaw-rpi5.sh
CLAW_FLAVOR=moltis ./install-openclaw-rpi5.sh
CLAW_FLAVOR=ironclaw ./install-openclaw-rpi5.sh
```

If omitted, installer prompts interactively.

All flavors can be validated through the same local Hailo endpoint path used by the unified facade and SSH flavor test harness.

## Target hardware and prerequisites

### Hardware

- Raspberry Pi 5 (8GB recommended)
- Raspberry Pi AI HAT+ 2 with Hailo-10H
- 27W USB-C power supply (recommended)
- Active cooling (recommended)

### Software

- Raspberry Pi OS Trixie (Debian 13), 64-bit
- Internet for online install (or prepare offline bundle)

### Pre-install hardware checklist

1. `sudo apt update && sudo apt full-upgrade`
2. Mount AI HAT+ 2 and PCIe ribbon cable correctly
3. Verify detection:

```bash
lspci | grep Hailo
```

See also: [Troubleshooting / Hailo not detected](#hailo-ai-hat-2-not-detected).

## Quick start

### Online install (recommended)

```bash
git clone https://github.com/sanchorelaxo/openclaw-raspberry-installer.git
cd openclaw-raspberry-installer
./install-openclaw-rpi5.sh
```

### Offline install

1) Prepare bundle on a networked machine:

```bash
git clone https://github.com/sanchorelaxo/openclaw-raspberry-installer.git
cd openclaw-raspberry-installer
./install-openclaw-rpi5.sh --prepare-offline
```

2) Copy folder to Pi (USB or SCP).

3) Run on Pi:

```bash
cd ~/openclaw-raspberry-installer
./install-openclaw-rpi5.sh --offline
```

## Installer phases

See source for exact behavior: [`install-openclaw-rpi5.sh`](./install-openclaw-rpi5.sh).

### Common phases

- **Phase 1**: system preparation (packages, Node, Docker)
- **Phase 2**: Hailo setup + `hailo-ollama` + optional `hailo-sanitize-proxy`
- **Phase 3**: selected flavor install (`openclaw` / `picoclaw` / `zeroclaw` / `nanobot` / `moltis`)
- **Phase 9**: verification

### OpenClaw-only phases

These run only when `CLAW_FLAVOR=openclaw`:

- Phase 4: deploy assistant config
- Phase 5: deploy `molt_tools`
- Phase 6: proactive behavior prompts
- Phase 7: channel configuration
- Phase 8: optional RAG setup

## Service architecture and ports

### Core local model path

- `hailo-ollama` on `127.0.0.1:8000`
- optional `hailo-sanitize-proxy` on `127.0.0.1:8081`

### Why proxy is often required

For OpenClaw-like traffic, the proxy normalizes incompatible behavior (e.g. `/api/show`, stream adaptation, payload sanitization). Keep enabled unless explicitly testing direct mode.

Feature flag:

```bash
# Recommended
USE_SANITIZER_PROXY_ON_OLLAMA=true ./install-openclaw-rpi5.sh

# Direct hailo-ollama path (advanced/testing)
USE_SANITIZER_PROXY_ON_OLLAMA=false ./install-openclaw-rpi5.sh
```

## Configuration flags (`.env.example`)

See [`./.env.example`](./.env.example) for complete examples.

Key flags:

- `CLAW_FLAVOR` (`openclaw|picoclaw|zeroclaw|nanobot|moltis`)
- `USE_SANITIZER_PROXY_ON_OLLAMA`
- `USE_OPENCLAW_TOOLS` (OpenClaw-specific)
- `HAILO_MODEL`
- Proxy CORS/security knobs (`HAILO_PROXY_*`)

## Unified chat facade

Files:

- [`templates/unified-chat-facade.html`](./templates/unified-chat-facade.html)
- [`templates/UNIFIED_CHAT_FACADE.md`](./templates/UNIFIED_CHAT_FACADE.md)
- `templates/unified-chat-runtime.json` (generated by installer)

### Behavior

- Facade loads generated runtime profile and snaps to selected flavor defaults.
- Conditional modes can appear depending on installed flavor/runtime profile.
- For browser calls to `:8081`, proxy provides CORS handling (restricted to localhost origins by default).

## Testing

### OpenClaw regression suite

```bash
bash scripts/test_tools_over_ssh.sh
```

### Adaptive cross-flavor/facade/proxy checks

```bash
SSH_HOST=raspberrypi SSH_USER=sanchobot scripts/test_claw_flavors_over_ssh.sh

# Force matrix run for all flavors by rewriting runtime profile per flavor
RUN_ALL_FLAVORS=true SSH_HOST=raspberrypi SSH_USER=sanchobot scripts/test_claw_flavors_over_ssh.sh
```

This validates:

- flavor/runtime profile alignment
- facade runtime-profile integration
- facade intermediary HTTP-chat path (`runtime profile -> facade mode -> proxy -> hailo-ollama`)
- direct-vs-proxy compatibility matrix for Hailo endpoints
- proxy OpenAI model discovery compatibility (`/v1/models`)
- exhaustive flavor matrix via `RUN_ALL_FLAVORS=true` (`picoclaw`, `zeroclaw`, `nanobot`, `moltis`, `ironclaw`, `openclaw`)
- per-flavor simple-query latency capture with end-of-run comparison table (`Query #1`, `Query #2`, `Total`, in seconds)

## Troubleshooting

### Hailo AI HAT+ 2 not detected

```bash
lspci | grep Hailo
```

If missing:

1. Re-seat PCIe ribbon/cable
2. Confirm power delivery (27W recommended)
3. Update firmware and reboot

### `hailo-ollama` service not running

```bash
sudo systemctl status hailo-ollama
sudo systemctl restart hailo-ollama
sudo journalctl -u hailo-ollama -f
curl http://localhost:8000/api/version
```

### OpenClaw cannot reach model provider

```bash
sudo systemctl status hailo-ollama hailo-sanitize-proxy
curl http://localhost:8000/api/tags
curl http://localhost:8081/api/tags
grep baseUrl ~/.openclaw/openclaw.json
```

Expected (proxy mode): `http://127.0.0.1:8081/v1`

### Proxy issues

```bash
sudo journalctl -u hailo-sanitize-proxy -f
sudo systemctl restart hailo-sanitize-proxy
```

### Node / Docker quick fixes

```bash
sudo n stable && hash -r && node -v
sudo usermod -aG docker $USER && newgrp docker
```

## Project layout

```text
openclaw-raspberry-installer/
├── install-openclaw-rpi5.sh
├── scripts/
│   ├── test_tools_over_ssh.sh
│   └── test_claw_flavors_over_ssh.sh
├── templates/
│   ├── unified-chat-facade.html
│   ├── UNIFIED_CHAT_FACADE.md
│   └── (generated) unified-chat-runtime.json
├── molt_tools/
├── rag/
└── .env.example
```

## License

MIT
