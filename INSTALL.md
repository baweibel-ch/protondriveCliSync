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

## 🗑️ Uninstallation

To cleanly remove all installed files and command wrappers:

```bash
# For user installation:
./install.sh --uninstall

# For system-wide installation:
sudo ./install.sh --uninstall
```
