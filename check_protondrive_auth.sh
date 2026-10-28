#!/usr/bin/env bash
# ==============================================================================
# check_protondrive_auth.sh
#
# Checks if the Proton Drive CLI is logged in.
# If NOT logged in:
#   Prompts and runs 'auth login' (opens browser for authentication).
#
# Robust against post-reboot delays: uses timeout on checks to prevent hanging.
#
# Return codes:
#   0 : Authenticated successfully (safe to proceed with sync scripts)
#   1 : Authentication failed or CLI not found (calling scripts should abort)
#
# Usage in terminal:
#   ~/scripts/protondriveCliSync/check_protondrive_auth.sh [path_to_protondrive_cli]
# ==============================================================================

set -uo pipefail

CLI="${1:-}"

# If no CLI path passed, try default locations or PATH
if [[ -z "$CLI" ]]; then
    if [[ -x "$HOME/Downloads/proton-drive_0.9.0" ]]; then
        CLI="$HOME/Downloads/proton-drive_0.9.0"
    elif command -v proton-drive &>/dev/null; then
        CLI=$(command -v proton-drive)
    else
        echo "[ERROR] Proton Drive CLI binary not specified and not found in default locations."
        echo "Usage: $0 <path_to_protondrive_cli>"
        exit 1
    fi
fi

# Expand tilde or relative paths
CLI=$(realpath "$CLI" 2>/dev/null || echo "$CLI")

if [[ ! -x "$CLI" ]]; then
    echo "[ERROR] CLI binary not found or not executable: $CLI"
    exit 1
fi

# Function to test whether the session is currently authenticated with a timeout
is_logged_in() {
    local t="${1:-15}"
    # Use timeout to avoid hanging after reboot if network/VPN is initializing
    if command -v timeout &>/dev/null; then
        timeout "$t" "$CLI" filesystem list / &>/dev/null
    else
        "$CLI" filesystem list / &>/dev/null
    fi
}

echo "==> Checking Proton Drive login status..."

if is_logged_in 15; then
    echo "✓ Proton Drive CLI is already logged in."
    exit 0
fi

# In case it timed out during system boot/network connection, try one more time
echo "Notice: Quick login check failed or timed out. Retrying with 20s timeout..."
if is_logged_in 20; then
    echo "✓ Proton Drive CLI is logged in."
    exit 0
fi

# Not logged in: prompt to authenticate
echo "⚠ Proton Drive CLI is NOT logged in."
echo "==> Starting authentication process ('$CLI auth login')..."
echo "    (A browser window will open. Keep this terminal open until complete.)"
echo ""

# Run auth login directly (interactive)
if ! "$CLI" auth login; then
    echo ""
    echo "[ERROR] Authentication command exited with an error."
    exit 1
fi

echo ""
echo "==> Verifying new login session..."

# Verify if authentication succeeded
if is_logged_in 20; then
    echo "✓ Authentication successful! Returning 0 to continue."
    exit 0
else
    echo "[ERROR] Authentication check failed after login attempt."
    exit 1
fi
