#!/bin/bash
set -e

#===============================================================================
# OpenClaw Installer for Raspberry Pi 5 GenAI Kit
# Target: CanaKit Raspberry Pi 5 8GB with Hailo 10H AI HAT+ 2
# OS: Raspberry Pi OS Trixie (Debian 13)
#
# Usage:
#   ./install-openclaw-rpi5.sh              # Online install (requires internet)
#   ./install-openclaw-rpi5.sh --offline    # Offline install (uses bundled deps)
#   ./install-openclaw-rpi5.sh --prepare-offline  # Download deps for offline use
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_WORKSPACE="$HOME/.openclaw/workspace"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
MOLTBOOK_CONFIG_DIR="$HOME/.config/moltbook"
OFFLINE_DIR="$SCRIPT_DIR/offline_bundle"

# Parse arguments
OFFLINE_MODE=false
PREPARE_OFFLINE=false
USE_SANITIZER_PROXY_ON_OLLAMA=${USE_SANITIZER_PROXY_ON_OLLAMA:-true}
USE_OPENCLAW_TOOLS=${USE_OPENCLAW_TOOLS:-true}
CLAW_FLAVOR=${CLAW_FLAVOR:-openclaw}
UNIFIED_FACADE_HTTP_PORT=${UNIFIED_FACADE_HTTP_PORT:-8787}

while [[ $# -gt 0 ]]; do
    case $1 in
        --offline)
            OFFLINE_MODE=true
            shift
            ;;
        --prepare-offline)
            PREPARE_OFFLINE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--offline | --prepare-offline]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_step() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi
    
    [[ "$response" =~ ^[Yy] ]]
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local response
    
    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        read -p "$prompt: " response
        echo "$response"
    fi
}

normalize_claw_flavor() {
    local raw="${1:-openclaw}"
    raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        openclaw|picoclaw|zeroclaw|nanobot|moltis|ironclaw)
            printf '%s' "$raw"
            ;;
        *)
            printf '%s' "openclaw"
            ;;
    esac
}

prompt_claw_flavor() {
    CLAW_FLAVOR=$(normalize_claw_flavor "$CLAW_FLAVOR")
    echo ""
    echo "Select assistant flavor to install:"
    echo "  1) OpenClaw (TypeScript)"
    echo "  2) PicoClaw (Go)"
    echo "  3) ZeroClaw (Rust)"
    echo "  4) Nanobot (Python)"
    echo "  5) Moltis (Rust)"
    echo "  6) IronClaw (Rust)"
    echo ""
    local default_choice="1"
    case "$CLAW_FLAVOR" in
        picoclaw) default_choice="2" ;;
        zeroclaw) default_choice="3" ;;
        nanobot) default_choice="4" ;;
        moltis) default_choice="5" ;;
        ironclaw) default_choice="6" ;;
    esac

    local choice
    choice=$(prompt_input "Choice" "$default_choice")
    case "$choice" in
        2) CLAW_FLAVOR="picoclaw" ;;
        3) CLAW_FLAVOR="zeroclaw" ;;
        4) CLAW_FLAVOR="nanobot" ;;
        5) CLAW_FLAVOR="moltis" ;;
        6) CLAW_FLAVOR="ironclaw" ;;
        *) CLAW_FLAVOR="openclaw" ;;
    esac
    print_step "Selected assistant flavor: $CLAW_FLAVOR"
}

get_hailo_openai_base_url() {
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" == "true" ]]; then
        printf '%s' "http://127.0.0.1:8081/v1"
    else
        printf '%s' "http://127.0.0.1:8000/v1"
    fi
}

get_hailo_chat_completions_url() {
    printf '%s/chat/completions' "$(get_hailo_openai_base_url)"
}

write_unified_facade_runtime_profile() {
    local facade_runtime_path="$SCRIPT_DIR/templates/unified-chat-runtime.json"
    local ollama_chat_url
    ollama_chat_url=$(get_hailo_chat_completions_url)
    local active_mode="ollama"
    local extra_mode_json="[]"

    if [[ "$CLAW_FLAVOR" == "picoclaw" ]]; then
        active_mode="picoclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "picoclaw-local",
    "title": "PicoClaw Local",
    "subtitle": "PicoClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "zeroclaw" ]]; then
        active_mode="zeroclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "zeroclaw-local",
    "title": "ZeroClaw Local",
    "subtitle": "ZeroClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "nanobot" ]]; then
        active_mode="nanobot-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "nanobot-local",
    "title": "Nanobot Local",
    "subtitle": "Nanobot + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "moltis" ]]; then
        active_mode="moltis-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "moltis-local",
    "title": "Moltis Local",
    "subtitle": "Moltis + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "ironclaw" ]]; then
        active_mode="ironclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "ironclaw-local",
    "title": "IronClaw Local",
    "subtitle": "IronClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    fi

    cat > "$facade_runtime_path" <<EOF
{
  "schemaVersion": 1,
  "flavor": "$CLAW_FLAVOR",
  "gatewayUrl": "ws://127.0.0.1:18789",
  "ollamaUrl": "$ollama_chat_url",
  "ollamaModel": "$HAILO_MODEL",
  "activeMode": "$active_mode",
  "extraModes": $extra_mode_json
}
EOF
    print_step "Wrote unified facade runtime profile: $facade_runtime_path"
}

install_unified_facade_http_service() {
    local facade_server_src="$SCRIPT_DIR/scripts/unified-chat-facade-httpd.py"
    local facade_server_dst="/usr/local/bin/unified-chat-facade-httpd.py"

    if [[ ! -f "$facade_server_src" ]]; then
        print_warn "Unified facade server script not found: $facade_server_src"
        return 0
    fi

    print_step "Installing unified facade HTTP server systemd service (debug logs enabled)..."
    sudo cp "$facade_server_src" "$facade_server_dst"
    sudo chmod +x "$facade_server_dst"

    sudo tee /etc/systemd/system/unified-chat-facade.service > /dev/null <<EOF
[Unit]
Description=Unified Chat Facade HTTP Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$SCRIPT_DIR
Environment=PYTHONUNBUFFERED=1
Environment=UNIFIED_CHAT_FACADE_LOG_LEVEL=DEBUG
ExecStart=/usr/bin/python3 /usr/local/bin/unified-chat-facade-httpd.py --bind 127.0.0.1 --port $UNIFIED_FACADE_HTTP_PORT --directory $SCRIPT_DIR --log-level DEBUG
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=unified-chat-facade

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable unified-chat-facade.service
    sudo systemctl restart unified-chat-facade.service

    sleep 1
    if sudo systemctl is-active --quiet unified-chat-facade.service; then
        print_step "Unified facade HTTP server running on http://127.0.0.1:$UNIFIED_FACADE_HTTP_PORT"
    else
        print_warn "Unified facade HTTP server failed to start — check: journalctl -u unified-chat-facade -n 100"
    fi
}

#===============================================================================
# Homebrew (Linuxbrew) - required by some OpenClaw tooling on Raspberry Pi
#===============================================================================

ensure_homebrew() {
    if command -v brew &> /dev/null; then
        return 0
    fi

    print_warn "Homebrew (brew) not found"

    if [[ "$OFFLINE_MODE" == "true" ]]; then
        print_warn "Offline mode enabled - skipping Homebrew install"
        print_warn "If OpenClaw fails due to missing brew, re-run with internet access"
        return 0
    fi

    print_step "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ -d "$HOME/.linuxbrew" ]]; then
        eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
    elif [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi

    if command -v brew &> /dev/null; then
        if ! grep -q 'brew shellenv' "$HOME/.bashrc" 2>/dev/null; then
            echo 'eval "$("$(brew --prefix)"/bin/brew shellenv)"' >> "$HOME/.bashrc"
        fi
        brew -h &> /dev/null || true
        print_step "Homebrew installed"
    else
        print_warn "Homebrew install did not add brew to PATH (may require re-login)"
    fi
}

#===============================================================================
# Build HailoRT from source (when apt version is incompatible)
#===============================================================================

build_hailort_from_source() {
    local HAILORT_VERSION="${1:-v5.1.1}"
    
    print_header "Building HailoRT $HAILORT_VERSION from source"
    print_warn "This is required because hailo-ollama needs a newer libhailort version."
    echo ""
    
    # Install build dependencies
    print_step "Installing build dependencies..."
    sudo apt update
    sudo apt install -y build-essential cmake pkg-config \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        linux-headers-$(uname -r) python3-pip python3-venv git
    
    # Clone HailoRT
    print_step "Cloning HailoRT repository..."
    local BUILD_DIR="$HOME/.openclaw/hailort-build"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    if [[ -d "hailort" ]]; then
        cd hailort
        git fetch --tags
    else
        git clone https://github.com/hailo-ai/hailort.git
        cd hailort
    fi
    
    git checkout "$HAILORT_VERSION"
    
    # Build and install
    print_step "Building HailoRT (this may take several minutes)..."
    cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release
    sudo cmake --build build --config release --target install
    
    # Update library cache
    sudo ldconfig
    
    # Verify
    if [[ -f /usr/local/lib/libhailort.so ]] || [[ -f /usr/lib/libhailort.so.5.1.1 ]]; then
        print_step "HailoRT $HAILORT_VERSION built and installed successfully"
        return 0
    else
        print_error "HailoRT build may have failed - library not found"
        return 1
    fi
}

#===============================================================================
# Prepare Offline Bundle (run on machine with internet)
#===============================================================================

prepare_offline_bundle() {
    print_header "Preparing Offline Bundle"
    
    mkdir -p "$OFFLINE_DIR"
    cd "$OFFLINE_DIR"
    
    # Node.js 22 ARM64 binary
    print_step "Downloading Node.js 22 ARM64..."
    NODE_VERSION="22.11.0"
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz" -o node-v${NODE_VERSION}-linux-arm64.tar.xz
    
    # Docker packages for Debian Trixie ARM64
    print_step "Downloading Docker packages..."
    mkdir -p docker_debs
    cd docker_debs
    
    # Get Docker GPG key
    curl -fsSL https://download.docker.com/linux/debian/gpg -o docker.gpg
    
    # Download Docker .deb packages (latest versions for Trixie ARM64)
    BASE_URL="https://download.docker.com/linux/debian/dists/trixie/pool/stable/arm64"
    
    print_step "Downloading containerd.io..."
    curl -fsSL "${BASE_URL}/containerd.io_2.2.1-1~debian.13~trixie_arm64.deb" -o containerd.io_arm64.deb || print_warn "containerd download failed"
    
    print_step "Downloading docker-ce-cli..."
    curl -fsSL "${BASE_URL}/docker-ce-cli_29.2.1-1~debian.13~trixie_arm64.deb" -o docker-ce-cli_arm64.deb || print_warn "docker-ce-cli download failed"
    
    print_step "Downloading docker-ce..."
    curl -fsSL "${BASE_URL}/docker-ce_29.2.1-1~debian.13~trixie_arm64.deb" -o docker-ce_arm64.deb || print_warn "docker-ce download failed"
    
    print_step "Downloading docker-buildx-plugin..."
    curl -fsSL "${BASE_URL}/docker-buildx-plugin_0.31.1-1~debian.13~trixie_arm64.deb" -o docker-buildx-plugin_arm64.deb || print_warn "buildx download failed"
    
    print_step "Downloading docker-compose-plugin..."
    curl -fsSL "${BASE_URL}/docker-compose-plugin_5.0.2-1~debian.13~trixie_arm64.deb" -o docker-compose-plugin_arm64.deb || print_warn "compose download failed"
    
    cd "$OFFLINE_DIR"
    
    # OpenClaw npm package
    print_step "Downloading OpenClaw npm package..."
    npm pack openclaw@latest
    
    # Hailo software packages
    print_header "Hailo Software Packages"
    echo ""
    echo "For offline installation, you need to manually download Hailo packages."
    echo ""
    echo "Required packages:"
    echo "  1. hailo-all (from Raspberry Pi apt repository)"
    echo "  2. hailo_gen_ai_model_zoo (from Hailo Developer Zone)"
    echo ""
    echo "Steps to prepare Hailo packages:"
    echo "  1. On a Pi with internet, run: apt download hailo-all"
    echo "  2. Download GenAI Model Zoo from: https://hailo.ai/developer-zone/software-downloads/"
    echo "  3. Copy .deb files to: $OFFLINE_DIR/hailo_debs/"
    echo ""
    
    mkdir -p hailo_debs
    
    # Try to download hailo-all if apt is available
    if command -v apt &> /dev/null; then
        print_step "Attempting to download hailo-all package..."
        cd hailo_debs
        apt download hailo-all 2>/dev/null || print_warn "hailo-all not available in apt (may need to run on Pi)"
        apt download dkms 2>/dev/null || true
        cd "$OFFLINE_DIR"
    fi
    
    # Hailo model selection and download
    print_header "Select Hailo Model for Offline Bundle"
    
    echo "Available Hailo-optimized models:"
    echo ""
    echo "  1) qwen2:1.5b        - General purpose (recommended)"
    echo "  2) qwen2.5:1.5b      - Improved general purpose"
    echo "  3) qwen2.5-coder:1.5b - Optimized for coding"
    echo "  4) llama3.2:1b       - Meta's compact model"
    echo "  5) deepseek_r1:1.5b  - Reasoning-focused model"
    echo "  6) All models        - Download all available models"
    echo "  7) Skip              - Don't download any models"
    echo ""
    
    MODEL_CHOICE=$(prompt_input "Select model to bundle" "1")
    
    mkdir -p hailo_models
    
    case $MODEL_CHOICE in
        1) MODELS_TO_DOWNLOAD="qwen2:1.5b" ;;
        2) MODELS_TO_DOWNLOAD="qwen2.5:1.5b" ;;
        3) MODELS_TO_DOWNLOAD="qwen2.5-coder:1.5b" ;;
        4) MODELS_TO_DOWNLOAD="llama3.2:1b" ;;
        5) MODELS_TO_DOWNLOAD="deepseek_r1:1.5b" ;;
        6) MODELS_TO_DOWNLOAD="qwen2:1.5b qwen2.5:1.5b qwen2.5-coder:1.5b llama3.2:1b deepseek_r1:1.5b" ;;
        7) MODELS_TO_DOWNLOAD="" ;;
        *) MODELS_TO_DOWNLOAD="qwen2:1.5b" ;;
    esac
    
    # Ask about RAG embedding model
    echo ""
    if prompt_yes_no "Include nomic-embed-text for RAG (document search)?"; then
        MODELS_TO_DOWNLOAD="$MODELS_TO_DOWNLOAD nomic-embed-text"
    fi
    
    if [[ -n "$MODELS_TO_DOWNLOAD" ]]; then
        if command -v hailo-ollama &> /dev/null; then
            print_step "Starting hailo-ollama to download models..."
            hailo-ollama &
            HAILO_PID=$!
            sleep 3
            
            for model in $MODELS_TO_DOWNLOAD; do
                print_step "Downloading $model..."
                curl -s http://localhost:8000/api/pull -H 'Content-Type: application/json' -d "{\"model\":\"$model\",\"stream\":true}" || {
                    print_warn "Failed to download $model"
                }
            done
            
            # Copy downloaded models to offline bundle
            print_step "Copying models to offline bundle..."
            if [[ -d ~/.hailo-ollama/models ]]; then
                cp -r ~/.hailo-ollama/models/* "$OFFLINE_DIR/hailo_models/" 2>/dev/null || true
            fi
            
            # Stop hailo-ollama
            kill $HAILO_PID 2>/dev/null || true
        else
            print_warn "hailo-ollama not found on this machine."
            echo ""
            echo "To download Hailo models, you need a machine with hailo-ollama installed."
            echo "After installing hailo-ollama, run:"
            echo ""
            for model in $MODELS_TO_DOWNLOAD; do
                echo "  hailo-ollama pull $model"
            done
            echo ""
            echo "Then copy ~/.hailo-ollama/models/* to $OFFLINE_DIR/hailo_models/"
        fi
    else
        print_step "Skipping model download"
    fi
    
    # Create manifest
    cat > manifest.json << EOF
{
  "created": "$(date -Iseconds)",
  "node_version": "${NODE_VERSION}",
  "arch": "arm64",
  "os": "debian-trixie",
  "models_bundled": "$MODELS_TO_DOWNLOAD",
  "contents": [
    "node-v${NODE_VERSION}-linux-arm64.tar.xz",
    "docker_debs/",
    "openclaw-*.tgz",
    "hailo_models/"
  ]
}
EOF
    
    print_step "Offline bundle created at: $OFFLINE_DIR"
    echo ""
    echo "Bundle contents:"
    ls -la "$OFFLINE_DIR"
    echo ""
    if [[ -d "$OFFLINE_DIR/hailo_models" ]]; then
        echo "Hailo models:"
        ls -la "$OFFLINE_DIR/hailo_models/" 2>/dev/null || echo "  (none)"
    fi
    echo ""
    print_warn "Copy the entire 'offline_bundle' directory to the Pi along with the installer."
}

#===============================================================================
# Phase 1: System Preparation
#===============================================================================

phase1_system_prep() {
    print_header "Phase 1: System Preparation (Raspberry Pi OS Trixie)"
    
    # Check if running on Raspberry Pi OS Trixie
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$VERSION_CODENAME" != "trixie" ]]; then
            print_warn "Expected Raspberry Pi OS Trixie, found: $VERSION_CODENAME"
            if ! prompt_yes_no "Continue anyway?"; then
                exit 1
            fi
        else
            print_step "Detected Raspberry Pi OS Trixie"
        fi
    fi
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        phase1_system_prep_offline
    else
        phase1_system_prep_online
    fi
}

phase1_system_prep_online() {
    # Update system
    print_step "Updating system packages..."
    sudo apt update && sudo apt full-upgrade -y
    
    # Install Node.js 22+ via n version manager
    print_step "Installing Node.js 22+ (via n version manager)..."
    sudo apt install -y nodejs npm
    sudo npm install -g n
    sudo n stable
    hash -r
    
    NODE_VERSION=$(node -v 2>/dev/null || echo "not installed")
    print_step "Node.js version: $NODE_VERSION"
    
    # Install Docker (Trixie-specific method)
    if ! command -v docker &> /dev/null; then
        print_step "Installing Docker (Trixie-specific method)..."
        sudo apt install -y ca-certificates curl gnupg
        
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable docker && sudo systemctl start docker
        sudo usermod -aG docker $USER
        
        print_step "Docker installed successfully"
    else
        print_step "Docker already installed"
    fi
}

phase1_system_prep_offline() {
    print_step "Installing from offline bundle..."
    
    if [[ ! -d "$OFFLINE_DIR" ]]; then
        print_error "Offline bundle not found at $OFFLINE_DIR"
        print_error "Run './install-openclaw-rpi5.sh --prepare-offline' on a machine with internet first."
        exit 1
    fi
    
    # Install Node.js from bundled tarball
    print_step "Installing Node.js 22 from offline bundle..."
    NODE_TARBALL=$(ls "$OFFLINE_DIR"/node-v*-linux-arm64.tar.xz 2>/dev/null | head -1)
    if [[ -f "$NODE_TARBALL" ]]; then
        sudo tar -xJf "$NODE_TARBALL" -C /usr/local --strip-components=1
        hash -r
        NODE_VERSION=$(node -v 2>/dev/null || echo "not installed")
        print_step "Node.js version: $NODE_VERSION"
    else
        print_error "Node.js tarball not found in offline bundle"
        exit 1
    fi
    
    # Install Docker from bundled .deb packages
    if ! command -v docker &> /dev/null; then
        print_step "Installing Docker from offline bundle..."
        
        if [[ -d "$OFFLINE_DIR/docker_debs" ]]; then
            # Install GPG key
            if [[ -f "$OFFLINE_DIR/docker_debs/docker.gpg" ]]; then
                sudo install -m 0755 -d /etc/apt/keyrings
                sudo cp "$OFFLINE_DIR/docker_debs/docker.gpg" /etc/apt/keyrings/docker.asc
                sudo chmod a+r /etc/apt/keyrings/docker.asc
            fi
            
            # Install .deb packages in order
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/containerd.io_arm64.deb" || sudo apt-get install -f -y
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-ce-cli_arm64.deb" || sudo apt-get install -f -y
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-ce_arm64.deb" || sudo apt-get install -f -y
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-buildx-plugin_arm64.deb" || true
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-compose-plugin_arm64.deb" || true
            
            sudo systemctl enable docker && sudo systemctl start docker
            sudo usermod -aG docker $USER
            
            print_step "Docker installed from offline bundle"
        else
            print_error "Docker packages not found in offline bundle"
            exit 1
        fi
    else
        print_step "Docker already installed"
    fi
}

#===============================================================================
# Phase 2: Hailo AI HAT+ 2 Setup (Hailo-10H GenAI)
#===============================================================================

phase2_hailo_setup() {
    print_header "Phase 2: Hailo AI HAT+ 2 Setup (Hailo-10H GenAI)"
    
    # Step 1: Check if Hailo-10H is detected via PCIe
    print_step "Checking for Hailo AI HAT+ 2 hardware..."
    
    if ! lspci 2>/dev/null | grep -qi "Hailo"; then
        print_warn "Hailo device not detected on PCIe bus"
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Ensure AI HAT+ 2 is properly connected via PCIe ribbon cable"
        echo "  2. Check that the Pi 5 Active Cooler is installed"
        echo "  3. Verify power supply is adequate (27W USB-C recommended)"
        echo ""
        echo "Run 'lspci | grep Hailo' to check detection"
        echo ""
        if ! prompt_yes_no "Continue without Hailo hardware detection?"; then
            exit 1
        fi
    else
        print_step "Hailo device detected: $(lspci | grep -i Hailo)"
    fi
    
    # Step 2: Install Hailo software stack if not present
    if ! command -v hailortcli &> /dev/null; then
        print_step "Installing Hailo software stack..."
        
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            # Offline: Install from bundled .deb packages
            if [[ -f "$OFFLINE_DIR/hailo_debs/hailo-all.deb" ]]; then
                sudo dpkg -i "$OFFLINE_DIR/hailo_debs/"*.deb || sudo apt-get install -f -y
            else
                print_warn "Hailo packages not found in offline bundle."
                print_warn "You will need to install manually when internet is available."
            fi
        else
            # Online: Install via apt (Raspberry Pi's official method)
            # IMPORTANT: Use hailo-h10-all for Hailo-10H (AI HAT+ 2), NOT hailo-all.
            # hailo-all is for Hailo-8/8L and installs a PCIe driver (4.23.0) that
            # doesn't support Hailo-10H, causing "Failed to create VDevice" errors.
            print_step "Installing hailo-h10-all package (HailoRT for Hailo-10H)..."
            sudo apt update
            sudo apt install -y dkms
            sudo apt install -y hailo-h10-all
        fi
    else
        print_step "HailoRT already installed"
    fi
    
    # Step 3: Ensure hailo_pci kernel module loads at boot and is loaded now.
    # The hailort-pcie-driver package installs the module but doesn't always
    # configure autoload, so /dev/hailo0 may be missing after reboot.
    print_step "Ensuring hailo_pci kernel module is loaded..."
    if ! lsmod | grep -q hailo_pci; then
        sudo modprobe hailo_pci || print_warn "Failed to load hailo_pci module"
    fi
    if ! grep -q 'hailo_pci' /etc/modules-load.d/hailo.conf 2>/dev/null; then
        echo "hailo_pci" | sudo tee /etc/modules-load.d/hailo.conf > /dev/null
        print_step "hailo_pci added to /etc/modules-load.d/ for boot autoload"
    fi
    # Wait briefly for /dev/hailo0 to appear
    for i in $(seq 1 5); do
        [[ -e /dev/hailo0 ]] && break
        sleep 1
    done
    if [[ ! -e /dev/hailo0 ]]; then
        print_warn "/dev/hailo0 not found — Hailo device may not be accessible"
    else
        print_step "/dev/hailo0 present"
    fi
    
    # Step 3b: Verify HailoRT installation
    if command -v hailortcli &> /dev/null; then
        print_step "Verifying Hailo installation..."
        hailortcli fw-control identify 2>/dev/null || print_warn "Could not identify Hailo device"
    fi
    
    # Step 4: Install Hailo GenAI Model Zoo (hailo-ollama)
    if ! command -v hailo-ollama &> /dev/null; then
        print_step "Installing Hailo GenAI Model Zoo (hailo-ollama)..."
        
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            # Offline: Install from bundled .deb
            GENAI_DEB=$(ls "$OFFLINE_DIR"/hailo_debs/hailo*genai*.deb 2>/dev/null | head -1)
            if [[ -f "$GENAI_DEB" ]]; then
                sudo dpkg -i "$GENAI_DEB" || sudo apt-get install -f -y
                print_step "Hailo GenAI Model Zoo installed from offline bundle"
            else
                print_warn "Hailo GenAI package not found in offline bundle."
                echo ""
                echo "To install manually, download from Hailo Developer Zone:"
                echo "  https://hailo.ai/developer-zone/software-downloads/"
                echo "Then run: sudo dpkg -i hailo_gen_ai_model_zoo_<ver>_arm64.deb"
            fi
        else
            # Online: Download and install from Hailo
            print_step "Downloading Hailo GenAI Model Zoo..."
            echo ""
            echo "The Hailo GenAI Model Zoo provides hailo-ollama server for LLMs."
            echo ""
            echo "Download options:"
            echo "  1) Auto-download from Raspberry Pi (if available in apt)"
            echo "  2) Manual download from Hailo Developer Zone"
            echo ""
            
            # Try apt first (Raspberry Pi may add this to their repo)
            if apt-cache show hailo-genai &>/dev/null; then
                sudo apt install -y hailo-genai
            else
                # Provide manual instructions
                print_warn "hailo-genai not in apt repository."
                echo ""
                echo "Please download manually from Hailo Developer Zone:"
                echo "  1. Go to: https://hailo.ai/developer-zone/software-downloads/"
                echo "  2. Download: hailo_gen_ai_model_zoo_5.1.1_arm64.deb (or latest)"
                echo "  3. Install: sudo dpkg -i hailo_gen_ai_model_zoo_*.deb"
                echo ""
                
                if prompt_yes_no "Have you already downloaded the .deb file?"; then
                    DEB_PATH=$(prompt_input "Enter path to .deb file" "")
                    if [[ -f "$DEB_PATH" ]]; then
                        sudo dpkg -i "$DEB_PATH" || sudo apt-get install -f -y
                    else
                        print_warn "File not found. Continuing without hailo-ollama."
                    fi
                fi
            fi
        fi
    else
        print_step "hailo-ollama already installed"
    fi
    
    # Check if hailo-ollama is now available
    if ! command -v hailo-ollama &> /dev/null; then
        print_warn "hailo-ollama not available. Skipping model setup."
        print_warn "You can install it later and run model setup manually."
        return
    fi
    
    # Step 5: Check if libhailort version matches hailo-ollama requirements
    # hailo-ollama from GenAI Model Zoo 5.1.1 requires libhailort.so.5.1.1
    print_step "Checking libhailort version compatibility..."
    
    REQUIRED_LIB="libhailort.so.5.1.1"
    if ! ldconfig -p | grep -q "$REQUIRED_LIB" && \
       ! [[ -f /usr/lib/$REQUIRED_LIB ]] && \
       ! [[ -f /usr/local/lib/$REQUIRED_LIB ]]; then
        print_warn "Required $REQUIRED_LIB not found (hailo-ollama needs HailoRT 5.1.1)"
        echo ""
        echo "The apt version of HailoRT may be incompatible with hailo-ollama."
        echo "Building HailoRT from source to fix this..."
        echo ""
        
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            print_error "Cannot build HailoRT from source in offline mode."
            print_warn "You will need internet access to build HailoRT."
            return
        fi
        
        if build_hailort_from_source "v5.1.1"; then
            # Update symlinks to point to new library
            print_step "Updating library symlinks..."
            sudo rm -f /usr/lib/libhailort.so 2>/dev/null || true
            if [[ -f /usr/local/lib/libhailort.so.5.1.1 ]]; then
                sudo ln -sf /usr/local/lib/libhailort.so.5.1.1 /usr/lib/libhailort.so
                sudo ln -sf /usr/local/lib/libhailort.so.5.1.1 /usr/lib/libhailort.so.5.1.1
                echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/hailort.conf > /dev/null
            fi
            sudo ldconfig
            print_step "HailoRT 5.1.1 installed and configured"
        else
            print_error "Failed to build HailoRT from source"
            return
        fi
    else
        print_step "libhailort 5.1.1 found - compatible with hailo-ollama"
    fi
    
    # Prompt user to select model
    echo "Available Hailo-optimized models:"
    echo ""
    echo "  1) qwen2:1.5b        - General purpose (recommended)"
    echo "  2) qwen2.5:1.5b      - Improved general purpose"
    echo "  3) qwen2.5-coder:1.5b - Optimized for coding"
    echo "  4) llama3.2:1b       - Meta's compact model"
    echo "  5) deepseek_r1:1.5b  - Reasoning-focused model"
    echo ""
    
    MODEL_CHOICE=$(prompt_input "Select model" "1")
    
    case $MODEL_CHOICE in
        1) SELECTED_MODEL="qwen2:1.5b" ;;
        2) SELECTED_MODEL="qwen2.5:1.5b" ;;
        3) SELECTED_MODEL="qwen2.5-coder:1.5b" ;;
        4) SELECTED_MODEL="llama3.2:1b" ;;
        5) SELECTED_MODEL="deepseek_r1:1.5b" ;;
        *) SELECTED_MODEL="qwen2:1.5b" ;;
    esac
    
    print_step "Selected model: $SELECTED_MODEL"
    
    # Step 6: Disable hailort_service if running (conflicts with hailo-ollama on Hailo-10H)
    # hailort_service is a multi-process RPC daemon for Hailo-8/8L. On Hailo-10H,
    # parallelism uses VDevice group_id="SHARED" instead. If hailort_service is
    # running, it holds /dev/hailo0 exclusively and hailo-ollama gets
    # HAILO_OUT_OF_PHYSICAL_DEVICES (status=74).
    if systemctl is-active --quiet hailort 2>/dev/null; then
        print_warn "hailort_service is running — stopping it (conflicts with hailo-ollama on Hailo-10H)"
        sudo systemctl stop hailort
        sudo systemctl disable hailort
        print_step "hailort_service stopped and disabled"
    fi
    
    # Step 7: Create systemd service for hailo-ollama (persistent server)
    # hailo-ollama MUST be running before OpenClaw or any client can use it.
    # It is a standalone C++ REST server (Ollama-compatible API on port 8000),
    # NOT the real Ollama binary — symlinking would not work.
    print_step "Creating systemd service for hailo-ollama..."
    
    HAILO_OLLAMA_BIN=$(command -v hailo-ollama)
    
    sudo tee /etc/systemd/system/hailo-ollama.service > /dev/null << EOF
[Unit]
Description=Hailo-Ollama GenAI Server (Ollama-compatible API on Hailo-10H)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$HAILO_OLLAMA_BIN
ExecStartPost=/bin/bash -c 'sleep 2 && curl -s -X POST http://localhost:8000/api/pull -H "Content-Type: application/json" -d "{\"model\":\"$SELECTED_MODEL\",\"stream\":false}" > /dev/null 2>&1'
Restart=on-failure
RestartSec=5
User=$USER
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable hailo-ollama.service
    sudo systemctl start hailo-ollama.service
    
    # Wait for the server to be ready
    print_step "Waiting for hailo-ollama server to start..."
    for i in $(seq 1 15); do
        if curl -s http://localhost:8000/api/version &>/dev/null; then
            print_step "hailo-ollama server is running on port 8000"
            break
        fi
        sleep 1
    done
    
    if ! curl -s http://localhost:8000/api/version &>/dev/null; then
        print_error "hailo-ollama server failed to start"
        print_warn "Check logs with: journalctl -u hailo-ollama.service"
        return
    fi
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Check if model exists in offline bundle
        MODEL_DIR_NAME="${SELECTED_MODEL//:/\/}"  # Convert qwen2:1.5b to qwen2/1.5b
        if [[ -d "$OFFLINE_DIR/hailo_models/$MODEL_DIR_NAME" ]]; then
            print_step "Installing $SELECTED_MODEL from offline bundle..."
            mkdir -p ~/.hailo-ollama/models
            cp -r "$OFFLINE_DIR/hailo_models/$MODEL_DIR_NAME" ~/.hailo-ollama/models/ 2>/dev/null || true
            print_step "Model installed from offline bundle"
        else
            print_warn "Model $SELECTED_MODEL not found in offline bundle."
            print_warn "Available models in bundle:"
            ls -la "$OFFLINE_DIR/hailo_models/" 2>/dev/null || echo "  (none)"
            print_warn "You will need to download the model when internet is available:"
            echo "  hailo-ollama pull $SELECTED_MODEL"
        fi
    else
        print_step "Pulling $SELECTED_MODEL model (this may take several minutes)..."
        echo ""
        
        # Use a temp file to capture output while showing progress
        PULL_OUTPUT=$(mktemp)
        
        # Run curl and tee output to both terminal and file
        if curl -s http://localhost:8000/api/pull \
            -H 'Content-Type: application/json' \
            -d "{\"model\":\"$SELECTED_MODEL\",\"stream\":true}" 2>&1 | tee "$PULL_OUTPUT"; then
            
            # Check if output contains error indicators
            if grep -qi "error\|500\|failed\|not found" "$PULL_OUTPUT"; then
                echo ""
                print_error "Model pull encountered an error"
                print_warn "You may need to pull it manually later:"
                echo "  curl http://localhost:8000/api/pull -H 'Content-Type: application/json' -d '{\"model\":\"$SELECTED_MODEL\",\"stream\":true}'"
            elif [[ ! -s "$PULL_OUTPUT" ]]; then
                echo ""
                print_error "No response from hailo-ollama server"
                print_warn "Check if hailo-ollama is running: ps aux | grep hailo-ollama"
            else
                echo ""
                print_step "Model $SELECTED_MODEL pulled successfully"
            fi
        else
            echo ""
            print_error "curl command failed"
            print_warn "Check network connectivity and hailo-ollama server status"
        fi
        
        rm -f "$PULL_OUTPUT"
    fi
    
    # Store selected model for later use in config
    HAILO_MODEL="$SELECTED_MODEL"
    
    # --- Install the sanitizing proxy (optional) ---
    # hailo-ollama's oatpp framework crashes on fields OpenClaw sends (tools,
    # stream_options, store) and its /api/show DTO is buggy. The proxy:
    #   - Strips unsupported request fields
    #   - Replaces massive system prompt with minimal one (2048-token context)
    #   - Converts non-streaming response to SSE for OpenClaw's SDK
    #   - Fixes nanosecond timestamps and missing usage fields
    #   - Fakes /api/show to avoid DTO crash
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" == "true" ]]; then
        print_step "Installing hailo-ollama sanitizing proxy..."
        
        PROXY_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hailo-sanitize-proxy.py"
        if [[ ! -f "$PROXY_SRC" ]]; then
            print_error "hailo-sanitize-proxy.py not found alongside installer"
            print_warn "Expected at: $PROXY_SRC"
        else
            sudo cp "$PROXY_SRC" /usr/local/bin/hailo-sanitize-proxy.py
            sudo chmod +x /usr/local/bin/hailo-sanitize-proxy.py
            
            sudo tee /etc/systemd/system/hailo-sanitize-proxy.service > /dev/null << 'EOF'
[Unit]
Description=Hailo-Ollama Sanitizing Proxy
After=hailo-ollama.service
Requires=hailo-ollama.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/hailo-sanitize-proxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            
            sudo systemctl daemon-reload
            sudo systemctl enable hailo-sanitize-proxy.service
            sudo systemctl start hailo-sanitize-proxy.service
            
            # Verify proxy is running
            sleep 2
            if curl -s http://127.0.0.1:8081/api/tags &>/dev/null; then
                print_step "Sanitizing proxy running on port 8081"
            else
                print_warn "Sanitizing proxy may not have started — check: journalctl -u hailo-sanitize-proxy"
            fi
        fi
    else
        print_warn "Skipping sanitizing proxy (USE_SANITIZER_PROXY_ON_OLLAMA=false)"
    fi
    
    print_step "Hailo GenAI stack configured with $SELECTED_MODEL"
}

#===============================================================================
# Phase 3: OpenClaw Installation
#===============================================================================

phase3_openclaw_install() {
    print_header "Phase 3: OpenClaw Installation"

    ensure_homebrew
    
    if ! command -v openclaw &> /dev/null; then
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            print_step "Installing OpenClaw from offline bundle..."
            OPENCLAW_TGZ=$(ls "$OFFLINE_DIR"/openclaw-*.tgz 2>/dev/null | head -1)
            if [[ -f "$OPENCLAW_TGZ" ]]; then
                sudo npm install -g "$OPENCLAW_TGZ"
                print_step "OpenClaw installed from offline bundle"
            else
                print_error "OpenClaw package not found in offline bundle"
                exit 1
            fi
        else
            print_step "Installing OpenClaw..."
            curl -fsSL https://openclaw.ai/install.sh | bash
        fi
    else
        print_step "OpenClaw already installed"
    fi
    
    # Run onboarding (non-interactive parts)
    print_step "Running OpenClaw onboarding..."
    openclaw onboard --install-daemon || {
        print_warn "Onboarding may require manual completion"
    }
    
    # Fix: remove duplicate nextcloud-talk extension from user-space if it exists.
    # OpenClaw bundles nextcloud-talk in its npm-global extensions dir; a second
    # copy under ~/.openclaw/extensions causes "duplicate plugin id" warnings and
    # may fail to load due to missing 'zod' dependency.
    if [[ -d "$HOME/.openclaw/extensions/nextcloud-talk" ]]; then
        print_step "Removing duplicate nextcloud-talk extension (bundled copy is sufficient)..."
        rm -rf "$HOME/.openclaw/extensions/nextcloud-talk"
    fi
    
    # Configure Hailo as primary model (use selected model from phase2)
    # NOTE: We use EXPLICIT provider config via the sanitizing proxy (port 8081):
    #   1. hailo-ollama runs on port 8000 with OpenAI-compatible /v1 endpoints
    #   2. The proxy strips unsupported fields, simplifies system prompts,
    #      converts responses to SSE, and fakes /api/show
    #   3. Explicit config with "api": "openai-completions" uses /v1/chat/completions
    print_step "Configuring Hailo $HAILO_MODEL as primary model..."
    mkdir -p "$(dirname "$OPENCLAW_CONFIG")"
    
    # Remove any old iptables redirect rules from previous install attempts
    sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 11434 -j REDIRECT --to-port 8000 2>/dev/null || true
    sudo netfilter-persistent save 2>/dev/null || true
    
    # Unset OLLAMA_API_KEY — we use explicit provider config, not auto-discovery.
    # Auto-discovery probes /api/show which causes 500 errors on hailo-ollama.
    sed -i '/OLLAMA_API_KEY/d' "$HOME/.bashrc" 2>/dev/null || true
    mkdir -p "$HOME/.openclaw"
    sed -i '/OLLAMA_API_KEY/d' "$HOME/.openclaw/.env" 2>/dev/null || true
    unset OLLAMA_API_KEY 2>/dev/null || true
    
    # Convert model name for ollama provider format (e.g., qwen2:1.5b -> ollama/qwen2:1.5b)
    # If USE_SANITIZER_PROXY_ON_OLLAMA=true, we route through the proxy on port 8081.
    HAILO_PROVIDER_MODEL="ollama/${HAILO_MODEL:-qwen2:1.5b}"
    MODEL_ID="${HAILO_MODEL:-qwen2:1.5b}"
    MODEL_BASE_URL="$(get_hailo_openai_base_url)"
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" != "true" ]]; then
        print_warn "Sanitizing proxy disabled; OpenClaw will call hailo-ollama directly"
    fi
    
    # Use explicit provider config with /v1/chat/completions via sanitizing proxy.
    # The proxy (port 8081) sits between OpenClaw and hailo-ollama (port 8000).
    # We set contextWindow to 16000 to satisfy OpenClaw's minimum requirement
    # (real context is 2048, maxTokens caps actual generation).
    if [[ "$USE_OPENCLAW_TOOLS" == "true" ]]; then
        TOOLS_BLOCK=""
    else
        TOOLS_BLOCK='  "tools": {
    "deny": ["*"]
  },'
        print_warn "OpenClaw tools disabled (USE_OPENCLAW_TOOLS=false)"
    fi

    cat > "$OPENCLAW_CONFIG" << EOF
{
  "gateway": {
    "mode": "local"
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "$MODEL_BASE_URL",
        "apiKey": "hailo-local",
        "api": "openai-completions",
        "models": [
          {
            "id": "$MODEL_ID",
            "name": "$MODEL_ID",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 16000,
            "maxTokens": 2048
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "$HAILO_PROVIDER_MODEL"
      },
      "models": {
        "$HAILO_PROVIDER_MODEL": {
          "streaming": false
        }
      },
      "sandbox": {
        "mode": "workspace",
        "rootPath": "~/.openclaw/workspace"
      },
      "heartbeat": {
        "every": "4h",
        "activeHours": { "start": "07:00", "end": "18:00" },
        "target": "last"
      }
    }
  },
  $TOOLS_BLOCK
  "plugins": {
    "allow": ["nextcloud-talk"]
  }
}
EOF
    
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" == "true" ]]; then
        print_step "OpenClaw configured with Hailo-Ollama via sanitizing proxy"
    else
        print_step "OpenClaw configured with Hailo-Ollama direct endpoint"
    fi
    print_step "Primary model: $HAILO_PROVIDER_MODEL (cost: \$0)"
    
    # Write auth profile so the agent can use the Ollama provider.
    # OpenClaw requires a credential entry in auth-profiles.json even for local
    # providers that don't need real auth (known issue: openclaw/openclaw#3740).
    print_step "Writing Ollama auth profile for main agent..."
    mkdir -p "$HOME/.openclaw/agents/main/agent"
    cat > "$HOME/.openclaw/agents/main/agent/auth-profiles.json" << 'EOF'
{
  "ollama:local": {
    "type": "token",
    "provider": "ollama",
    "token": "hailo-local"
  },
  "lastGood": {
    "ollama": "ollama:local"
  }
}
EOF
    
    # Restart OpenClaw daemon so it picks up the new config.
    print_step "Restarting OpenClaw daemon with Hailo model config..."
    openclaw daemon restart 2>/dev/null || openclaw gateway restart 2>/dev/null || {
        print_warn "Could not restart daemon automatically — restart manually after install"
    }
}

phase3_picoclaw_install() {
    print_header "Phase 3: PicoClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v go &> /dev/null; then
        print_step "Installing Go toolchain for PicoClaw build..."
        sudo apt update
        sudo apt install -y golang-go make git
    fi

    local pico_dir="$HOME/.picoclaw-src"
    if [[ -d "$pico_dir/.git" ]]; then
        git -C "$pico_dir" pull --ff-only
    else
        git clone https://github.com/sipeed/picoclaw.git "$pico_dir"
    fi

    print_step "Building PicoClaw..."
    make -C "$pico_dir" deps
    make -C "$pico_dir" build
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$pico_dir/build/picoclaw" "$HOME/.local/bin/picoclaw"

    mkdir -p "$HOME/.picoclaw"
    mkdir -p "$HOME/.config/picoclaw"
    cat > "$HOME/.picoclaw/config.json" << EOF
{
  "agents": {
    "defaults": {
      "workspace": "~/.picoclaw/workspace",
      "restrict_to_workspace": true,
      "model": "$HAILO_MODEL",
      "max_tokens": 2048,
      "temperature": 0.7,
      "max_tool_iterations": 20
    }
  },
  "providers": {
    "ollama": {
      "api_key": "hailo-local",
      "api_base": "$model_base_url"
    }
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 18790
  }
}
EOF

    cp "$HOME/.picoclaw/config.json" "$HOME/.config/picoclaw/config.json"

    print_step "PicoClaw installed and configured for local Hailo endpoint: $model_base_url"
    write_unified_facade_runtime_profile
}

phase3_zeroclaw_install() {
    print_header "Phase 3: ZeroClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v cargo &> /dev/null; then
        print_step "Installing Rust toolchain for ZeroClaw build..."
        sudo apt update
        sudo apt install -y cargo rustc git
    fi

    local zero_dir="$HOME/.zeroclaw-src"
    if [[ -d "$zero_dir/.git" ]]; then
        git -C "$zero_dir" pull --ff-only
    else
        git clone https://github.com/openagen/zeroclaw.git "$zero_dir"
    fi

    print_step "Building ZeroClaw (release)..."
    local build_log
    build_log=$(mktemp)

    if ! cargo build --release --manifest-path "$zero_dir/Cargo.toml" >"$build_log" 2>&1; then
        print_warn "ZeroClaw build failed with system Rust/cargo. Trying rustup stable toolchain..."

        if ! command -v rustup &> /dev/null; then
            print_step "Installing rustup (stable toolchain manager)..."
            RUSTUP_INIT_SKIP_PATH_CHECK=yes curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
        fi

        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        rustup toolchain install stable --profile minimal
        rustup default stable

        if ! cargo build --release --manifest-path "$zero_dir/Cargo.toml" >"$build_log" 2>&1; then
            print_error "ZeroClaw build failed even with rustup stable"
            tail -n 80 "$build_log" || true
            rm -f "$build_log"
            return 1
        fi
    fi

    rm -f "$build_log"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$zero_dir/target/release/zeroclaw" "$HOME/.local/bin/zeroclaw"

    mkdir -p "$HOME/.zeroclaw"
    cat > "$HOME/.zeroclaw/config.toml" << EOF
api_key = "hailo-local"
default_provider = "custom:$model_base_url"
default_model = "$HAILO_MODEL"
default_temperature = 0.7

[gateway]
host = "127.0.0.1"
port = 8080
require_pairing = true

[autonomy]
workspace_only = true

[heartbeat]
enabled = false
interval_minutes = 30
EOF

    print_step "ZeroClaw installed (local Hailo defaults written to ~/.zeroclaw/config.toml; endpoint=$model_base_url)"
    write_unified_facade_runtime_profile
}

phase3_nanobot_install() {
    print_header "Phase 3: Nanobot Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v pipx &> /dev/null; then
        print_step "Installing pipx and Python venv support for Nanobot..."
        sudo apt update
        sudo apt install -y pipx python3-venv
    fi

    if ! command -v pipx &> /dev/null; then
        print_error "pipx not available after install attempt"
        return 1
    fi

    python3 -m pipx ensurepath >/dev/null 2>&1 || true

    if pipx list 2>/dev/null | grep -q "package nanobot-ai"; then
        print_step "Upgrading Nanobot (nanobot-ai) via pipx..."
        pipx upgrade nanobot-ai
    else
        print_step "Installing Nanobot (nanobot-ai) via pipx..."
        pipx install nanobot-ai
    fi

    mkdir -p "$HOME/.nanobot"
    cat > "$HOME/.nanobot/config.json" << EOF
{
  "agents": {
    "defaults": {
      "workspace": "~/.nanobot/workspace",
      "model": "$HAILO_MODEL",
      "max_tokens": 2048,
      "temperature": 0.7,
      "max_tool_iterations": 20,
      "memory_window": 50
    }
  },
  "providers": {
    "custom": {
      "api_key": "hailo-local",
      "api_base": "$model_base_url"
    }
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 18790
  },
  "tools": {
    "restrict_to_workspace": true
  }
}
EOF

    mkdir -p "$HOME/.nanobot/workspace"

    print_step "Nanobot installed and configured for local Hailo endpoint: $model_base_url"
    write_unified_facade_runtime_profile
}

phase3_moltis_install() {
    print_header "Phase 3: Moltis Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v cargo &> /dev/null; then
        print_step "Installing Rust toolchain for Moltis build..."
        sudo apt update
        sudo apt install -y cargo rustc git
    fi

    print_step "Installing Moltis via cargo (this may take several minutes)..."
    if ! cargo install --locked --git https://github.com/moltis-org/moltis moltis; then
        print_warn "Moltis install failed with system Rust/cargo. Trying rustup stable toolchain..."

        if ! command -v rustup &> /dev/null; then
            print_step "Installing rustup (stable toolchain manager)..."
            RUSTUP_INIT_SKIP_PATH_CHECK=yes curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
        fi

        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        rustup toolchain install stable --profile minimal
        rustup default stable

        cargo install --locked --git https://github.com/moltis-org/moltis moltis
    fi

    mkdir -p "$HOME/.local/bin"
    if [[ -x "$HOME/.cargo/bin/moltis" ]]; then
        install -m 0755 "$HOME/.cargo/bin/moltis" "$HOME/.local/bin/moltis"
    else
        print_error "Moltis binary not found at ~/.cargo/bin/moltis after install"
        return 1
    fi

    mkdir -p "$HOME/.config/moltis"
    mkdir -p "$HOME/.moltis"
    cat > "$HOME/.config/moltis/moltis.toml" << EOF
[providers]
offered = ["ollama"]

[providers.ollama]
enabled = true
base_url = "$model_base_url"
models = ["$HAILO_MODEL"]
fetch_models = false

[chat]
priority_models = ["$HAILO_MODEL"]
EOF

    print_step "Moltis installed and configured for local Hailo endpoint: $model_base_url"
    write_unified_facade_runtime_profile
}

phase3_ironclaw_install() {
    print_header "Phase 3: IronClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v cargo &> /dev/null; then
        print_step "Installing Rust toolchain for IronClaw build..."
        sudo apt update
        sudo apt install -y cargo rustc git
    fi

    print_step "Installing IronClaw via cargo (this may take several minutes)..."
    if ! cargo install --locked --git https://github.com/nearai/ironclaw.git ironclaw; then
        print_warn "IronClaw install failed with system Rust/cargo. Trying rustup stable toolchain..."

        if ! command -v rustup &> /dev/null; then
            print_step "Installing rustup (stable toolchain manager)..."
            RUSTUP_INIT_SKIP_PATH_CHECK=yes curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
        fi

        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        rustup toolchain install stable --profile minimal
        rustup default stable

        cargo install --locked --git https://github.com/nearai/ironclaw.git ironclaw
    fi

    mkdir -p "$HOME/.local/bin"
    if [[ -x "$HOME/.cargo/bin/ironclaw" ]]; then
        install -m 0755 "$HOME/.cargo/bin/ironclaw" "$HOME/.local/bin/ironclaw"
    else
        print_error "IronClaw binary not found at ~/.cargo/bin/ironclaw after install"
        return 1
    fi

    mkdir -p "$HOME/.ironclaw"
    cat > "$HOME/.ironclaw/.env" << EOF
DATABASE_URL=postgresql://localhost/ironclaw
OPENAI_BASE_URL=$model_base_url
OPENAI_API_KEY=hailo-local
OPENAI_MODEL=$HAILO_MODEL
LLM_BACKEND=openai_compatible
EOF

    print_step "IronClaw installed and local Hailo defaults written to ~/.ironclaw/.env (endpoint=$model_base_url)"
    write_unified_facade_runtime_profile
}

phase3_install_selected_claw() {
    CLAW_FLAVOR=$(normalize_claw_flavor "$CLAW_FLAVOR")
    case "$CLAW_FLAVOR" in
        picoclaw)
            phase3_picoclaw_install
            ;;
        zeroclaw)
            phase3_zeroclaw_install
            ;;
        nanobot)
            phase3_nanobot_install
            ;;
        moltis)
            phase3_moltis_install
            ;;
        ironclaw)
            phase3_ironclaw_install
            ;;
        *)
            phase3_openclaw_install
            write_unified_facade_runtime_profile
            ;;
    esac
}

#===============================================================================
# Phase 4: Deploy Custom Configuration
#===============================================================================

phase4_deploy_config() {
    print_header "Phase 4: Deploy Custom Configuration"
    
    mkdir -p "$OPENCLAW_WORKSPACE"
    mkdir -p "$OPENCLAW_WORKSPACE/skills/molt_tools"
    
    # Copy clawdbot-assistant.md as CLAUDE.md and AGENTS.md
    if [[ -f "$SCRIPT_DIR/clawdbot-assistant.md" ]]; then
        cp "$SCRIPT_DIR/clawdbot-assistant.md" "$OPENCLAW_WORKSPACE/CLAUDE.md"
        cp "$SCRIPT_DIR/clawdbot-assistant.md" "$OPENCLAW_WORKSPACE/AGENTS.md"
        print_step "Deployed clawdbot-assistant.md as CLAUDE.md and AGENTS.md"
    else
        print_error "clawdbot-assistant.md not found in $SCRIPT_DIR"
    fi
    
    # Copy HEARTBEAT.md template
    if [[ -f "$SCRIPT_DIR/templates/HEARTBEAT.md" ]]; then
        cp "$SCRIPT_DIR/templates/HEARTBEAT.md" "$OPENCLAW_WORKSPACE/HEARTBEAT.md"
        print_step "Deployed HEARTBEAT.md"
    fi
    
    # Copy BOOTSTRAP.md (first task)
    if [[ -f "$SCRIPT_DIR/templates/BOOTSTRAP.md" ]]; then
        cp "$SCRIPT_DIR/templates/BOOTSTRAP.md" "$OPENCLAW_WORKSPACE/BOOTSTRAP.md"
        print_step "Deployed BOOTSTRAP.md (first boot task)"
    fi
    
    # Customize "What I Care About" section
    print_header "Customize Your Assistant"
    
    echo "Let's personalize your assistant's 'What I Care About' section."
    echo ""
    
    DEEP_WORK=$(prompt_input "Deep work hours (don't interrupt)" "9am-12pm, 2pm-5pm")
    PRIORITY_CONTACTS=$(prompt_input "Priority contacts (comma-separated)" "")
    PRIORITY_PROJECTS=$(prompt_input "Priority projects (comma-separated)" "")
    IGNORE_LIST=$(prompt_input "Ignore list" "newsletters, promotional emails, LinkedIn")
    
    # Update AGENTS.md with customizations
    if [[ -f "$OPENCLAW_WORKSPACE/AGENTS.md" ]]; then
        sed -i "s/{list names}/$PRIORITY_CONTACTS/g" "$OPENCLAW_WORKSPACE/AGENTS.md"
        sed -i "s/{list projects}/$PRIORITY_PROJECTS/g" "$OPENCLAW_WORKSPACE/AGENTS.md"
        if [[ -n "$DEEP_WORK" ]]; then
            sed -i "s/9am-12pm, 2pm-5pm (don't interrupt)/$DEEP_WORK (don't interrupt)/g" "$OPENCLAW_WORKSPACE/AGENTS.md"
        fi
        print_step "Customized AGENTS.md with your preferences"
    fi
}

#===============================================================================
# Phase 5: Deploy molt_tools Skill
#===============================================================================

phase5_molt_tools() {
    print_header "Phase 5: Deploy molt_tools Skill"
    
    # Copy molt_tools
    if [[ -d "$SCRIPT_DIR/molt_tools" ]]; then
        cp -r "$SCRIPT_DIR/molt_tools/"* "$OPENCLAW_WORKSPACE/skills/molt_tools/"
        print_step "Copied molt_tools to workspace"
    fi
    
    # Create SKILL.md
    cat > "$OPENCLAW_WORKSPACE/skills/molt_tools/SKILL.md" << 'EOF'
---
name: molt_tools
description: Moltbook integration (check status/DMs/feed and post updates).
---

# Moltbook Skill

Tools for interacting with Moltbook social platform.

## check_moltbook.py
Checks agent status, DMs, and feed.
Usage: `python3 check_moltbook.py`

## post_to_moltbook.py
Posts content to Moltbook.
Usage: `python3 post_to_moltbook.py --title "Title" --content "Content" [--submolt general]`

Credentials: ~/.config/moltbook/credentials.json (requires api_key)
EOF
    print_step "Created SKILL.md for molt_tools"
    
    # Setup Moltbook credentials
    mkdir -p "$MOLTBOOK_CONFIG_DIR"
    
    if [[ -f "$MOLTBOOK_CONFIG_DIR/credentials.json" ]]; then
        print_step "Moltbook credentials already exist"
    else
        echo ""
        echo "Moltbook API key required for molt_tools skill."
        MOLTBOOK_API_KEY=$(prompt_input "Enter your Moltbook API key" "")
        
        if [[ -n "$MOLTBOOK_API_KEY" ]]; then
            cat > "$MOLTBOOK_CONFIG_DIR/credentials.json" << EOF
{
  "api_key": "$MOLTBOOK_API_KEY"
}
EOF
            chmod 600 "$MOLTBOOK_CONFIG_DIR/credentials.json"
            print_step "Moltbook credentials saved"
        else
            print_warn "No API key provided. molt_tools will not work until configured."
        fi
    fi
}

#===============================================================================
# Phase 6: Configure Proactive Behaviors
#===============================================================================

phase6_proactive_behaviors() {
    print_header "Phase 6: Configure Proactive Behaviors"
    
    echo "The following behaviors are OFF by default. Enable them now?"
    echo ""
    
    ENABLE_AUTO_EMAIL="false"
    ENABLE_AUTO_DECLINE="false"
    ENABLE_AUTO_ORGANIZE="false"
    ENABLE_STOCK_MONITOR="false"
    
    if prompt_yes_no "Enable auto-respond to routine emails?"; then
        ENABLE_AUTO_EMAIL="true"
    fi
    
    if prompt_yes_no "Enable auto-decline calendar invites?"; then
        ENABLE_AUTO_DECLINE="true"
    fi
    
    if prompt_yes_no "Enable auto-organize Downloads folder?"; then
        ENABLE_AUTO_ORGANIZE="true"
    fi
    
    if prompt_yes_no "Enable stock/crypto monitoring?"; then
        ENABLE_STOCK_MONITOR="true"
    fi
    
    # Append enabled behaviors to AGENTS.md
    if [[ "$ENABLE_AUTO_EMAIL" == "true" || "$ENABLE_AUTO_DECLINE" == "true" || "$ENABLE_AUTO_ORGANIZE" == "true" || "$ENABLE_STOCK_MONITOR" == "true" ]]; then
        echo "" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        echo "## Enabled Optional Behaviors" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_AUTO_EMAIL" == "true" ]] && echo "- Auto-respond to routine emails: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_AUTO_DECLINE" == "true" ]] && echo "- Auto-decline calendar invites: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_AUTO_ORGANIZE" == "true" ]] && echo "- Auto-organize Downloads folder: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_STOCK_MONITOR" == "true" ]] && echo "- Monitor stock/crypto prices: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        print_step "Enabled optional behaviors saved to AGENTS.md"
    fi
}

#===============================================================================
# Phase 7: Channel Configuration
#===============================================================================

phase7_channel_config() {
    print_header "Phase 7: Channel Configuration"
    
    echo "Select your communication channel (self-hosted options only):"
    echo ""
    echo "  1) WebChat (built-in, localhost only - zero setup)"
    echo "  2) Matrix (will install Synapse homeserver if needed)"
    echo ""
    
    CHANNEL_CHOICE=$(prompt_input "Choice" "1")
    
    if [[ "$CHANNEL_CHOICE" == "2" ]]; then
        setup_matrix_homeserver
    else
        print_step "WebChat selected - available at http://localhost:18789/"
    fi
}

setup_matrix_homeserver() {
    print_header "Matrix Homeserver Setup"
    
    # Check if Synapse is already running
    if docker ps | grep -q synapse; then
        print_step "Synapse already running"
        return
    fi
    
    echo "Matrix requires a domain name with DNS configured."
    MATRIX_DOMAIN=$(prompt_input "Enter your Matrix domain (e.g., matrix.yourdomain.com)" "")
    
    if [[ -z "$MATRIX_DOMAIN" ]]; then
        print_warn "No domain provided. Skipping Matrix setup."
        print_step "Falling back to WebChat"
        return
    fi
    
    print_step "Setting up Synapse Matrix homeserver..."
    
    # Create Synapse directory
    mkdir -p ~/matrix
    cd ~/matrix
    
    # Create docker-compose.yml
    cat > docker-compose.yml << 'EOF'
version: '3.3'
services:
  app:
    image: matrixdotorg/synapse
    restart: always
    ports:
      - 8008:8008
    volumes:
      - /var/docker_data/matrix:/data
EOF
    
    # Generate homeserver config
    print_step "Generating Synapse configuration..."
    sudo mkdir -p /var/docker_data/matrix
    docker run -it --rm \
        -v /var/docker_data/matrix:/data \
        -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" \
        -e SYNAPSE_REPORT_STATS=yes \
        matrixdotorg/synapse:latest generate
    
    # Start Synapse
    print_step "Starting Synapse..."
    docker compose up -d
    
    # Install and configure Nginx
    print_step "Configuring Nginx reverse proxy..."
    sudo apt-get install -y nginx
    
    sudo tee /etc/nginx/sites-available/matrix << EOF
server {
    server_name $MATRIX_DOMAIN;
    location / {
        proxy_pass http://localhost:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF
    
    sudo ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl restart nginx
    
    # SSL via Certbot
    print_step "Setting up SSL with Certbot..."
    sudo apt-get install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d "$MATRIX_DOMAIN" --non-interactive --agree-tos --email admin@"$MATRIX_DOMAIN" || {
        print_warn "Certbot failed. You may need to run it manually."
        echo "Run: sudo certbot --nginx -d $MATRIX_DOMAIN"
    }
    
    print_step "Matrix homeserver setup complete"
    echo ""
    print_warn "Remember to forward ports 80 and 443 to this Pi!"
}

#===============================================================================
# Phase 8: RAG Setup (Optional)
#===============================================================================

phase8_rag_setup() {
    print_header "Phase 8: RAG Setup (Optional)"
    
    echo "RAG (Retrieval-Augmented Generation) allows your assistant to answer"
    echo "questions based on your own documents (PDFs, text files, etc.)."
    echo ""
    
    if ! prompt_yes_no "Enable RAG with local document search?"; then
        print_step "Skipping RAG setup"
        return
    fi
    
    RAG_ENABLED=true
    RAG_DOCS_DIR="$HOME/.openclaw/rag_documents"
    RAG_INSTALL_DIR="$HOME/.openclaw/rag"
    RAG_DOCS_SOURCE_FILE="$RAG_INSTALL_DIR/.docs_source"
    
    # Install Python dependencies
    print_step "Installing RAG Python dependencies..."
    sudo apt install -y python3-pip python3-venv
    
    # Create RAG directory and virtual environment
    mkdir -p "$RAG_INSTALL_DIR"
    mkdir -p "$RAG_DOCS_DIR"
    
    python3 -m venv "$RAG_INSTALL_DIR/venv"
    source "$RAG_INSTALL_DIR/venv/bin/activate"
    
    # Install from requirements.txt
    if [[ -f "$SCRIPT_DIR/rag/requirements.txt" ]]; then
        pip install -r "$SCRIPT_DIR/rag/requirements.txt"
        print_step "RAG dependencies installed"
    else
        pip install llama-index-core llama-index-embeddings-ollama llama-index-llms-ollama llama-index-vector-stores-chroma chromadb pypdf
        print_step "RAG dependencies installed"
    fi
    
    # Copy RAG query + test scripts
    if [[ -f "$SCRIPT_DIR/rag/rag_query.py" ]]; then
        cp "$SCRIPT_DIR/rag/rag_query.py" "$RAG_INSTALL_DIR/"
        chmod +x "$RAG_INSTALL_DIR/rag_query.py"
        print_step "RAG query script installed"
    fi
    if [[ -f "$SCRIPT_DIR/rag/test_rag.py" ]]; then
        cp "$SCRIPT_DIR/rag/test_rag.py" "$RAG_INSTALL_DIR/"
        chmod +x "$RAG_INSTALL_DIR/test_rag.py"
        print_step "RAG test script installed"
    fi
    
    deactivate
    
    # Pull embedding model
    print_step "Pulling nomic-embed-text embedding model..."
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        if [[ -d "$OFFLINE_DIR/hailo_models/nomic-embed-text" ]]; then
            print_step "Installing nomic-embed-text from offline bundle..."
            mkdir -p ~/.hailo-ollama/models
            cp -r "$OFFLINE_DIR/hailo_models/nomic-embed-text" ~/.hailo-ollama/models/ 2>/dev/null || true
        else
            print_warn "nomic-embed-text not found in offline bundle."
            print_warn "You will need to download it when internet is available:"
            echo "  curl -H 'Content-Type: application/json' http://localhost:8000/api/pull -d '{\"model\":\"nomic-embed-text\",\"stream\":true}'"
        fi
    else
        curl -s -H 'Content-Type: application/json' http://localhost:8000/api/pull -d '{"model":"nomic-embed-text","stream":true}' || {
            print_warn "Failed to pull nomic-embed-text. You may need to pull it manually."
        }
    fi
    
    # Prompt for document directory to copy
    echo ""
    echo "You can copy a directory of documents to use for RAG."
    echo "Supported formats: PDF, TXT, MD, DOCX, etc."
    echo ""
    
    DOC_SOURCE_DEFAULT=""
    if [[ -f "$RAG_DOCS_SOURCE_FILE" ]]; then
        DOC_SOURCE_DEFAULT=$(cat "$RAG_DOCS_SOURCE_FILE" 2>/dev/null || true)
    fi
    DOC_SOURCE=$(prompt_input "Path to documents directory (leave empty to skip)" "$DOC_SOURCE_DEFAULT")
    
    if [[ -n "$DOC_SOURCE" ]] && [[ -d "$DOC_SOURCE" ]]; then
        print_step "Copying documents from $DOC_SOURCE to $RAG_DOCS_DIR..."
        cp -r "$DOC_SOURCE"/* "$RAG_DOCS_DIR/" 2>/dev/null || true
        
        DOC_COUNT=$(find "$RAG_DOCS_DIR" -type f | wc -l)
        print_step "Copied $DOC_COUNT document(s) to $RAG_DOCS_DIR"
        mkdir -p "$RAG_INSTALL_DIR"
        echo "$DOC_SOURCE" > "$RAG_DOCS_SOURCE_FILE"
    elif [[ -n "$DOC_SOURCE" ]]; then
        print_warn "Directory not found: $DOC_SOURCE"
        print_warn "You can manually copy documents to $RAG_DOCS_DIR later."
    else
        print_step "No documents copied. Add documents to $RAG_DOCS_DIR later."
    fi
    
    # Create environment file for RAG
    RAG_DOCS_DIR_ENV="$RAG_DOCS_DIR"
    if [[ -f "$RAG_DOCS_SOURCE_FILE" ]]; then
        SAVED_DOC_SOURCE=$(cat "$RAG_DOCS_SOURCE_FILE" 2>/dev/null || true)
        if [[ -n "$SAVED_DOC_SOURCE" ]]; then
            RAG_DOCS_DIR_ENV="$SAVED_DOC_SOURCE"
        fi
    fi
    cat > "$RAG_INSTALL_DIR/.env" << EOF
OLLAMA_BASE_URL=http://localhost:8000
HAILO_MODEL=$HAILO_MODEL
RAG_DATA_DIR=$RAG_DOCS_DIR_ENV
EMBEDDINGS_PROVIDER=local
EMBEDDINGS_MODEL=sentence-transformers/all-MiniLM-L6-v2
LLM_PROVIDER=openai
OPENAI_API_BASE=http://127.0.0.1:8081/v1
OPENAI_API_KEY=hailo-local
EOF
    
    # Create convenience script
    cat > "$HOME/.openclaw/rag_query.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
source ~/.openclaw/rag/venv/bin/activate
set -a
source ~/.openclaw/rag/.env
set +a

if [[ "${1:-}" == "--test" ]]; then
  shift
  python3 ~/.openclaw/rag/test_rag.py "$@"
else
  python3 ~/.openclaw/rag/rag_query.py "$@"
fi
deactivate
EOF
    chmod +x "$HOME/.openclaw/rag_query.sh"
    
    print_step "RAG setup complete"
    echo ""
    echo "RAG Usage:"
    echo "  Query RAG:       ~/.openclaw/rag_query.sh \"your question\""
    echo "  Interactive:     ~/.openclaw/rag_query.sh --interactive"
    echo "  Run smoke tests: ~/.openclaw/rag_query.sh --test"
    echo "  Documents dir:   $RAG_DOCS_DIR"
}

#===============================================================================
# Phase 9: Verification
#===============================================================================

phase9_verification() {
    print_header "Phase 9: Verification"
    
    print_step "Running OpenClaw diagnostics..."
    openclaw doctor || true
    openclaw status --all || true
    openclaw health || true
    
    print_step "Verification complete"
}

phase9_verify_selected_claw() {
    CLAW_FLAVOR=$(normalize_claw_flavor "$CLAW_FLAVOR")
    case "$CLAW_FLAVOR" in
        openclaw)
            phase9_verification
            ;;
        picoclaw)
            print_header "Phase 9: Verification (PicoClaw)"
            if command -v "$HOME/.local/bin/picoclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/picoclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "PicoClaw binary verification complete"
            ;;
        zeroclaw)
            print_header "Phase 9: Verification (ZeroClaw)"
            if command -v "$HOME/.local/bin/zeroclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/zeroclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "ZeroClaw binary verification complete"
            ;;
        nanobot)
            print_header "Phase 9: Verification (Nanobot)"
            if command -v "$HOME/.local/bin/nanobot" >/dev/null 2>&1; then
                "$HOME/.local/bin/nanobot" --version >/dev/null 2>&1 || true
            fi
            print_step "Nanobot binary verification complete"
            ;;
        moltis)
            print_header "Phase 9: Verification (Moltis)"
            if command -v "$HOME/.local/bin/moltis" >/dev/null 2>&1; then
                "$HOME/.local/bin/moltis" --version >/dev/null 2>&1 || true
            fi
            print_step "Moltis binary verification complete"
            ;;
        ironclaw)
            print_header "Phase 9: Verification (IronClaw)"
            if command -v "$HOME/.local/bin/ironclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/ironclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "IronClaw binary verification complete"
            ;;
    esac
}

#===============================================================================
# Main
#===============================================================================

main() {
    # Handle --prepare-offline mode
    if [[ "$PREPARE_OFFLINE" == "true" ]]; then
        prepare_offline_bundle
        exit 0
    fi
    
    print_header "OpenClaw Installer for Raspberry Pi 5 GenAI Kit"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        echo "*** OFFLINE MODE ***"
        echo ""
    fi
    
    echo "This installer will set up:"
    echo "  - Node.js 22+ (via n version manager)"
    echo "  - Docker (Trixie-specific)"
    echo "  - Hailo GenAI stack with qwen2:1.5b"
    echo "  - Selected claw flavor (OpenClaw/PicoClaw/ZeroClaw/Nanobot/Moltis/IronClaw) with local Hailo model wiring"
    echo "  - molt_tools skill for Moltbook integration"
    echo "  - First boot task: post to Moltbook"
    echo ""
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        echo "Installing from offline bundle at: $OFFLINE_DIR"
        echo ""
    fi
    
    if ! prompt_yes_no "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    prompt_claw_flavor
    
    phase1_system_prep
    phase2_hailo_setup
    phase3_install_selected_claw
    install_unified_facade_http_service
    if [[ "$CLAW_FLAVOR" == "openclaw" ]]; then
        phase4_deploy_config
        phase5_molt_tools
        phase6_proactive_behaviors
        phase7_channel_config
        phase8_rag_setup
    else
        print_warn "Skipping OpenClaw-specific phases (4-8) for flavor: $CLAW_FLAVOR"
    fi
    phase9_verify_selected_claw
    
    print_header "Installation Complete!"
    
    echo "Selected claw flavor is now installed and configured: $CLAW_FLAVOR"
    echo ""
    echo "Services:"
    echo "  hailo-ollama : systemd service on port 8000 (auto-starts on boot)"
    echo "    sudo systemctl status hailo-ollama"
    echo "    sudo journalctl -u hailo-ollama -f"
    echo "  unified-chat-facade : systemd static HTTP server on port $UNIFIED_FACADE_HTTP_PORT"
    echo "    sudo systemctl status unified-chat-facade"
    echo "    sudo journalctl -u unified-chat-facade -f"
    echo ""
    echo "First boot task:"
    echo "  - Check Moltbook connection"
    echo "  - Post: \"i've been boxed into a Raspberry Pi !\""
    echo ""
    if [[ "$CLAW_FLAVOR" == "openclaw" ]]; then
        echo "To start OpenClaw:"
        echo "  openclaw gateway --port 18789 --verbose"
        echo ""
        echo "Dashboard: http://localhost:18789/"
    elif [[ "$CLAW_FLAVOR" == "picoclaw" ]]; then
        echo "To start PicoClaw:"
        echo "  ~/.local/bin/picoclaw gateway"
    elif [[ "$CLAW_FLAVOR" == "zeroclaw" ]]; then
        echo "To start ZeroClaw:"
        echo "  ~/.local/bin/zeroclaw gateway"
    elif [[ "$CLAW_FLAVOR" == "nanobot" ]]; then
        echo "To start Nanobot:"
        echo "  ~/.local/bin/nanobot gateway"
        echo "  ~/.local/bin/nanobot agent"
    elif [[ "$CLAW_FLAVOR" == "ironclaw" ]]; then
        echo "To start IronClaw:"
        echo "  ~/.local/bin/ironclaw"
        echo "  ~/.local/bin/ironclaw onboard"
    else
        echo "To start Moltis:"
        echo "  ~/.local/bin/moltis"
        echo "  ~/.local/bin/moltis agent --message \"Hello\""
    fi
    echo ""
    echo "Unified facade URL: http://127.0.0.1:$UNIFIED_FACADE_HTTP_PORT/templates/unified-chat-facade.html"
    echo ""
    print_step "Done!"
}

main "$@"
