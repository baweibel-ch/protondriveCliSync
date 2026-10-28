#!/usr/bin/env bash
# ==============================================================================
# sync_protondrive.sh
#
# Primary Bash entry point for Proton Drive Synchronization.
# Directs all calls to the core differential engine (sync_protondrive.py) with 100%
# parameter and flag propagation ($@), supporting both CLI options and environment variables.
#
# Usage:
#   sync_protondrive.sh <cli_bin> <local_folder> <remote_folder> [OPTIONS]
#
# Options:
#   -L, --copy-links      : Follow symlinks and upload real target contents (like rclone -L)
#   -l, --links           : Translate symlinks into '.rclonelink' files (like rclone -l)
#   -e, --exclude PATTERN : Exclude pattern for files/dirs (can be repeated; default: '.tresorit')
#   -w, --workspace-excludes, --workspace : Apply IntelliJ/Gradle/Android workspace project exclusions
#                           (.git, .tresorit, .gradle, build, target, out, node_modules, dist, venv,
#                           .cxx, .externalNativeBuild, *.log, *.hprof, hex-only dumps; workspace.xml retained)
#                           (Strictly an explicit parameter; NEVER automatically enabled by directory path).
#   --no-history, -nh     : Do NOT keep version history:
#                           - Upload uses '--file-conflict-strategy replace' instead of 'create-new-revision'
#                           - Trashing permanently purges items from cloud trash
#                           (Can also be enabled globally via: export PROTONDRIVE_NO_HISTORY=true)
#   -n, --dry-run         : Perform trial run without making changes
#   --rescan-remote       : Force full recursive scan of remote tree to reconcile state
#   --save-filelist       : Write 'last_put_to_protondrive' snapshot file into local_dir
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_ENGINE="$SCRIPT_DIR/sync_protondrive.py"

if [[ ! -f "$PYTHON_ENGINE" ]]; then
    echo "ERROR: Engine script not found: $PYTHON_ENGINE"
    exit 1
fi

exec python3 "$PYTHON_ENGINE" "$@"
