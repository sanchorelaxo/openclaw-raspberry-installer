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
                curl -s http://localhost:8000/api/pull -d "{\"model\":\"$model\",\"stream\":false}" || {
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
            print_step "Installing hailo-all package (HailoRT + TAPPAS Core)..."
            sudo apt update
            sudo apt install -y dkms
            sudo apt install -y hailo-all
        fi
    else
        print_step "HailoRT already installed"
    fi
    
    # Step 3: Verify HailoRT installation
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
    
    # Step 5: Test hailo-ollama execution - build HailoRT from source if it fails
    print_step "Testing hailo-ollama execution..."
    if ! hailo-ollama --version &>/dev/null 2>&1; then
        print_warn "hailo-ollama failed to execute (likely libhailort version mismatch)"
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
            print_step "Retesting hailo-ollama..."
            if hailo-ollama --version &>/dev/null 2>&1; then
                print_step "hailo-ollama now works correctly"
            else
                print_error "hailo-ollama still failing after HailoRT rebuild"
                print_warn "You may need to troubleshoot manually"
                return
            fi
        else
            print_error "Failed to build HailoRT from source"
            return
        fi
    else
        print_step "hailo-ollama executes successfully"
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
    
    print_step "Starting hailo-ollama server..."
    hailo-ollama &
    sleep 3
    
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
        print_step "Pulling $SELECTED_MODEL model..."
        curl -s http://localhost:8000/api/pull -d "{\"model\":\"$SELECTED_MODEL\",\"stream\":false}" || {
            print_warn "Failed to pull model. You may need to pull it manually later:"
            echo "  hailo-ollama pull $SELECTED_MODEL"
        }
    fi
    
    # Store selected model for later use in config
    HAILO_MODEL="$SELECTED_MODEL"
    
    print_step "Hailo GenAI stack configured with $SELECTED_MODEL"
}

#===============================================================================
# Phase 3: OpenClaw Installation
#===============================================================================

phase3_openclaw_install() {
    print_header "Phase 3: OpenClaw Installation"
    
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
    
    # Configure Hailo as primary model (use selected model from phase2)
    print_step "Configuring Hailo $HAILO_MODEL as primary model..."
    mkdir -p "$(dirname "$OPENCLAW_CONFIG")"
    
    # Convert model name for ollama format (e.g., qwen2:1.5b -> ollama/qwen2:1.5b)
    OLLAMA_MODEL="ollama/${HAILO_MODEL:-qwen2:1.5b}"
    
    cat > "$OPENCLAW_CONFIG" << EOF
{
  "agent": {
    "model": "$OLLAMA_MODEL",
    "provider": {
      "ollama": {
        "baseUrl": "http://localhost:8000"
      }
    }
  },
  "agents": {
    "defaults": {
      "heartbeat": {
        "every": "4h",
        "activeHours": { "start": "07:00", "end": "18:00" },
        "target": "last"
      }
    }
  }
}
EOF
    
    print_step "OpenClaw configured with local Hailo model"
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
    
    # Copy RAG test script
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
            echo "  curl http://localhost:8000/api/pull -d '{\"model\":\"nomic-embed-text\"}'"
        fi
    else
        curl -s http://localhost:8000/api/pull -d '{"model":"nomic-embed-text","stream":false}' || {
            print_warn "Failed to pull nomic-embed-text. You may need to pull it manually."
        }
    fi
    
    # Prompt for document directory to copy
    echo ""
    echo "You can copy a directory of documents to use for RAG."
    echo "Supported formats: PDF, TXT, MD, DOCX, etc."
    echo ""
    
    DOC_SOURCE=$(prompt_input "Path to documents directory (leave empty to skip)" "")
    
    if [[ -n "$DOC_SOURCE" ]] && [[ -d "$DOC_SOURCE" ]]; then
        print_step "Copying documents from $DOC_SOURCE to $RAG_DOCS_DIR..."
        cp -r "$DOC_SOURCE"/* "$RAG_DOCS_DIR/" 2>/dev/null || true
        
        DOC_COUNT=$(find "$RAG_DOCS_DIR" -type f | wc -l)
        print_step "Copied $DOC_COUNT document(s) to $RAG_DOCS_DIR"
    elif [[ -n "$DOC_SOURCE" ]]; then
        print_warn "Directory not found: $DOC_SOURCE"
        print_warn "You can manually copy documents to $RAG_DOCS_DIR later."
    else
        print_step "No documents copied. Add documents to $RAG_DOCS_DIR later."
    fi
    
    # Create environment file for RAG
    cat > "$RAG_INSTALL_DIR/.env" << EOF
OLLAMA_BASE_URL=http://localhost:8000
HAILO_MODEL=$HAILO_MODEL
RAG_DATA_DIR=$RAG_DOCS_DIR
EOF
    
    # Create convenience script
    cat > "$HOME/.openclaw/rag_query.sh" << 'EOF'
#!/bin/bash
source ~/.openclaw/rag/venv/bin/activate
export $(cat ~/.openclaw/rag/.env | xargs)
python3 ~/.openclaw/rag/test_rag.py "$@"
deactivate
EOF
    chmod +x "$HOME/.openclaw/rag_query.sh"
    
    print_step "RAG setup complete"
    echo ""
    echo "RAG Usage:"
    echo "  Test RAG:        ~/.openclaw/rag_query.sh"
    echo "  Interactive:     ~/.openclaw/rag_query.sh --interactive"
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
    echo "  - OpenClaw with custom executive assistant config"
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
    
    phase1_system_prep
    phase2_hailo_setup
    phase3_openclaw_install
    phase4_deploy_config
    phase5_molt_tools
    phase6_proactive_behaviors
    phase7_channel_config
    phase8_rag_setup
    phase9_verification
    
    print_header "Installation Complete!"
    
    echo "OpenClaw is now installed and configured."
    echo ""
    echo "First boot task:"
    echo "  - Check Moltbook connection"
    echo "  - Post: \"i've been boxed into a Raspberry Pi !\""
    echo ""
    echo "To start OpenClaw:"
    echo "  openclaw gateway --port 18789 --verbose"
    echo ""
    echo "Dashboard: http://localhost:18789/"
    echo ""
    print_step "Done!"
}

main "$@"
