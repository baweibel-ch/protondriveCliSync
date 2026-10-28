# 📦 Installation Guide: Proton Drive CLI Sync Suite

This guide explains how to install and set up `protondriveCliSync` on your Linux machine.

---

## 🔑 1. Download & Install Proton Drive CLI (Prerequisite)

`protondriveCliSync` acts as the differential synchronization engine on top of the **official Proton Drive CLI**. You need the official executable.

### Official Proton Resources:
* 📥 **Official Download Index:** [https://proton.me/download/drive/cli/index.html](https://proton.me/download/drive/cli/index.html)
* 📖 **Official Support & Setup Guide:** [https://proton.me/support/drive-cli](https://proton.me/support/drive-cli)
* 📰 **Official Announcement Blog:** [https://proton.me/blog/proton-drive-cli](https://proton.me/blog/proton-drive-cli)

### Quick Terminal Download (One-Liner):

Choose your system architecture and run:

#### Linux x86_64 (Standard 64-bit PC / Intel / AMD):
```bash
mkdir -p ~/.local/bin
curl -fSL https://proton.me/download/drive/cli/0.9.0/linux-x64/proton-drive -o ~/.local/bin/proton-drive
chmod +x ~/.local/bin/proton-drive
```

#### Linux ARM64 (Raspberry Pi / ARM Servers):
```bash
mkdir -p ~/.local/bin
curl -fSL https://proton.me/download/drive/cli/0.9.0/linux-arm64/proton-drive -o ~/.local/bin/proton-drive
chmod +x ~/.local/bin/proton-drive
```

#### Verify & Initial Login:
```bash
proton-drive --help
proton-drive auth login
```
*(This opens your browser to authenticate with Proton Drive. Keep your terminal open until complete).*

---

## 🚀 2. Install Proton Drive CLI Sync Suite

You can choose between two installation methods:

| Method | Best For | Python Needed? | Command |
| :--- | :--- | :---: | :--- |
| **Method 1: Installer Script** | Most users, developers | Yes (auto-installed if missing) | `./install.sh` |
| **Method 2: Standalone Binary** | Minimal setups, servers | **No** (self-contained) | Download or `./build_binary.sh` |

---

### Method 1: Script Suite Installation via `install.sh` (Recommended)

Clone the repository and run the installer:

```bash
git clone https://github.com/baweibel-ch/protondriveCliSync.git
cd protondriveCliSync
```

#### Option A: User Installation (Recommended, no root/sudo needed)
Installs wrappers to `~/.local/bin` and libraries to `~/.local/lib/protondrive-cli-sync`:

```bash
./install.sh
```

#### Option B: System-Wide Installation
Installs to `/usr/local/bin` and `/usr/local/lib/protondrive-cli-sync` for all system users:

```bash
sudo ./install.sh --system
```

#### What `install.sh` does automatically:
1. **Official CLI Integration:** If the official `proton-drive` binary is not yet in your `PATH`, it automatically offers to download and place it in your bin directory!
2. **Python Check:** Automatically checks if `python3` (>= 3.8) is available. If missing, it offers to install it via your system package manager (`apt`, `dnf`, `pacman`, `zypper`, `apk`).
3. **Commands Setup:** Creates `protondrive-sync` and `protondrive-check-auth` in your `PATH`.
4. **PATH Verification:** Verifies that your bin directory is active in `$PATH` and gives configuration hints if needed.

---

### Method 2: Standalone Binary (Zero Python Required)

If you do not want to install Python on your machine, you can use the pre-compiled standalone executable.

#### Option A: Download from GitHub Releases
1. Download `protondrive-sync` from the [GitHub Releases](https://github.com/baweibel-ch/protondriveCliSync/releases) page.
2. Make it executable and move it to your bin directory:
   ```bash
   chmod +x protondrive-sync
   mv protondrive-sync ~/.local/bin/
   ```

#### Option B: Build the Standalone Binary Yourself
If building from source:
```bash
./build_binary.sh
```
* Compiles `sync_protondrive.py` into a self-contained executable: `dist/protondrive-sync` (~8 MB).
* Embeds its own lightweight Python runtime.
* You can run `./install.sh`, and it will automatically detect and install this standalone binary directly into your `PATH`.

---

## ✅ 3. Verifying Installation

Verify that all tools are installed and working:

```bash
# Check sync engine help
protondrive-sync --help

# Check pre-flight authentication
protondrive-check-auth
```

---

## 💡 4. Ready-to-Use Backup Script Templates

Users can copy and adapt these example scripts for their automated backups.

### Example A: Standard User Backup (After running `./install.sh`)
Since `./install.sh` places `protondrive-sync` and `protondrive-check-auth` directly into your `PATH`, your backup script is minimal and clean:

```bash
#!/usr/bin/env bash
# ==============================================================================
# backup_daily.sh - Example user backup script
# ==============================================================================
set -euo pipefail

# Path to Proton Drive CLI executable
PROTONDRIVE_CLI="${HOME}/.local/bin/proton-drive"

echo "==> Using Proton Drive CLI: ${PROTONDRIVE_CLI}"
"$PROTONDRIVE_CLI" --version

# 1. Check/ensure authentication before running syncs
if ! protondrive-check-auth "$PROTONDRIVE_CLI"; then
    echo "Proton Drive authentication failed or cancelled. Aborting sync."
    exit 1
fi

# 2. Synchronize directories
echo "==> Syncing Documents..."
protondrive-sync "$PROTONDRIVE_CLI" ~/Documents Documents -l

echo "==> Syncing Projects (excluding build artifacts & git)..."
protondrive-sync "$PROTONDRIVE_CLI" ~/workspace/MyProject MyProject -l --workspace-excludes

echo "==> Syncing Downloads (without version history to save quota)..."
protondrive-sync "$PROTONDRIVE_CLI" ~/Downloads Downloads -l --no-history

echo "✓ All backup tasks completed successfully!"
```

---

### Example B: Sudo-Aware Backup Script (System / Sudo Backups)
If your backup script is run with `sudo` (e.g. combined with `rsync` of root partitions), this template ensures commands and authentication run under your desktop user session:

```bash
#!/usr/bin/env bash
# ==============================================================================
# backup.sh - Standalone & Sudo-Aware Backup Script Template
# ==============================================================================
set -euo pipefail

# Detect real user & home directory if executed with sudo
if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    TARGET_UID=$(id -u "$TARGET_USER")
    RUN_AS_USER="sudo -u $TARGET_USER -H env DISPLAY=${DISPLAY:-:1} XAUTHORITY=/run/user/$TARGET_UID/gdm/Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$TARGET_UID/bus XDG_RUNTIME_DIR=/run/user/$TARGET_UID"
else
    TARGET_USER="${USER:-$LOGNAME}"
    TARGET_HOME="$HOME"
    RUN_AS_USER=""
fi

# Paths
PROTONDRIVE_CLI="${TARGET_HOME}/.local/bin/proton-drive"
PROTONDRIVE_SYNC_DIR="${TARGET_HOME}/scripts/protondriveCliSync"

echo "Using PROTONDRIVE_CLI: $PROTONDRIVE_CLI"
$RUN_AS_USER "$PROTONDRIVE_CLI" --version

# 1. Check/ensure authentication before running syncs
if ! $RUN_AS_USER "$PROTONDRIVE_SYNC_DIR/check_protondrive_auth.sh" "$PROTONDRIVE_CLI"; then
    echo "Proton Drive authentication failed or cancelled. Aborting sync."
    exit 1
fi

# 2. Synchronize directories
echo "==> Synchronizing Documents..."
$RUN_AS_USER "$PROTONDRIVE_SYNC_DIR/sync_protondrive.sh" "$PROTONDRIVE_CLI" ~/Documents Documents -l

echo "✓ Backup finished!"
```

---

## 🗑️ 5. Uninstallation

To cleanly remove all installed files and command wrappers:

```bash
# For user installation:
./install.sh --uninstall

# For system-wide installation:
sudo ./install.sh --uninstall
```
