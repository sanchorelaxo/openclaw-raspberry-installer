# OpenClaw Raspberry Pi 5 GenAI Kit Installer

Automated installer for OpenClaw on the CanaKit Raspberry Pi 5 8GB Dual Cooling GenAI Kit with Hailo 10H AI accelerator.

## Target Hardware

- **CanaKit Raspberry Pi 5 8GB Dual Cooling GenAI Kit (256GB Flash Edition)**
  - Raspberry Pi 5 with 8GB RAM
  - AI HAT+ 2 with Hailo 10H neural network accelerator (8GB onboard RAM)
  - 256GB Raspberry Pi Flash Drive
  - Pre-loaded with Raspberry Pi OS Trixie (Debian 13)

## What Gets Installed

1. **Node.js 22+** via `n` version manager (Trixie-compatible)
2. **Docker** with Trixie-specific installation method
3. **Hailo GenAI stack** with user-selected model (fully local, no cloud auth)
4. **OpenClaw** personal AI assistant with systemd daemon
5. **Custom executive assistant configuration** from `clawdbot-assistant.md`
6. **molt_tools skill** for Moltbook integration
7. **Channel options**: WebChat (default) or Matrix (self-hosted Synapse)
8. **RAG (optional)**: Local document search with nomic-embed-text embeddings

## Quick Start

### Online Installation (requires internet on Pi)
```bash
git clone https://github.com/yourusername/openclaw-raspberry-installer.git
cd openclaw-raspberry-installer
./install-openclaw-rpi5.sh
```

### Offline Installation (no internet on Pi)

**Step 1: Prepare offline bundle (on machine with internet)**
```bash
git clone https://github.com/yourusername/openclaw-raspberry-installer.git
cd openclaw-raspberry-installer
./install-openclaw-rpi5.sh --prepare-offline
```

This downloads:
- Node.js 22 ARM64 binary (~25MB)
- Docker .deb packages for Trixie ARM64 (~100MB)
- OpenClaw npm package (~5MB)
- (Manual) Hailo models if available

**Step 2: Copy to Pi**
```bash
# Via USB drive
cp -r openclaw-raspberry-installer /media/usb/

# OR via SCP (if Pi has temporary network)
scp -r openclaw-raspberry-installer pi@PI_IP:~/
```

**Step 3: Run offline install on Pi**
```bash
cd ~/openclaw-raspberry-installer
./install-openclaw-rpi5.sh --offline
```

## Prerequisites

- Raspberry Pi 5 with Raspberry Pi OS Trixie
- Hailo AI HAT+ 2 installed
- HailoRT installed from [Hailo Developer Zone](https://hailo.ai/developer-zone/)
- Internet connection for online install (or use `--offline` mode)

## Installation Phases

### Phase 1: System Preparation
- Updates system packages
- Installs Node.js 22+ via `n` version manager
- Installs Docker (Trixie-specific method)

### Phase 2: Hailo GenAI Stack
- Prompts user to select from available models:
  - `qwen2:1.5b` - General purpose (default)
  - `qwen2.5:1.5b` - Improved general purpose
  - `qwen2.5-coder:1.5b` - Optimized for coding
  - `llama3.2:1b` - Meta's compact model
  - `deepseek_r1:1.5b` - Reasoning-focused model
- Configures hailo-ollama server
- Pulls selected model

### Phase 3: OpenClaw Installation
- Installs OpenClaw CLI
- Runs onboarding wizard
- Configures Hailo as primary model provider (no cloud auth needed)

### Phase 4: Deploy Custom Configuration
- Deploys `clawdbot-assistant.md` as `CLAUDE.md` and `AGENTS.md`
- Interactive customization of "What I Care About" section:
  - Deep work hours
  - Priority contacts
  - Priority projects
  - Ignore list

### Phase 5: Deploy molt_tools Skill
- Copies molt_tools to OpenClaw workspace
- Creates SKILL.md documentation
- Prompts for Moltbook API key

### Phase 6: Configure Proactive Behaviors
Interactive prompts to enable/disable:
- Auto-respond to routine emails
- Auto-decline calendar invites
- Auto-organize Downloads folder
- Monitor stock/crypto prices

### Phase 7: Channel Configuration
Choose between:
- **WebChat** (default): Zero setup, available at `http://localhost:18789/`
- **Matrix**: Full Synapse homeserver setup with Nginx + SSL

### Phase 8: RAG Setup (Optional)
- Prompts to enable RAG (Retrieval-Augmented Generation)
- Installs Python dependencies (llama-index, chromadb, pypdf)
- Pulls `nomic-embed-text` embedding model
- Prompts for document directory to copy for local search
- Creates convenience script for querying documents

### Phase 9: Verification
- Runs `openclaw doctor`
- Runs `openclaw status --all`
- Runs `openclaw health`

## First Boot Task

After installation, OpenClaw's first task is to:
1. Check Moltbook connection via `check_moltbook.py`
2. Post "i've been boxed into a Raspberry Pi !" to Moltbook
3. Report success/failure

## File Structure

```
openclaw-raspberry-installer/
├── install-openclaw-rpi5.sh    # Main installer script
├── clawdbot-assistant.md       # Executive assistant configuration
├── molt_tools/                 # Moltbook integration skill
│   ├── check_moltbook.py
│   ├── post_to_moltbook.py
│   └── SKILL.md
├── rag/                        # RAG (document search) components
│   ├── requirements.txt        # Python dependencies
│   └── test_rag.py             # RAG query script
├── templates/
│   ├── HEARTBEAT.md            # 4-hour heartbeat checklist
│   └── BOOTSTRAP.md            # First boot task
├── offline_bundle/             # Created by --prepare-offline
│   ├── node-v22.x-linux-arm64.tar.xz
│   ├── docker_debs/
│   ├── openclaw-*.tgz
│   ├── hailo_models/           # Including nomic-embed-text if selected
│   └── manifest.json
└── README.md
```

## Configuration Files (after install)

- `~/.openclaw/openclaw.json` - OpenClaw configuration
- `~/.openclaw/workspace/AGENTS.md` - Agent instructions
- `~/.openclaw/workspace/CLAUDE.md` - Agent instructions (alias)
- `~/.openclaw/workspace/HEARTBEAT.md` - Heartbeat checklist
- `~/.config/moltbook/credentials.json` - Moltbook API key
- `~/.openclaw/rag/` - RAG installation (if enabled)
- `~/.openclaw/rag_documents/` - Documents for RAG search
- `~/.openclaw/rag_query.sh` - Convenience script for RAG queries

## Usage After Installation

```bash
# Start OpenClaw gateway
openclaw gateway --port 18789 --verbose

# Open dashboard
openclaw dashboard

# Check status
openclaw status --all

# Run diagnostics
openclaw doctor

# RAG queries (if enabled)
~/.openclaw/rag_query.sh                    # Run test queries
~/.openclaw/rag_query.sh --interactive      # Interactive mode
```

## Troubleshooting

### Hailo not detected
Ensure HailoRT is installed:
```bash
# Download from https://hailo.ai/developer-zone/
sudo dpkg -i hailo_gen_ai_model_zoo_<ver>_arm64.deb
```

### Node.js version issues
```bash
sudo n stable
hash -r
node -v  # Should show v22.x
```

### Docker permission denied
```bash
sudo usermod -aG docker $USER
newgrp docker
```

### OpenClaw not responding
```bash
openclaw doctor
openclaw gateway status
```

## License

MIT
