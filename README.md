# 🚀 Proton Drive CLI Sync Suite

High-performance, one-way differential synchronization from local Linux directories to **Proton Drive** using the official Proton Drive CLI.

Designed as a modern, reliable replacement for `rclone` with support for symlinks, exclusion rules, deletion synchronization, version history control, and instantaneous differential runs via snapshot caching.

---

## 🌟 Key Features & Architecture

* **🛡️ Absolute Local Safety (Strictly Read-Only):**
  Never deletes, overwrites, renames, or touches any local file or directory. All synchronization is strictly one-way (`Local -> Cloud`).
* **⚡ High-Performance Differential Snapshot Sync:**
  * Caches local tree state in `~/.cache/protondrive_sync/<remote_folder>.json`.
  * Fully compatible with legacy `last_put_to_protondrive` snapshot files.
  * Checks `(size, mtime, link_target)`. If nothing changed locally, **sync finishes in < 1 second** with **zero cloud uploads and zero remote listing delays**.
  * Only uploads modified or newly added files.
* **🔒 Non-Blocking Authentication with Auto-Login:**
  * Employs timeout probes (15s/20s) to prevent hanging during post-reboot network/VPN connection delays.
  * If unauthenticated or session expired, automatically prints a notice and launches `auth login` interactively in the terminal (opening the browser).
* **🗑️ Smart Cloud Purging for Ignored / Excluded Items:**
  * Excluded items (e.g. `.tresorit`, `.gradle`, `build`, `*.log`, `node_modules`) are **ALWAYS permanently purged** from Proton Drive (never left in trash / version history), even when the rest of the sync runs with history.
  * Ordinary deleted files respect the `--no-history` flag (retained in cloud trash by default; permanently purged if `--no-history` is specified).
  * Automatically collapses redundant child deletions when an entire directory (like `build` or `.gradle`) is deleted.
* **🔗 Symlink Compatibility:**
  * `-l` (`--links`): Translates symlinks into `.rclonelink` text files (identical to `rclone -l`).
  * `-L` (`--copy-links`): Follows symlinks and uploads the real content (identical to `rclone -L`).
* **🕒 History & Trash Control (`--no-history`):**
  * With history (default): Uses `--file-conflict-strategy create-new-revision`, and deleted files are moved to `/trash/`.
  * `--no-history` (`-nh`): Uses `--file-conflict-strategy replace`, and deleted files are purged permanently.

---

## 📁 Repository Structure

```
protondriveCliSync/
├── install.sh                 # Universal installer (User or System mode)
├── build_binary.sh            # One-click standalone binary builder (PyInstaller)
├── sync_protondrive.sh        # Main Bash entry point (propagates all CLI flags)
├── sync_protondrive.py        # Core differential synchronization engine
├── check_protondrive_auth.sh  # Pre-flight authentication checker with timeout & auto-login
├── README.md                  # Main suite documentation & CLI reference
├── INSTALL.md                 # Complete installation guide & binary downloads
├── templates/
│   ├── backup_template.sh     # Ready-to-use multi-tier backup template (apt-clone, rsync, Proton Drive)
│   └── restore_template.sh    # Ready-to-use system & cloud restore template (with safe --dry-run default)
└── .gitignore                 # Git ignore rules
```

---

## 📦 Installation

For step-by-step setup guides, package manager details, and standalone binary downloads, please see **[INSTALL.md](INSTALL.md)**.

---

## 🔐 Pre-Flight Authentication Check (`check_protondrive_auth.sh`)

Checks if Proton Drive CLI is logged in. If not, it interactively executes `auth login`.

```bash
~/scripts/protondriveCliSync/check_protondrive_auth.sh [path_to_protondrive_cli]
```

### Usage in Calling Scripts:
```bash
PROTONDRIVE_CLI=~/Downloads/proton-drive_0.9.0
"$PROTONDRIVE_CLI" --version

if ! ~/scripts/protondriveCliSync/check_protondrive_auth.sh "$PROTONDRIVE_CLI"; then
    echo "Proton Drive authentication failed. Aborting sync."
    exit 1
fi
```
*(Note: `sync_protondrive.py` also contains built-in authentication verification, so standalone calls are always protected).*

---

## 🚀 Sync Script Usage (`sync_protondrive.sh`)

### Syntax
```bash
~/scripts/protondriveCliSync/sync_protondrive.sh <cli_binary> <local_folder> <remote_folder> [OPTIONS]
```

### Positional Arguments (Required)

| Parameter | Description | Examples |
| :--- | :--- | :--- |
| **`$1` : CLI Binary** | Path to the `proton-drive` executable | `~/Downloads/proton-drive_0.9.0`<br>`/usr/local/bin/proton-drive` |
| **`$2` : Local Folder** | Directory to synchronize (**strictly read-only**) | `/scripts`<br>`/data/CameraUploads`<br>`~/workspace/Projekt` |
| **`$3` : Remote Folder** | Target directory on Proton Drive (mapped to `/my-files/<folder>`) | `rootscripts`<br>`CameraUploads`<br>`Projekt` |

---

### Command-Line Options & Flags

| Flag | Shorthand | Default | Description |
| :--- | :---: | :---: | :--- |
| **`--links`** | `-l` | *Off* | **Translate symlinks** *(like `rclone -l`)*:<br>Uploads symlinks as `.rclonelink` text files containing the link target. Preserves original symlink timestamps. |
| **`--copy-links`** | `-L` | *Off* | **Follow symlinks** *(like `rclone -L`)*:<br>Resolves symlinks and uploads the pointed-to real file or directory contents. |
| *(None)* | — | **Default** | **Safe skip**:<br>Symlinks are omitted so Proton Drive CLI does not crash with validation errors. |
| **`--exclude PATTERN`** | `-e` | `['.tresorit']` | **Exclude files/directories**:<br>• Matches are skipped during local upload.<br>• If an excluded item exists on Proton Drive, it is **permanently purged** (no trash/history).<br>• Can be repeated multiple times. Supports wildcards (`*.log`) and directory names (`.gradle`, `build`). |
| **`--workspace-excludes`** | `-w` *(or `--workspace`)* | *Off* | **IntelliJ / Gradle / Android Project Exclusions**:<br>• Excludes and permanently purges project/build artifacts: `.git`, `.tresorit`, `.gradle`, `build`, `target`, `out`, `node_modules`, `dist`, `venv`, `.cxx`, `.externalNativeBuild`, `*.log`, `*.hprof`, and hex-only named dump/hash files.<br>• **Retains `workspace.xml`** (not excluded).<br>• Can be combined with additional `-e` flags.<br>• **Explicit parameter**: Never applied automatically just by directory path (e.g. `~/workspace/`). |
| **`--no-history`** | `-nh` | *Off* | **Disable version history & trash retention**:<br>• **Uploads:** Uses `--file-conflict-strategy replace` instead of `create-new-revision`.<br>• **Deletions:** Permanently purges items from `/trash/`.<br>*(Can also be set globally via `export PROTONDRIVE_NO_HISTORY=true`)*. |
| **`--dry-run`** | `-n` | *Off* | **Simulation mode**:<br>Displays what would be uploaded or permanently purged without making cloud modifications. |
| **`--rescan-remote`** | — | *Off* | **Full Remote Crawl**:<br>Forces a parallel multi-threaded scan of the remote Proton Drive folder to reconcile cloud state with the local snapshot. |
| **`--save-filelist`** | — | *Off* | Also writes a sorted `last_put_to_protondrive` plaintext list into the local directory (if writable). |

---

## 🗑️ Deletion Rules (Normal Files vs. Ignored Items)

| Item Type | Sync with History (Default) | Sync with `--no-history` (`-nh`) |
| :--- | :--- | :--- |
| **Ordinary deleted file** | Moved to cloud trash (`filesystem trash <path>`). Recoverable in Proton Drive Trash. | Permanently purged (`filesystem trash` + `filesystem delete /trash/<name>`). |
| **Ignored / Excluded item** *(e.g. `.tresorit`, `.gradle`, `build`, `*.log`, `node_modules`)* | **Permanently purged** (never stored in trash; leaves no trace in quota). | **Permanently purged** (never stored in trash; leaves no trace in quota). |

---

## 📋 Synchronization Workflow

```
[Local Machine] (Strictly Read-Only)              [Proton Drive Cloud Storage]
       │                                                      │
       ├─ Pre-flight: Auth Verification ─────────────────────>│ Probes session with timeout (15s/20s)
       │                                                      │ (triggers interactive 'auth login' if needed)
       │                                                      │
       ├─ Step 0: Directory Check ───────────────────────────>│ Ensures /my-files/<target> exists
       │                                                      │
       ├─ Local Scan & Differential Compare ──────────────────>│ Scans local tree (0.02s - 0.1s)
       │                                                      │ Compares (size, mtime) against snapshot
       │                                                      │
       ├─ Step 1: Targeted Deletions ─────────────────────────>│ Deletes ONLY removed files
       │                                                      │ (Ignored items: permanently purged)
       │                                                      │ (0 API calls if nothing was deleted!)
       │                                                      │
       └─ Step 2: Upload Modified/New Only ───────────────────>│ Stages ONLY changed files
                                                              │ Uploads with replace or create-new-revision
                                                              │ (Skipped completely if 0 changes!)
```

---

## 💡 Practical Examples

### 1. Differential Backup of Scripts
```bash
~/scripts/protondriveCliSync/sync_protondrive.sh "$PROTONDRIVE_CLI" /scripts rootscripts -l
```

### 2. Large Directory Sync without History (`CameraUploads`)
```bash
~/scripts/protondriveCliSync/sync_protondrive.sh "$PROTONDRIVE_CLI" /data/CameraUploads CameraUploads -l --no-history
```

### 3. IntelliJ Project with Workspace Excludes
Pass `--workspace-excludes` (or `-w`) as an explicit parameter to exclude standard build, cache, and log files without declaring external arrays:
```bash
~/scripts/protondriveCliSync/sync_protondrive.sh "$PROTONDRIVE_CLI" ~/workspace/Projekt Projekt -l --workspace-excludes
```
*(Workspace exclusions are strictly parameter-driven and not triggered automatically by path. Build artifacts, caches, and logs are permanently purged from cloud trash to save quota, while source code retains version history).*

---

## 🔄 Complete Backup & System Restore Guide (Best Practices)

When combining `protondriveCliSync` with local backups (`rsync`), package state snapshots (`apt-clone` / `snap`), and optional cloud sync clients (`tresorit-cli`), you can build a complete, multi-tiered Linux backup and disaster recovery workflow.

> 💡 **Ready-to-Use Templates:** Complete, customizable scripts implementing the workflows below are included in [`templates/backup_template.sh`](templates/backup_template.sh) and [`templates/restore_template.sh`](templates/restore_template.sh).

### 1. Exporting System Package State Before Backup (`apt-clone` & `snap`)

Backing up `/usr`, `/lib`, or `/snap` directly is inefficient and difficult to restore cleanly across OS installations. Instead, export lightweight package state snapshots into a `systemsettings/` directory and sync that folder to Proton Drive:

```bash
SYS_DIR=~/systemsettings
mkdir -p "$SYS_DIR"
UBUNTU_VER=$(lsb_release -rs)

# 1. Full APT state (installed packages, PPAs, and sources.list)
sudo apt-clone clone "$SYS_DIR/apt-clone-state-ubuntu.${UBUNTU_VER}.tar.gz"
sudo chown "$USER:$USER" "$SYS_DIR/apt-clone-state-ubuntu.${UBUNTU_VER}.tar.gz"

# 2. Plaintext package & snap lists (for diffing or selective reinstallation)
apt list --installed > "$SYS_DIR/apt_installed.${UBUNTU_VER}.txt"
snap list | awk '!/disabled/ && NR>1 {print $1}' > "$SYS_DIR/snap_installed.${UBUNTU_VER}.txt"

# 3. Sync systemsettings to Proton Drive (following symlinks with -L if extra configs are linked)
~/scripts/protondriveCliSync/sync_protondrive.sh "$PROTONDRIVE_CLI" "$SYS_DIR" systemsettings -L
```

### 2. Selective Application Configs via Symlink Directories (`-L` / `--copy-links`)

Large IDE directories (such as `~/.config/JetBrains`, `~/.local/share/JetBrains`, or `~/.config/Google`) often contain gigabytes of caches, bundled runtimes, and indices alongside a few megabytes of critical user settings (`options/`, `keymaps/`, `codestyles/`, `tools/`).

By creating a dedicated link directory pointing only to the essential configuration subdirectories, you can back up and sync them cleanly using `-L` (`--copy-links`):

```bash
mkdir -p ~/backup_links/ide_config/IntelliJIdea
LATEST_IDEA=$(ls -1d ~/.config/JetBrains/IntelliJIdea* 2>/dev/null | sort -V | tail -n 1)

for item in options keymaps codestyles templates tools idea64.vmoptions disabled_plugins.txt; do
    [ -e "$LATEST_IDEA/$item" ] && ln -sfn "$LATEST_IDEA/$item" ~/backup_links/ide_config/IntelliJIdea/"$item"
done

# Upload dereferenced config files to Proton Drive:
~/scripts/protondriveCliSync/sync_protondrive.sh "$PROTONDRIVE_CLI" ~/backup_links/ide_config ide_config -L
```

---

### 3. Restoring a Fresh System (Step-by-Step Draft / Template)

Always test recovery scripts in **dry-run mode (`-n`)** first before executing changes on a target machine.

#### Phase A: Restore APT & Snap Packages (`apt-clone` & `snap`)
```bash
SYS_DIR=~/systemsettings
UBUNTU_VER=$(lsb_release -rs)

# 1. Restore APT sources and packages via apt-clone
sudo apt update && sudo apt install -y apt-clone
sudo apt-clone restore "$SYS_DIR/apt-clone-state-ubuntu.${UBUNTU_VER}.tar.gz"

# 2. Reinstall Snaps from exported list
while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^(core.*|bare|snapd|gnome-.*|gtk-common-themes|mesa-.*)$ ]] && continue
    snap list "$pkg" >/dev/null 2>&1 || sudo snap install "$pkg"
done < "$SYS_DIR/snap_installed.${UBUNTU_VER}.txt"
```

#### Phase B: Restore from External Drive via `rsync` (Primary Fast Restore)
```bash
# Always run with -n (--dry-run) first to preview changes!
RSYNC_FLAGS=(-vrlpEAXogth --inplace --numeric-ids -n)
BACKUP_ROOT="/mnt/backup_drive/system_backup"

# Restore data and user home
rsync "${RSYNC_FLAGS[@]}" "$BACKUP_ROOT/home/$USER/" "$HOME/"

# Restore dereferenced IDE configs (-L) into the newly installed IDE config directory
LATEST_IDEA=$(ls -1d ~/.config/JetBrains/IntelliJIdea* 2>/dev/null | sort -V | tail -n 1)
[ -n "$LATEST_IDEA" ] && rsync "${RSYNC_FLAGS[@]}" -L "/mnt/backup_drive/ide_config/IntelliJIdea/" "$LATEST_IDEA/"
```

#### Phase C: Restore Directly from Proton Drive (Cloud Fallback)
When restoring from Proton Drive using the official CLI, download the remote folder and reconstruct any `.rclonelink` symlink files created by `-l` (`--links`):

```bash
PROTONDRIVE_CLI=~/Downloads/proton-drive_0.9.0

# 1. Ensure session is authenticated
~/scripts/protondriveCliSync/check_protondrive_auth.sh "$PROTONDRIVE_CLI"

# 2. Download remote folder from /my-files/<RemoteFolder> into local parent directory
#    -f skip  : Do not overwrite existing local files (use 'remove' to force overwrite)
#    -d merge : Merge into existing directory structure
"$PROTONDRIVE_CLI" filesystem download -f skip -d merge "/my-files/rootscripts" "$HOME"

# 3. Reconstruct symlinks from '.rclonelink' files (if synced with -l / --links)
find "$HOME/rootscripts" -type f -name "*.rclonelink" -print0 | while IFS= read -r -d '' link_file; do
    target_path="${link_file%.rclonelink}"
    link_target=$(cat "$link_file")
    if [ -n "$link_target" ]; then
        ln -sfn "$link_target" "$target_path" && rm -f "$link_file"
    fi
done
```

#### Phase D: Re-Attaching `tresorit-cli` Sync Directories (Optional)
If you also use Tresorit alongside Proton Drive, you can script re-linking all cloud tresors to their local directories on a new installation via `tresorit-cli`:

```bash
TRESORIT_CLI="$HOME/.local/share/tresorit/tresorit-cli"
"$TRESORIT_CLI" start
"$TRESORIT_CLI" status

# Map Tresor names (or IDs) to local paths:
declare -a TRESORS=(
    "My Scripts:$HOME/scripts"
    "System Settings:$HOME/systemsettings"
    "IDE Config:$HOME/backup_links/ide_config"
)

for entry in "${TRESORS[@]}"; do
    tresor_name="${entry%%:*}"
    local_path="${entry#*:}"
    mkdir -p "$local_path"
    "$TRESORIT_CLI" sync --start "$tresor_name" --path "$local_path"
done
```
