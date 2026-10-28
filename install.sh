#!/usr/bin/env bash
# ==============================================================================
# install.sh
#
# Installer for Proton Drive CLI Sync Suite.
#
# Supports:
#   - User installation:   ~/.local/bin (Default, no sudo required)
#   - System installation: /usr/local/bin (via --system or running with sudo)
#   - Automatic Python 3 detection and package manager prompt
#   - Standalone binary mode (installs dist/protondrive-sync if available)
#   - Clean uninstallation via --uninstall
# ==============================================================================

set -euo pipefail

# Text styling
BOLD=$(tput bold 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
NORMAL=$(tput sgr0 2>/dev/null || echo "")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
SYSTEM_MODE=false
UNINSTALL_MODE=false

for arg in "$@"; do
    case "$arg" in
        --system|-s)
            SYSTEM_MODE=true
            ;;
        --uninstall|-u)
            UNINSTALL_MODE=true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --system, -s     Install system-wide to /usr/local/bin (requires sudo)"
            echo "  --uninstall, -u  Remove installed files and commands"
            echo "  --help, -h       Show this help message"
            exit 0
            ;;
        *)
            echo "${RED}Unknown option: $arg${NORMAL}"
            echo "Use '$0 --help' for available options."
            exit 1
            ;;
    esac
done

# If executed by root directly, switch to system mode
if [ "$EUID" -eq 0 ]; then
    SYSTEM_MODE=true
fi

if [ "$SYSTEM_MODE" = true ]; then
    BIN_DIR="/usr/local/bin"
    LIB_DIR="/usr/local/lib/protondrive-cli-sync"
else
    BIN_DIR="${HOME}/.local/bin"
    LIB_DIR="${HOME}/.local/lib/protondrive-cli-sync"
fi

# ==============================================================================
# UNINSTALLATION
# ==============================================================================
if [ "$UNINSTALL_MODE" = true ]; then
    echo "${BOLD}==> Uninstalling Proton Drive CLI Sync Suite...${NORMAL}"
    rm -f "${BIN_DIR}/protondrive-sync"
    rm -f "${BIN_DIR}/protondrive-check-auth"
    rm -rf "${LIB_DIR}"
    echo "${GREEN}✓ Successfully uninstalled from ${BIN_DIR}.${NORMAL}"
    exit 0
fi

# ==============================================================================
# INSTALLATION
# ==============================================================================
echo "${BOLD}======================================================${NORMAL}"
echo "${BOLD}   Proton Drive CLI Sync Suite Installer              ${NORMAL}"
echo "${BOLD}======================================================${NORMAL}"
echo "Target directory : ${BIN_DIR}"
echo "Library directory: ${LIB_DIR}"
echo ""

# 1. Check Python 3 (unless standalone binary is present)
STANDALONE_BIN="${SCRIPT_DIR}/dist/protondrive-sync"
HAS_STANDALONE=false
if [ -f "$STANDALONE_BIN" ] && [ -x "$STANDALONE_BIN" ]; then
    HAS_STANDALONE=true
fi

if ! command -v python3 &>/dev/null; then
    if [ "$HAS_STANDALONE" = true ]; then
        echo "${YELLOW}Notice: python3 not found, but standalone binary detected. Proceeding without Python...${NORMAL}"
    else
        echo "${YELLOW}python3 is not installed.${NORMAL}"
        echo "Attempting to install Python 3 via system package manager..."

        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y python3
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm python
        elif command -v zypper &>/dev/null; then
            sudo zypper install -y python3
        elif command -v apk &>/dev/null; then
            sudo apk add --no-cache python3
        else
            echo "${RED}[ERROR] Could not detect package manager. Please install Python 3 manually.${NORMAL}"
            exit 1
        fi
    fi
fi

# 2. Create Target Directories
mkdir -p "${BIN_DIR}"
mkdir -p "${LIB_DIR}"

# 3. Install Files
if [ "$HAS_STANDALONE" = true ]; then
    echo "==> Installing standalone binary to ${BIN_DIR}/protondrive-sync..."
    cp -f "${STANDALONE_BIN}" "${BIN_DIR}/protondrive-sync"
    chmod +x "${BIN_DIR}/protondrive-sync"
else
    echo "==> Installing script suite to ${LIB_DIR}..."
    cp -f "${SCRIPT_DIR}/sync_protondrive.py" "${LIB_DIR}/sync_protondrive.py"
    cp -f "${SCRIPT_DIR}/sync_protondrive.sh" "${LIB_DIR}/sync_protondrive.sh"
    chmod +x "${LIB_DIR}/sync_protondrive.sh"

    # Create wrapper in BIN_DIR
    cat << 'WRAPPER' > "${BIN_DIR}/protondrive-sync"
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Look in corresponding lib dir
if [ -f "/usr/local/lib/protondrive-cli-sync/sync_protondrive.sh" ]; then
    exec "/usr/local/lib/protondrive-cli-sync/sync_protondrive.sh" "$@"
else
    exec "${HOME}/.local/lib/protondrive-cli-sync/sync_protondrive.sh" "$@"
fi
WRAPPER
    chmod +x "${BIN_DIR}/protondrive-sync"
fi

# Always install check_protondrive_auth.sh
cp -f "${SCRIPT_DIR}/check_protondrive_auth.sh" "${LIB_DIR}/check_protondrive_auth.sh"
chmod +x "${LIB_DIR}/check_protondrive_auth.sh"

cat << 'WRAPPER' > "${BIN_DIR}/protondrive-check-auth"
#!/usr/bin/env bash
if [ -f "/usr/local/lib/protondrive-cli-sync/check_protondrive_auth.sh" ]; then
    exec "/usr/local/lib/protondrive-cli-sync/check_protondrive_auth.sh" "$@"
else
    exec "${HOME}/.local/lib/protondrive-cli-sync/check_protondrive_auth.sh" "$@"
fi
WRAPPER
chmod +x "${BIN_DIR}/protondrive-check-auth"

echo "${GREEN}✓ Successfully installed:${NORMAL}"
echo "  - ${BIN_DIR}/protondrive-sync"
echo "  - ${BIN_DIR}/protondrive-check-auth"
echo ""

# 4. Check PATH
if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    echo "${YELLOW}Note: '${BIN_DIR}' is not currently in your PATH.${NORMAL}"
    echo "Add the following line to your ~/.bashrc or ~/.profile:"
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
    echo ""
fi

# 5. Check / Install official Proton Drive CLI binary
if command -v proton-drive &>/dev/null; then
    echo "${GREEN}✓ Official Proton Drive CLI is detected in PATH.${NORMAL}"
else
    found_local=""
    for p in "${HOME}/Downloads/"proton-drive*; do
        if [ -x "$p" ]; then
            found_local="$p"
            break
        fi
    done

    if [ -n "$found_local" ]; then
        echo "Found local Proton Drive CLI in Downloads: $found_local"
        echo "Copying to ${BIN_DIR}/proton-drive..."
        cp -f "$found_local" "${BIN_DIR}/proton-drive"
        chmod +x "${BIN_DIR}/proton-drive"
        echo "${GREEN}✓ Installed Proton Drive CLI to ${BIN_DIR}/proton-drive${NORMAL}"
    else
        echo "${YELLOW}Notice: Official Proton Drive CLI (proton-drive) was not found.${NORMAL}"
        auto_dl=""
        if [ -t 0 ]; then
            printf "Would you like to automatically download the official Proton Drive CLI binary now? [Y/n] "
            read -r auto_dl || auto_dl="y"
        else
            auto_dl="y"
        fi

        if [[ "$auto_dl" =~ ^[Yy]?$ ]]; then
            ARCH=$(uname -m)
            if [ "$ARCH" = "x86_64" ]; then
                DL_ARCH="linux-x64"
            elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
                DL_ARCH="linux-arm64"
            else
                DL_ARCH="linux-x64"
            fi

            LATEST_VER=$(curl -sL https://proton.me/download/drive/cli/index.html 2>/dev/null | grep -Eo "download/drive/cli/[0-9.]+" | head -n 1 | cut -d/ -f4 || echo "0.9.0")
            LATEST_VER="${LATEST_VER:-0.9.0}"
            DL_URL="https://proton.me/download/drive/cli/${LATEST_VER}/${DL_ARCH}/proton-drive"

            echo "Downloading official Proton Drive CLI (${LATEST_VER} for ${DL_ARCH})..."
            if curl -fSL --progress-bar "$DL_URL" -o "${BIN_DIR}/proton-drive"; then
                chmod +x "${BIN_DIR}/proton-drive"
                echo "${GREEN}✓ Proton Drive CLI successfully downloaded to ${BIN_DIR}/proton-drive${NORMAL}"
            else
                echo "${RED}Download failed. Please download manually.${NORMAL}"
                echo "  Official Downloads: https://proton.me/download/drive/cli/index.html"
                echo "  Documentation:      https://proton.me/support/drive-cli"
                echo "  Announcement:       https://proton.me/blog/proton-drive-cli"
            fi
        else
            echo "Official Proton Drive CLI can be downloaded manually from:"
            echo "  Downloads:     https://proton.me/download/drive/cli/index.html"
            echo "  Support Guide: https://proton.me/support/drive-cli"
            echo "  Announcement:  https://proton.me/blog/proton-drive-cli"
        fi
        echo ""
    fi
fi
echo "${BOLD}Setup complete! Try running:${NORMAL}"
echo "  protondrive-sync --help"
