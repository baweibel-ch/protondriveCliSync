#!/usr/bin/env python3
"""
sync_protondrive.py - High-Performance Differential Proton Drive Synchronization.

SAFETY GUARANTEES:
  - NEVER deletes, moves, overwrites, or modifies ANY local file or directory.
  - Local files are strictly READ-ONLY.
  - Remote deletions only apply to items deleted locally or explicitly excluded.

DIFFERENTIAL PERFORMANCE:
  - Maintains snapshot state in ~/.cache/protondrive_sync/<remote>.json.
  - Also compatible with legacy 'last_put_to_protondrive' list files.
  - Only sends modified or newly added files to Proton Drive CLI.
  - Skips remote crawling and uploads completely if no local changes occurred.
  - Automatic interactive login ('auth login') if unauthenticated.
  - Robust timeouts prevent blocking during post-boot delays.
  - Excluded/ignored items (e.g. .tresorit, build, .gradle, logs) are permanently purged
    from Proton Drive without history, even when the rest of sync runs with history.

Usage:
  sync_protondrive.py <cli_bin> <local_folder> <remote_folder> [OPTIONS]

Options:
  -L, --copy-links      : Follow symlinks and upload real target contents (rclone -L)
  -l, --links           : Translate symlinks to .rclonelink regular files (rclone -l)
  -e, --exclude PATTERN : Exclude pattern for files/dirs (can be repeated, default: '.tresorit')
  -w, --workspace-excludes, --workspace :
                          Include standard IntelliJ / Gradle / Android project exclusions:
                          .git, .tresorit, .gradle, build, target, out, node_modules, dist, venv,
                          .cxx, .externalNativeBuild, *.log, *.hprof, and hex-only named files/dumps.
                          (NOTE: workspace.xml is preserved; strictly an explicit parameter).
  --no-history, -nh     : Do NOT keep version history:
                          - Upload uses '--file-conflict-strategy replace' instead of 'create-new-revision'
                          - Trashing permanently purges items from cloud trash
                          (Can also be enabled globally via: export PROTONDRIVE_NO_HISTORY=true)
  -n, --dry-run         : Perform trial run without making cloud modifications
  --rescan-remote       : Force a full remote scan to reconcile cloud state
  --save-filelist       : Write/update 'last_put_to_protondrive' in local_dir if writable
"""

import sys
import re
import os
import shutil
import tempfile
import fnmatch
import json
import time
import subprocess
import argparse
from concurrent.futures import ThreadPoolExecutor

BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BLUE = "\033[36m"
RESET = "\033[0m"

SNAPSHOT_DIR = os.path.expanduser("~/.cache/protondrive_sync")


def log_info(msg):
    print(f"{BLUE}[INFO]{RESET} {msg}")


def log_ok(msg):
    print(f"{GREEN}[OK]{RESET} {msg}")


def log_warn(msg):
    print(f"{YELLOW}[WARN]{RESET} {msg}")


def log_err(msg):
    print(f"{RED}[ERROR]{RESET} {msg}")


def normalize_remote_path(remote_path):
    remote_path = remote_path.strip().rstrip("/")
    if not remote_path:
        return "/my-files"
    if remote_path.startswith(("/my-files", "/shared-with-me", "/devices")):
        return remote_path
    if remote_path.startswith("/"):
        return f"/my-files{remote_path}"
    return f"/my-files/{remote_path}"


def get_snapshot_path(remote_dir):
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    safe_name = remote_dir.strip("/").replace("/", "_")
    return os.path.join(SNAPSHOT_DIR, f"{safe_name}.json")


HEX_NAME_REGEX = re.compile(r"^[0-9a-fA-F]{8,}$")

DEFAULT_WORKSPACE_EXCLUDES = [
    ".tresorit",
    ".git",
    ".gradle",
    "build",
    "target",
    "out",
    "node_modules",
    "dist",
    "venv",
    ".cxx",
    ".externalNativeBuild",
    "*.log",
    "*.hprof",
    "<hex-names>",
]


def parse_exclude_patterns(raw_excludes, include_workspace=False):
    """
    Parses exclude patterns from command line arguments.
    Supports repeated -e, comma-separated values, or list representations.
    If include_workspace is True, includes standard IntelliJ / Gradle / Android exclusions.
    Always includes '.tresorit'.
    NOTE: Workspace exclusions are strictly parameter-driven (-w / --workspace-excludes)
          and NEVER applied automatically by directory path.
    """
    patterns = []
    if include_workspace:
        patterns.extend(DEFAULT_WORKSPACE_EXCLUDES)

    if raw_excludes:
        for item in raw_excludes:
            cleaned = item.strip('[]"' + chr(39))
            parts = [p.strip(' "' + chr(39)) for p in cleaned.split(',') if p.strip(' "' + chr(39))]
            patterns.extend(parts)

    if ".tresorit" not in patterns:
        patterns.append(".tresorit")

    # Remove duplicates preserving order
    return list(dict.fromkeys(patterns))


def is_item_excluded(rel_path, name, exclude_patterns):
    """
    Checks if a file or directory matches any exclusion pattern.
    Checks basename, full relative path, and each path segment.
    Also checks for hex-only named files (dumps, hashes, loose objects) when <hex-names> is active.
    """
    rel_clean = rel_path.replace("\\", "/").strip("/")
    parts = rel_clean.split("/")

    # Exclude files or path segments whose name consists purely of hexadecimal numbers (e.g. dumps, hashes)
    if "<hex-names>" in exclude_patterns:
        if HEX_NAME_REGEX.match(name) or any(HEX_NAME_REGEX.match(p) for p in parts):
            return True

    for pattern in exclude_patterns:
        if pattern == "<hex-names>":
            continue
        # Match against basename
        if fnmatch.fnmatch(name, pattern):
            return True
        # Match against relative path
        if fnmatch.fnmatch(rel_clean, pattern):
            return True
        # Match against any path segment (e.g. pattern 'build' matches 'app/build/classes')
        if any(fnmatch.fnmatch(p, pattern) for p in parts):
            return True
    return False


def collapse_redundant_paths(paths):
    """
    Removes paths whose ancestor directory is already scheduled for deletion.
    E.g. if 'build' is in paths, 'build/classes' and 'build/libs/a.jar' are omitted.
    """
    sorted_paths = sorted(paths, key=lambda x: (x.count("/"), len(x)))
    final_paths = []
    for p in sorted_paths:
        parts = p.split("/")
        has_ancestor = False
        for i in range(1, len(parts)):
            ancestor = "/".join(parts[:i])
            if ancestor in final_paths:
                has_ancestor = True
                break
        if not has_ancestor:
            final_paths.append(p)
    return final_paths


def run_cli(cli_bin, args, capture=True, timeout=60):
    cmd = [cli_bin] + args
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE if capture else None,
                             stderr=subprocess.PIPE if capture else None,
                             text=True, timeout=timeout)
        return res
    except subprocess.TimeoutExpired:
        log_warn(f"CLI command timed out ({timeout}s): {' '.join(cmd[:4])}...")
        return subprocess.CompletedProcess(cmd, returncode=124, stdout="", stderr="Timeout expired")


def ensure_authenticated(cli_bin):
    """
    Ensures Proton Drive CLI is logged in.
    If not logged in, launches interactive 'auth login'.
    Uses timeouts so it will never hang indefinitely after a reboot.
    """
    log_info("Verifying Proton Drive authentication...")
    try:
        check = subprocess.run([cli_bin, "filesystem", "list", "/"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=15)
        if check.returncode == 0:
            log_ok("Proton Drive CLI is authenticated.")
            return True
    except subprocess.TimeoutExpired:
        log_warn("Login check timed out (possible network initialization delay). Retrying with 20s timeout...")
        try:
            check = subprocess.run([cli_bin, "filesystem", "list", "/"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=20)
            if check.returncode == 0:
                log_ok("Proton Drive CLI is authenticated.")
                return True
        except subprocess.TimeoutExpired:
            log_err("Authentication check timed out repeatedly. Check network/VPN connection.")
            sys.exit(1)

    # Not authenticated: prompt user and execute auth login
    log_warn("Proton Drive CLI is NOT logged in or session has expired.")
    print(f"\n{BOLD}{YELLOW}==> Starting interactive authentication ('{cli_bin} auth login')...{RESET}")
    print("    (A browser window will open. Keep this terminal open until complete.)\n")

    login_res = subprocess.run([cli_bin, "auth", "login"])
    if login_res.returncode != 0:
        log_err("Interactive 'auth login' failed or was cancelled.")
        sys.exit(1)

    print("\n==> Verifying new login session...")
    try:
        verify = subprocess.run([cli_bin, "filesystem", "list", "/"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=20)
        if verify.returncode == 0:
            log_ok("Authentication successful! Continuing sync...")
            return True
        else:
            log_err("Authentication check failed after 'auth login'.")
            sys.exit(1)
    except subprocess.TimeoutExpired:
        log_err("Session verification timed out after login.")
        sys.exit(1)


def ensure_remote_dir_exists(cli_bin, remote_dir, dry_run=False):
    parts = [p for p in remote_dir.strip("/").split("/") if p]
    if len(parts) <= 1:
        return

    current = "/" + parts[0]
    for seg in parts[1:]:
        check_path = f"{current}/{seg}"
        res = run_cli(cli_bin, ["filesystem", "info", check_path], capture=True, timeout=20)
        if res.returncode != 0:
            if dry_run:
                log_info(f"{YELLOW}[DRY-RUN CREATE]{RESET} Would create remote folder '{seg}' in '{current}'")
            else:
                log_info(f"Creating missing remote folder '{check_path}' on Proton Drive...")
                create_res = run_cli(cli_bin, ["filesystem", "create-folder", current, seg], capture=True, timeout=30)
                if create_res.returncode == 0:
                    log_ok(f"Created: {check_path}")
                else:
                    err = create_res.stderr or create_res.stdout
                    if "already exists" not in err.lower():
                        log_warn(f"Note creating folder '{check_path}': {err.strip()}")
        current = check_path


def scan_local_tree(local_dir, link_mode, exclude_patterns):
    """
    Scans the local directory and returns a dictionary:
      rel_path -> { 'size': int, 'mtime': float, 'is_link': bool, 'link_target': str|None }
    Strictly READ-ONLY on local filesystem.
    """
    files_map = {}
    for root, dirs, files in os.walk(local_dir, followlinks=False):
        rel_root = os.path.relpath(root, local_dir)

        # Filter directories in-place (exclude matching dirs)
        dirs[:] = [
            d for d in dirs
            if not is_item_excluded(d if rel_root == "." else os.path.join(rel_root, d), d, exclude_patterns)
        ]

        # Check directory symlinks
        for d in list(dirs):
            d_path = os.path.join(root, d)
            rel_d = d if rel_root == "." else os.path.join(rel_root, d)
            if os.path.islink(d_path):
                dirs.remove(d)  # Do not descend automatically
                if link_mode == "links":
                    target = os.readlink(d_path)
                    rel_item = f"{rel_d}.rclonelink"
                    st = os.lstat(d_path)
                    files_map[rel_item] = {
                        "size": len(target.encode("utf-8")),
                        "mtime": st.st_mtime,
                        "is_link": True,
                        "link_target": target
                    }
                elif link_mode == "copy-links":
                    # Descend into real directory
                    real_d = os.path.realpath(d_path)
                    if os.path.isdir(real_d):
                        sub_files = scan_local_tree(real_d, link_mode, exclude_patterns)
                        for sub_p, sub_meta in sub_files.items():
                            combined_p = os.path.join(d, sub_p) if rel_root == "." else os.path.join(rel_root, d, sub_p)
                            files_map[combined_p] = sub_meta

        # Check files
        for f in files:
            rel_file = f if rel_root == "." else os.path.join(rel_root, f)
            if is_item_excluded(rel_file, f, exclude_patterns):
                continue

            f_path = os.path.join(root, f)

            if os.path.islink(f_path):
                if link_mode == "links":
                    target = os.readlink(f_path)
                    st = os.lstat(f_path)
                    files_map[rel_file + ".rclonelink"] = {
                        "size": len(target.encode("utf-8")),
                        "mtime": st.st_mtime,
                        "is_link": True,
                        "link_target": target
                    }
                elif link_mode == "copy-links":
                    target = os.path.realpath(f_path)
                    if os.path.isfile(target):
                        st = os.stat(target)
                        files_map[rel_file] = {
                            "size": st.st_size,
                            "mtime": st.st_mtime,
                            "is_link": False,
                            "link_target": None
                        }
                    else:
                        log_warn(f"Skipping broken symlink: {f_path}")
                else:
                    # link_mode == "skip"
                    pass
            else:
                try:
                    st = os.stat(f_path)
                    files_map[rel_file] = {
                        "size": st.st_size,
                        "mtime": st.st_mtime,
                        "is_link": False,
                        "link_target": None
                    }
                except OSError as e:
                    log_warn(f"Could not stat local file '{f_path}': {e}")

    return files_map


def load_snapshot(local_dir, remote_dir):
    """
    Loads previous snapshot data from ~/.cache/protondrive_sync/<remote>.json.
    Also checks for legacy 'last_put_to_protondrive' in local_dir if snapshot doesn't exist yet.
    """
    state_file = get_snapshot_path(remote_dir)
    if os.path.isfile(state_file):
        try:
            with open(state_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data, state_file, "cache"
        except Exception as e:
            log_warn(f"Could not read state file '{state_file}': {e}")

    # Fallback / migration: check for legacy last_put_to_protondrive in local_dir
    legacy_file = os.path.join(local_dir, "last_put_to_protondrive")
    if os.path.isfile(legacy_file):
        try:
            legacy_files = {}
            with open(legacy_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        legacy_files[line] = {"size": None, "mtime": None, "is_link": False, "link_target": None}
            log_info(f"Loaded {len(legacy_files)} entries from legacy '{legacy_file}'.")
            return {"files": legacy_files}, state_file, "legacy"
        except Exception as e:
            log_warn(f"Could not read legacy file '{legacy_file}': {e}")

    return None, state_file, "none"


def save_snapshot(state_file, local_dir, remote_dir, link_mode, files_map, save_legacy=False):
    """
    Atomically saves the snapshot to state_file.
    Optionally also writes 'last_put_to_protondrive' to local_dir if writable.
    """
    data = {
        "remote_dir": remote_dir,
        "local_dir": local_dir,
        "link_mode": link_mode,
        "last_sync": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "files": files_map
    }
    tmp_file = f"{state_file}.tmp.{os.getpid()}"
    try:
        with open(tmp_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_file, state_file)
    except Exception as e:
        log_warn(f"Could not save snapshot file '{state_file}': {e}")
        if os.path.exists(tmp_file):
            try:
                os.remove(tmp_file)
            except OSError:
                pass

    # Update legacy file if it exists or if explicitly requested
    legacy_file = os.path.join(local_dir, "last_put_to_protondrive")
    if save_legacy or os.path.isfile(legacy_file):
        try:
            tmp_legacy = f"{legacy_file}.tmp.{os.getpid()}"
            with open(tmp_legacy, "w", encoding="utf-8") as f:
                for path in sorted(files_map.keys()):
                    f.write(f"{path}\n")
            os.replace(tmp_legacy, legacy_file)
        except (OSError, PermissionError):
            if os.path.exists(tmp_legacy):
                try:
                    os.remove(tmp_legacy)
                except OSError:
                    pass


def list_remote_json(cli_bin, remote_dir):
    res = run_cli(cli_bin, ["filesystem", "list", "-j", remote_dir], capture=True, timeout=30)
    if res.returncode != 0:
        return None, res.stderr or res.stdout
    raw = res.stdout.strip()
    if not raw:
        return [], ""
    try:
        data = json.loads(raw)
        return (data if isinstance(data, list) else []), ""
    except json.JSONDecodeError as e:
        return None, f"JSON parse error: {e}"


def full_remote_crawl_parallel(cli_bin, remote_dir, max_workers=6):
    """
    Recursively scans the remote directory using parallel workers for fast reconciliation.
    Returns set of all relative paths on Proton Drive.
    """
    log_info(f"Scanning remote tree '{remote_dir}' with {max_workers} parallel workers...")
    remote_items = set()

    def crawl_dir(r_dir, rel_prefix):
        items, err = list_remote_json(cli_bin, r_dir)
        if items is None:
            return []
        sub_tasks = []
        for it in items:
            name_obj = it.get("name", {})
            name = name_obj.get("value") if isinstance(name_obj, dict) else str(name_obj)
            node_type = it.get("type", "file")
            if not name:
                continue
            rel_path = name if not rel_prefix else f"{rel_prefix}/{name}"
            remote_items.add(rel_path)
            if node_type == "folder":
                sub_tasks.append((f"{r_dir}/{name}", rel_path))
        return sub_tasks

    queue = [(remote_dir, "")]
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        while queue:
            next_queue = []
            futures = [executor.submit(crawl_dir, q_dir, q_prefix) for q_dir, q_prefix in queue]
            for f in futures:
                next_queue.extend(f.result())
            queue = next_queue

    return remote_items


def main():
    parser = argparse.ArgumentParser(
        description="High-performance differential sync to Proton Drive with deletion history and symlink support.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s ~/Downloads/proton-drive_0.9.0 /scripts rootscripts -l
  %(prog)s ~/Downloads/proton-drive_0.9.0 ~/workspace/Projekt projekt -l --workspace-excludes
  %(prog)s ~/Downloads/proton-drive_0.9.0 /data/CameraUploads CameraUploads -l --no-history
  %(prog)s ~/Downloads/proton-drive_0.9.0 ~/Documents Documents -L
"""
    )
    parser.add_argument("cli_bin", help="Path to Proton Drive CLI executable")
    parser.add_argument("local_dir", help="Local directory to synchronize (READ-ONLY)")
    parser.add_argument("remote_dir", help="Proton Drive target directory")

    symlink_group = parser.add_mutually_exclusive_group()
    symlink_group.add_argument("-L", "--copy-links", action="store_true",
                               help="Follow symlinks and upload real target contents (rclone -L)")
    symlink_group.add_argument("-l", "--links", action="store_true",
                               help="Translate symlinks to .rclonelink regular files (rclone -l)")

    parser.add_argument("-e", "--exclude", action="append", default=[],
                        help="Exclude pattern for files/dirs (can be repeated, default: '.tresorit')")
    parser.add_argument("-w", "--workspace", "--workspace-excludes", action="store_true", dest="workspace_excludes",
                        help="Include standard IntelliJ / Gradle / Android project exclusions "
                             "(.git, .tresorit, .gradle, build, target, out, node_modules, dist, venv, "
                             ".cxx, .externalNativeBuild, *.log, *.hprof, hex-only dumps; workspace.xml retained). "
                             "Must be passed explicitly as parameter.")
    parser.add_argument("--no-history", "-nh", action="store_true",
                        help="Do NOT keep version history (upload uses 'replace', trash permanently purges)")
    parser.add_argument("-n", "--dry-run", action="store_true",
                        help="Perform trial run without uploading or deleting anything")
    parser.add_argument("-t", "--skip-thumbnails", action="store_true", default=True,
                        help="Skip generating thumbnails for faster upload (default: true)")
    parser.add_argument("--rescan-remote", action="store_true",
                        help="Force a full recursive crawl of Proton Drive to reconcile state")
    parser.add_argument("--save-filelist", action="store_true",
                        help="Also write 'last_put_to_protondrive' file in local_dir if writable")

    args = parser.parse_args()

    cli_bin = os.path.abspath(os.path.expanduser(args.cli_bin))
    local_dir = os.path.abspath(os.path.expanduser(args.local_dir))
    remote_dir = normalize_remote_path(args.remote_dir)

    if not os.path.isfile(cli_bin) or not os.access(cli_bin, os.X_OK):
        log_err(f"Proton Drive CLI executable not found: {cli_bin}")
        sys.exit(1)

    if not os.path.isdir(local_dir):
        log_err(f"Local directory does not exist: {local_dir}")
        sys.exit(1)

    exclude_patterns = parse_exclude_patterns(args.exclude, include_workspace=args.workspace_excludes)

    if args.copy_links:
        link_mode = "copy-links"
    elif args.links:
        link_mode = "links"
    else:
        link_mode = "skip"

    env_no_history = os.environ.get("PROTONDRIVE_NO_HISTORY", "").strip().lower() in ("1", "true", "yes", "y")
    is_no_history = args.no_history or env_no_history
    conflict_strategy = "replace" if is_no_history else "create-new-revision"

    print(f"{BOLD}=== Proton Drive Sync (Differential: Local -> Cloud) ==={RESET}")
    print(f"CLI Binary : {cli_bin}")
    print(f"Local Dir  : {local_dir} (READ-ONLY: no local files are ever modified)")
    print(f"Remote Dir : {remote_dir}")
    print(f"Link Mode  : {link_mode}")
    print(f"Workspace  : {'EXCLUDES ACTIVE (-w / --workspace-excludes)' if args.workspace_excludes else 'Standard (parameter not set)'}")
    print(f"Exclusions : {exclude_patterns}")
    print(f"History    : {'NO-HISTORY (conflict: replace, trash: permanent purge)' if is_no_history else 'WITH-HISTORY (conflict: create-new-revision, trash: preserved in /trash; ignored items: permanent purge)'}")
    if args.dry_run:
        print(f"{YELLOW}Mode       : DRY-RUN (no changes will be applied){RESET}")
    print("-------------------------------------------------------------")

    # Step -1: Ensure Authentication (Never block after restart; interactive login if needed)
    ensure_authenticated(cli_bin)

    # Step 0: Ensure target directory exists on Proton Drive
    ensure_remote_dir_exists(cli_bin, remote_dir, dry_run=args.dry_run)

    # Scan local tree (instant on local SSD/HDD)
    t0 = time.time()
    curr_files = scan_local_tree(local_dir, link_mode, exclude_patterns)
    log_info(f"Local scan completed in {time.time() - t0:.2f}s ({len(curr_files)} items found).")

    # Load previous snapshot
    snapshot, state_file, snap_source = load_snapshot(local_dir, remote_dir)

    raw_deletions = []
    modified_or_new = []

    if snapshot is not None and not args.rescan_remote:
        prev_files = snapshot.get("files", {})
        # Deleted: in snapshot but missing locally (or newly excluded)
        raw_deletions = [p for p in prev_files if p not in curr_files]

        # Modified or New:
        for p, cur in curr_files.items():
            if p not in prev_files:
                modified_or_new.append(p)
            else:
                prev = prev_files[p]
                # If legacy snapshot without size/mtime, assume unchanged unless rescan requested
                if prev.get("size") is None or prev.get("mtime") is None:
                    continue
                size_changed = cur["size"] != prev.get("size")
                mtime_changed = abs(cur["mtime"] - prev.get("mtime", 0)) > 0.001
                link_changed = cur.get("link_target") != prev.get("link_target")
                if size_changed or mtime_changed or link_changed:
                    modified_or_new.append(p)

        log_ok(f"Snapshot loaded ({snap_source}): {len(raw_deletions)} to delete, {len(modified_or_new)} new/modified.")
    else:
        # First sync or full rescan requested
        if args.rescan_remote:
            log_info("Full remote reconciliation requested...")
            remote_set = full_remote_crawl_parallel(cli_bin, remote_dir)
            raw_deletions = [p for p in remote_set if p not in curr_files]
            modified_or_new = list(curr_files.keys())
        else:
            log_info("Initial run for this folder (establishing snapshot)...")
            raw_deletions = []
            modified_or_new = list(curr_files.keys())

    # Check top-level remote items for any existing excluded items (e.g. .tresorit, build, .gradle)
    top_items, _ = list_remote_json(cli_bin, remote_dir)
    if top_items:
        for it in top_items:
            name_obj = it.get("name", {})
            name = name_obj.get("value") if isinstance(name_obj, dict) else str(name_obj)
            if not name:
                continue
            if is_item_excluded(name, name, exclude_patterns):
                if name not in raw_deletions:
                    raw_deletions.append(name)

    # Collapse redundant child paths when parent directory is already scheduled for deletion
    final_deletions = collapse_redundant_paths(raw_deletions)

    # Step 1: Delete remote items (Ignored items: ALWAYS permanently deleted / no-history!)
    print(f"\n{BOLD}Step 1: Checking for remote files to delete/trash in cloud...{RESET}")
    if not final_deletions:
        log_ok("No deleted files detected (0 remote deletions needed).")
    else:
        log_info(f"Found {len(final_deletions)} items to delete/purge on Proton Drive.")
        for rel_p in final_deletions:
            remote_item_path = f"{remote_dir}/{rel_p}"
            item_name = os.path.basename(rel_p)
            is_ignored = is_item_excluded(rel_p, item_name, exclude_patterns)

            # RULE: Ignored/excluded items are ALWAYS permanently purged (no-history)
            # Normal items are purged only if overall is_no_history is True
            should_purge = is_no_history or is_ignored

            if args.dry_run:
                action_desc = "would permanently purge (no-history)" if should_purge else "would move to trash (history preserved)"
                reason = "ignored/excluded item" if is_ignored else "deleted locally"
                log_info(f"{YELLOW}[DRY-RUN DELETE]{RESET} {remote_item_path} ({reason}) -> {action_desc}")
            else:
                if should_purge:
                    reason = "ignored/excluded item" if is_ignored else "no-history sync"
                    log_info(f"Permanently purging on Proton Drive ({reason}): {remote_item_path}")
                    run_cli(cli_bin, ["filesystem", "trash", remote_item_path], capture=True, timeout=30)
                    purge_res = run_cli(cli_bin, ["filesystem", "delete", f"/trash/{item_name}"], capture=True, timeout=30)
                    if purge_res.returncode == 0:
                        log_ok(f"Permanently purged: {remote_item_path}")
                    else:
                        log_warn(f"Note purging '{remote_item_path}': {purge_res.stderr or purge_res.stdout}")
                else:
                    log_info(f"Moving to cloud trash (history preserved): {remote_item_path}")
                    res = run_cli(cli_bin, ["filesystem", "trash", remote_item_path], capture=True, timeout=30)
                    if res.returncode == 0:
                        log_ok(f"Moved to trash: {remote_item_path}")
                    else:
                        log_warn(f"Note trashing '{remote_item_path}': {res.stderr or res.stdout}")

    # Step 2: Upload new or modified items
    print(f"\n{BOLD}Step 2: Uploading modified / new items to Proton Drive (conflict: {conflict_strategy})...{RESET}")
    if not modified_or_new:
        log_ok(f"{GREEN}✓ Everything is up to date (0 files modified or added).{RESET}")
        if final_deletions and not args.dry_run:
            save_snapshot(state_file, local_dir, remote_dir, link_mode, curr_files, save_legacy=args.save_filelist)
            log_ok("Snapshot updated.")
        print(f"\n{BOLD}{GREEN}✓ Sync to Proton Drive finished successfully!{RESET}\n")
        sys.exit(0)

    if args.dry_run:
        log_info(f"{YELLOW}[DRY-RUN UPLOAD]{RESET} Would upload {len(modified_or_new)} items to {remote_dir} with strategy {conflict_strategy}")
        for sample_p in modified_or_new[:5]:
            print(f"  + {sample_p}")
        if len(modified_or_new) > 5:
            print(f"  ... and {len(modified_or_new) - 5} more")
        print(f"\n{BOLD}{GREEN}✓ Dry-run completed successfully!{RESET}\n")
        sys.exit(0)

    log_info(f"Staging {len(modified_or_new)} new/modified items...")
    staging_temp = tempfile.mkdtemp(prefix="proton_sync_stage_")
    try:
        for rel_p in modified_or_new:
            meta = curr_files[rel_p]
            dst_path = os.path.join(staging_temp, rel_p)
            os.makedirs(os.path.dirname(dst_path), exist_ok=True)

            if meta["is_link"] and meta.get("link_target"):
                with open(dst_path, "w", encoding="utf-8") as f:
                    f.write(meta["link_target"])
                # Preserve mtime
                os.utime(dst_path, (meta["mtime"], meta["mtime"]))
            else:
                # Regular file or copied link
                src_path = os.path.join(local_dir, rel_p)
                if not os.path.exists(src_path):
                    continue
                try:
                    os.link(src_path, dst_path)
                except OSError:
                    shutil.copy2(src_path, dst_path)

        staged_items = [os.path.join(staging_temp, it) for it in os.listdir(staging_temp)]
        if not staged_items:
            log_info("Nothing to stage for upload.")
            sys.exit(0)

        upload_cmd = [cli_bin, "filesystem", "upload"]
        if args.skip_thumbnails:
            upload_cmd.append("-t")
        upload_cmd.extend([
            "--folder-conflict-strategy", "merge",
            "--file-conflict-strategy", conflict_strategy
        ])
        upload_cmd.extend(staged_items)
        upload_cmd.append(remote_dir)

        log_info(f"Running upload of {len(modified_or_new)} items to {remote_dir}...")
        res = subprocess.run(upload_cmd)
        if res.returncode == 0:
            log_ok("Upload completed successfully.")
            save_snapshot(state_file, local_dir, remote_dir, link_mode, curr_files, save_legacy=args.save_filelist)
            log_ok("Snapshot updated.")
        else:
            log_err(f"Upload exited with code {res.returncode}")
            sys.exit(res.returncode)

    finally:
        if staging_temp.startswith(tempfile.gettempdir()) and os.path.exists(staging_temp):
            shutil.rmtree(staging_temp, ignore_errors=True)

    print(f"\n{BOLD}{GREEN}✓ Sync to Proton Drive finished successfully!{RESET}\n")


if __name__ == "__main__":
    main()
