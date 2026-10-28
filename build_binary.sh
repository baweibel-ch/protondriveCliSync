#!/usr/bin/env bash
# ==============================================================================
# build_binary.sh
#
# Builds a self-contained, standalone Linux binary of protondrive-sync
# using PyInstaller in a temporary virtual environment.
#
# Output:
#   dist/protondrive-sync (single executable, no Python required on target machine)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building standalone binary with PyInstaller..."

# Check Python 3
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required to build the standalone binary."
    exit 1
fi

BUILD_VENV=$(mktemp -d /tmp/pd_build_venv_XXXXXX)
WORK_DIR=$(mktemp -d /tmp/pd_work_XXXXXX)

cleanup() {
    rm -rf "$BUILD_VENV" "$WORK_DIR" "$SCRIPT_DIR/protondrive-sync.spec" 2>/dev/null || true
}
trap cleanup EXIT

echo "  -> Creating isolated build environment..."
python3 -m venv "$BUILD_VENV"
"$BUILD_VENV/bin/pip" install --quiet --upgrade pip pyinstaller

echo "  -> Compiling 'dist/protondrive-sync'..."
mkdir -p "$SCRIPT_DIR/dist"
"$BUILD_VENV/bin/pyinstaller" \
    --onefile \
    --clean \
    --name protondrive-sync \
    --distpath "$SCRIPT_DIR/dist" \
    --workpath "$WORK_DIR" \
    "$SCRIPT_DIR/sync_protondrive.py"

chmod +x "$SCRIPT_DIR/dist/protondrive-sync"

echo ""
echo "✓ Build complete!"
echo "  Binary location: $SCRIPT_DIR/dist/protondrive-sync"
ls -lh "$SCRIPT_DIR/dist/protondrive-sync"
echo ""
echo "To test run:"
echo "  $SCRIPT_DIR/dist/protondrive-sync --help"
