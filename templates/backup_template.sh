#!/usr/bin/env bash
# ==============================================================================
# backup_template.sh
#
# Generic Multi-Tier System & Data Backup Template for Linux (Ubuntu/Debian)
# Combines:
#   1. System Package State Export (apt-clone, apt list, snap list)
#   2. Selective IDE / Application Config Symlink Directory (JetBrains / Android Studio)
#   3. Primary Local Backup to External Drive via rsync (differential)
#   4. Differential Cloud Sync to Proton Drive via sync_protondrive.sh
#
# Usage:
#   sudo ./backup_template.sh
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Configuration (Adapt paths to your environment)
# ------------------------------------------------------------------------------
if [ "$EUID" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-$USER}"
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
else
    TARGET_USER="$USER"
    TARGET_HOME="$HOME"
fi

UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
SYSTEM_ROLE="${SYSTEM_ROLE:-main}" # e.g. 'main' or 'test' for dual-boot setups

EXTERNAL_DRIVE="/mnt/backup_drive"
RSYNC_DEST="${EXTERNAL_DRIVE}/system_backup_${SYSTEM_ROLE}_ubuntu.${UBUNTU_VER}"

DATA_DIR="/data"
SYS_SETTINGS_DIR="${TARGET_HOME}/systemsettings"
IDE_LINKS_DIR="${TARGET_HOME}/backup_links/jetbrains_config"

PROTONDRIVE_CLI="${PROTONDRIVE_CLI:-${TARGET_HOME}/Downloads/proton-drive_0.9.0}"
PROTONDRIVE_SYNC_DIR="${PROTONDRIVE_SYNC_DIR:-${TARGET_HOME}/scripts/protondriveCliSync}"

run_as_user() {
    if [ "$EUID" -eq 0 ]; then
        local u_uid
        u_uid=$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)
        sudo -u "$TARGET_USER" -H env \
            DISPLAY="${DISPLAY:-:0}" \
            DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$u_uid/bus}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$u_uid}" \
            "$@"
    else
        "$@"
    fi
}

# ------------------------------------------------------------------------------
# 2. Export System Package State (apt-clone, apt, snap)
# ------------------------------------------------------------------------------
echo "==> Exporting APT & Snap package state to ${SYS_SETTINGS_DIR}..."
mkdir -p "$SYS_SETTINGS_DIR"

if command -v apt-clone >/dev/null 2>&1; then
    apt-clone clone "${SYS_SETTINGS_DIR}/apt-clone-state-${SYSTEM_ROLE}_ubuntu.${UBUNTU_VER}.tar.gz"
fi
apt list --installed > "${SYS_SETTINGS_DIR}/apt_installed.${SYSTEM_ROLE}.${UBUNTU_VER}.txt" 2>/dev/null
if command -v snap >/dev/null 2>&1; then
    snap list | awk '!/disabled/ && NR>1 {print $1}' > "${SYS_SETTINGS_DIR}/snap_installed.${SYSTEM_ROLE}.${UBUNTU_VER}.txt"
fi
chown -R "$TARGET_USER:$TARGET_USER" "$SYS_SETTINGS_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 3. Refresh IDE Config Symlinks (IntelliJ IDEA & Android Studio)
# ------------------------------------------------------------------------------
sync_ide_config_links() {
    local src_dir="$1"
    local dst_dir="$2"
    mkdir -p "$dst_dir"

    for item in "$src_dir"/*; do
        [ -e "$item" ] || continue
        local name
        name=$(basename "$item")
        # Skip transient runtime/lock/cache files inside the IDE config dir
        case "$name" in
            event-log-metadata|tasks|app-internal-state.db*|updatedBrokenPlugins.db*|.lock|port|port.lock|aia-task-history|ssl|migration|grazie)
                continue
                ;;
        esac
        ln -sfn "$item" "$dst_dir/$name"
    done
    chown -R -h "$TARGET_USER:$TARGET_USER" "$dst_dir" 2>/dev/null || true
}

echo "==> Updating IDE configuration symlinks in ${IDE_LINKS_DIR}..."
latest_idea=$(ls -1d "${TARGET_HOME}"/.config/JetBrains/IntelliJIdea* 2>/dev/null | sort -V | tail -n 1 || true)
[ -n "$latest_idea" ] && sync_ide_config_links "$latest_idea" "${IDE_LINKS_DIR}/IntelliJIdea"

latest_studio=$(ls -1d "${TARGET_HOME}"/.config/Google/AndroidStudio* 2>/dev/null | sort -V | tail -n 1 || true)
[ -n "$latest_studio" ] && sync_ide_config_links "$latest_studio" "${IDE_LINKS_DIR}/AndroidStudio"

# ------------------------------------------------------------------------------
# 4. Primary Backup to External Drive via rsync
# ------------------------------------------------------------------------------
if mountpoint -q "$EXTERNAL_DRIVE"; then
    echo "==> Running primary rsync backup to ${RSYNC_DEST}..."
    TRANSFER_LOG="/tmp/backup_rsync_transferred.txt"
    rm -f "$TRANSFER_LOG"

    rsync -vrlpEAXogth --inplace --numeric-ids \
        --exclude="*.iso" \
        --exclude="*.cache" \
        --exclude="node_modules" \
        --exclude="swap.img" \
        --exclude="/proc" \
        --exclude="/sys" \
        --exclude="/dev" \
        --exclude="/run" \
        --exclude="/tmp" \
        --exclude="/mnt" \
        --exclude="/media" \
        --exclude="/var" \
        --exclude="/usr" \
        --exclude="/lib*" \
        --exclude="/bin" \
        --exclude="/sbin" \
        --exclude="/snap" \
        --exclude="${EXTERNAL_DRIVE}" \
        --exclude="${TARGET_HOME}/.cache" \
        --exclude="${TARGET_HOME}/snap" \
        --exclude="${TARGET_HOME}/.gradle" \
        --exclude="${TARGET_HOME}/.android" \
        --exclude="${TARGET_HOME}/.local/share/JetBrains" \
        --exclude="${TARGET_HOME}/.local/share/Google" \
        --exclude="${TARGET_HOME}/.config/JetBrains" \
        --exclude="${TARGET_HOME}/.config/Google" \
        --exclude="${IDE_LINKS_DIR}" \
        --delete --delete-excluded \
        / "$RSYNC_DEST" | tee "$TRANSFER_LOG"

    # Sync dereferenced IDE configuration files (-L) to external drive
    rsync -vrlpEAXogthL --inplace --numeric-ids --delete \
        "$IDE_LINKS_DIR" "$EXTERNAL_DRIVE/" | tee -a "$TRANSFER_LOG"
else
    echo "WARNING: External drive ${EXTERNAL_DRIVE} is not mounted. Skipping local rsync."
fi

# ------------------------------------------------------------------------------
# 5. Differential Cloud Sync to Proton Drive
# ------------------------------------------------------------------------------
echo "==> Verifying Proton Drive authentication..."
if run_as_user "${PROTONDRIVE_SYNC_DIR}/check_protondrive_auth.sh" "$PROTONDRIVE_CLI"; then
    echo "==> Syncing directories to Proton Drive..."

    # 1. System settings & package lists (follow symlinks with -L)
    run_as_user "${PROTONDRIVE_SYNC_DIR}/sync_protondrive.sh" \
        "$PROTONDRIVE_CLI" "$SYS_SETTINGS_DIR" "systemsettings" -L

    # 2. IDE configurations (follow symlinks with -L)
    run_as_user "${PROTONDRIVE_SYNC_DIR}/sync_protondrive.sh" \
        "$PROTONDRIVE_CLI" "$IDE_LINKS_DIR" "jetbrains_config" -L

    # 3. User scripts (translate symlinks to .rclonelink with -l)
    [ -d "${TARGET_HOME}/scripts" ] && run_as_user "${PROTONDRIVE_SYNC_DIR}/sync_protondrive.sh" \
        "$PROTONDRIVE_CLI" "${TARGET_HOME}/scripts" "scripts" -l

    # 4. Example: CameraUploads without version history (--no-history)
    [ -d "${DATA_DIR}/CameraUploads" ] && run_as_user "${PROTONDRIVE_SYNC_DIR}/sync_protondrive.sh" \
        "$PROTONDRIVE_CLI" "${DATA_DIR}/CameraUploads" "CameraUploads" -l --no-history

    # 5. Example: Development project with workspace build/cache exclusions
    [ -d "${TARGET_HOME}/workspace/MyProject" ] && run_as_user "${PROTONDRIVE_SYNC_DIR}/sync_protondrive.sh" \
        "$PROTONDRIVE_CLI" "${TARGET_HOME}/workspace/MyProject" "MyProject" -l --workspace-excludes
fi

echo "==> Backup completed."

