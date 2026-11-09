#!/usr/bin/env bash
# ==============================================================================
# restore_template.sh
#
# Generic Multi-Tier System & Data Restore Template for Linux (Ubuntu/Debian)
# Supports restoring from:
#   1. System Package State (apt-clone, apt list, snap list)
#   2. External Backup Drive via rsync (including dereferenced IDE configs)
#   3. Proton Drive Cloud Storage (via proton-drive CLI + .rclonelink reconstruction)
#   4. Tresorit Cloud Storage (via tresorit-cli sync --start)
#
# SAFETY: Runs in --dry-run mode by default! Pass --execute to apply changes.
#
# Usage:
#   ./restore_template.sh                        # Dry-run preview of all phases
#   ./restore_template.sh --source protondrive   # Dry-run Proton Drive restore only
#   ./restore_template.sh --execute              # Interactive execution
# ==============================================================================

set -euo pipefail

DRY_RUN=true
SYSTEM_ROLE="${SYSTEM_ROLE:-main}"
SRC_VER=$(lsb_release -rs 2>/dev/null || echo "24.04")
SOURCE_MODE="all" # all | systemsettings | drive | protondrive | tresorit

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -n, --dry-run                 Simulate and print commands only (DEFAULT)
  --execute                     Execute changes interactively after confirmation
  -r, --role <main|test>        System role of backup (default: $SYSTEM_ROLE)
  -v, --version <ver>           Ubuntu version of backup (default: $SRC_VER)
  -s, --source <mode>           Phase to run: all | systemsettings | drive | protondrive | tresorit
  -h, --help                    Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; shift ;;
        --execute)    DRY_RUN=false; shift ;;
        -r|--role)    SYSTEM_ROLE="${2:-main}"; shift 2 ;;
        -v|--version) SRC_VER="${2:-24.04}"; shift 2 ;;
        -s|--source)  SOURCE_MODE="${2:-all}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

EXTERNAL_DRIVE="/mnt/backup_drive"
RSYNC_SRC="${EXTERNAL_DRIVE}/system_backup_${SYSTEM_ROLE}_ubuntu.${SRC_VER}"
SYS_SETTINGS_DIR="${TARGET_HOME}/systemsettings"

PROTONDRIVE_CLI="${PROTONDRIVE_CLI:-${TARGET_HOME}/Downloads/proton-drive_0.9.0}"
PROTONDRIVE_SYNC_DIR="${PROTONDRIVE_SYNC_DIR:-${TARGET_HOME}/scripts/protondriveCliSync}"
TRESORIT_CLI="${TRESORIT_CLI:-${TARGET_HOME}/.local/share/tresorit/tresorit-cli}"

run_cmd() {
    local cmd_str
    printf -v cmd_str '%q ' "$@"
    if $DRY_RUN; then
        printf "  [DRY-RUN] %s\n" "${cmd_str% }"
    else
        printf "  [EXEC]    %s\n" "${cmd_str% }"
        "$@"
    fi
}

confirm_phase() {
    local title="$1"
    printf "\n==============================================================================\n"
    printf "%s\n" "$title"
    printf "==============================================================================\n"
    if $DRY_RUN; then
        return 0
    fi
    read -r -p "Proceed with this phase? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ------------------------------------------------------------------------------
# PHASE 1: Restore System Packages (apt-clone & snap)
# ------------------------------------------------------------------------------
restore_systemsettings() {
    confirm_phase "PHASE 1: Restore System Packages (apt-clone & snap)" || return 0

    local apt_clone_archive="${SYS_SETTINGS_DIR}/apt-clone-state-${SYSTEM_ROLE}_ubuntu.${SRC_VER}.tar.gz"
    local snap_list_file="${SYS_SETTINGS_DIR}/snap_installed.${SYSTEM_ROLE}.${SRC_VER}.txt"

    if [ -f "$apt_clone_archive" ]; then
        run_cmd sudo apt update
        run_cmd sudo apt install -y apt-clone
        run_cmd sudo apt-clone restore "$apt_clone_archive"
    else
        printf "  [INFO] No apt-clone archive found at: %s\n" "$apt_clone_archive"
    fi

    if [ -f "$snap_list_file" ]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" || "$pkg" =~ ^(Name|core.*|bare|snapd|gnome-.*|gtk-common-themes|mesa-.*)$ ]] && continue
            if ! snap list "$pkg" >/dev/null 2>&1; then
                run_cmd sudo snap install "$pkg"
            fi
        done < "$snap_list_file"
    else
        printf "  [INFO] No snap list found at: %s\n" "$snap_list_file"
    fi
}

# ------------------------------------------------------------------------------
# PHASE 2: Restore from External Drive via rsync
# ------------------------------------------------------------------------------
restore_from_drive() {
    confirm_phase "PHASE 2: Restore from External Drive (${RSYNC_SRC}) via rsync" || return 0

    local rsync_flags=(-vrlpEAXogth --inplace --numeric-ids)
    $DRY_RUN && rsync_flags+=(-n)

    # 1. Restore user home directory
    run_cmd rsync "${rsync_flags[@]}" "${RSYNC_SRC}${TARGET_HOME}/" "${TARGET_HOME}/"

    # 2. Restore dereferenced IDE configurations (-L) into latest installed IDE config dir
    local jb_backup="${EXTERNAL_DRIVE}/jetbrains_config"
    local latest_idea latest_studio
    latest_idea=$(ls -1d "${TARGET_HOME}"/.config/JetBrains/IntelliJIdea* 2>/dev/null | sort -V | tail -n 1 || true)
    latest_studio=$(ls -1d "${TARGET_HOME}"/.config/Google/AndroidStudio* 2>/dev/null | sort -V | tail -n 1 || true)

    if [ -n "$latest_idea" ]; then
        run_cmd rsync "${rsync_flags[@]}" -L "${jb_backup}/IntelliJIdea/" "${latest_idea}/"
    fi
    if [ -n "$latest_studio" ]; then
        run_cmd rsync "${rsync_flags[@]}" -L "${jb_backup}/AndroidStudio/" "${latest_studio}/"
    fi
}

# ------------------------------------------------------------------------------
# Helper: Convert .rclonelink files back into native POSIX symlinks
# ------------------------------------------------------------------------------
restore_rclonelinks() {
    local base_dir="$1"
    [ -d "$base_dir" ] || return 0
    while IFS= read -r -d '' link_file; do
        local target_path="${link_file%.rclonelink}"
        local link_target
        link_target=$(cat "$link_file" 2>/dev/null || true)
        if [ -n "$link_target" ]; then
            run_cmd ln -sfn "$link_target" "$target_path"
            run_cmd rm -f "$link_file"
        fi
    done < <(find "$base_dir" -type f -name "*.rclonelink" -print0 2>/dev/null)
}

# ------------------------------------------------------------------------------
# PHASE 3: Restore from Proton Drive (proton-drive filesystem download)
# ------------------------------------------------------------------------------
restore_from_protondrive() {
    confirm_phase "PHASE 3: Restore from Proton Drive Cloud Storage" || return 0

    if ! $DRY_RUN && [ -x "${PROTONDRIVE_SYNC_DIR}/check_protondrive_auth.sh" ]; then
        "${PROTONDRIVE_SYNC_DIR}/check_protondrive_auth.sh" "$PROTONDRIVE_CLI"
    fi

    # Format: "RemoteFolderName:/local/destination/path"
    declare -a pd_mappings=(
        "systemsettings:${SYS_SETTINGS_DIR}"
        "jetbrains_config:${TARGET_HOME}/backup_links/jetbrains_config"
        "scripts:${TARGET_HOME}/scripts"
        "CameraUploads:/data/CameraUploads"
        "MyProject:${TARGET_HOME}/workspace/MyProject"
    )

    for entry in "${pd_mappings[@]}"; do
        local remote_name="${entry%%:*}"
        local local_dir="${entry#*:}"
        run_cmd mkdir -p "$local_dir"
        run_cmd "$PROTONDRIVE_CLI" filesystem download -f skip -d merge "/my-files/${remote_name}" "$(dirname "$local_dir")"
        restore_rclonelinks "$local_dir"
    done
}

# ------------------------------------------------------------------------------
# PHASE 4: Re-Attach Tresorit Cloud Sync Directories (tresorit-cli)
# ------------------------------------------------------------------------------
restore_from_tresorit() {
    confirm_phase "PHASE 4: Re-Attach Tresorit Cloud Sync Directories" || return 0

    run_cmd "$TRESORIT_CLI" start
    run_cmd "$TRESORIT_CLI" status

    # Format: "Tresor Name or ID:/local/sync/path"
    declare -a tresor_mappings=(
        "System Settings:${SYS_SETTINGS_DIR}"
        "Scripts:${TARGET_HOME}/scripts"
        "JetBrains Config:${TARGET_HOME}/backup_links/jetbrains_config"
        "Camera Uploads:/data/CameraUploads"
        "Workspace - MyProject:${TARGET_HOME}/workspace/MyProject"
    )

    for item in "${tresor_mappings[@]}"; do
        local t_name="${item%%:*}"
        local t_path="${item#*:}"
        run_cmd mkdir -p "$t_path"
        run_cmd "$TRESORIT_CLI" sync --start "$t_name" --path "$t_path"
    done
}

case "$SOURCE_MODE" in
    all)
        restore_systemsettings
        restore_from_drive
        restore_from_protondrive
        restore_from_tresorit
        ;;
    systemsettings) restore_systemsettings ;;
    drive)          restore_from_drive ;;
    protondrive)    restore_from_protondrive ;;
    tresorit)       restore_from_tresorit ;;
    *)              echo "Invalid source mode: $SOURCE_MODE"; exit 1 ;;
esac

printf "\n==> Restore (%s) finished.\n" "$( $DRY_RUN && echo "DRY-RUN" || echo "EXECUTE" )"

