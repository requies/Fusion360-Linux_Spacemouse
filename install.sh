#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUSION_ROOT="${FUSION_ROOT:-$HOME/.autodesk_fusion}"
SKIP_DEPS=0
SKIP_SERVICE=0
SKIP_LAUNCHER_PATCH=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Installs the SpaceMouse bridge for Autodesk Fusion 360 running through the
cryinkfly Wine launcher on Linux.

Options:
  --fusion-root PATH       Fusion Linux launcher root. Default: ~/.autodesk_fusion
  --skip-deps              Do not install distro packages.
  --skip-service           Do not enable/start spacenavd.service.
  --skip-launcher-patch    Install files only; do not patch the Fusion launcher.
  -h, --help               Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --fusion-root)
            FUSION_ROOT="${2:?missing path after --fusion-root}"
            shift 2
            ;;
        --skip-deps)
            SKIP_DEPS=1
            shift
            ;;
        --skip-service)
            SKIP_SERVICE=1
            shift
            ;;
        --skip-launcher-patch)
            SKIP_LAUNCHER_PATCH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

log() {
    printf '[spacemouse360] %s\n' "$*"
}

warn() {
    printf '[spacemouse360] warning: %s\n' "$*" >&2
}

die() {
    printf '[spacemouse360] error: %s\n' "$*" >&2
    exit 1
}

need_file() {
    [ -f "$1" ] || die "missing required file: $1"
}

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif command -v python >/dev/null 2>&1; then
        command -v python
    else
        return 1
    fi
}

deps_ready() {
    command -v cc >/dev/null 2>&1 &&
        command -v spacenavd >/dev/null 2>&1 &&
        [ -r /usr/include/spnav.h ]
}

install_deps() {
    if [ "$SKIP_DEPS" -eq 1 ] || deps_ready; then
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        log "Installing Arch/CachyOS dependencies with pacman"
        sudo pacman -S --needed spacenavd libspnav gcc
    elif command -v apt-get >/dev/null 2>&1; then
        log "Installing Debian/Ubuntu dependencies with apt"
        sudo apt-get update
        sudo apt-get install -y spacenavd libspnav-dev build-essential
    elif command -v dnf >/dev/null 2>&1; then
        log "Installing Fedora dependencies with dnf"
        sudo dnf install -y spacenavd libspnav-devel gcc
    else
        die "unsupported package manager. Install spacenavd, libspnav development headers, and a C compiler, then rerun with --skip-deps."
    fi
}

start_spacenavd() {
    if [ "$SKIP_SERVICE" -eq 1 ] || ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    if systemctl is-active --quiet spacenavd.service; then
        log "spacenavd.service is already running"
        return
    fi

    log "Enabling and starting spacenavd.service"
    sudo systemctl enable --now spacenavd.service
}

resolve_wine_prefix() {
    local log_file="$FUSION_ROOT/logs/wineprefixes.log"
    local prefix=""

    if [ -f "$log_file" ]; then
        prefix="$(sed -n '3p' "$log_file")"
    fi

    if [ -n "$prefix" ] && [ -d "$prefix" ]; then
        printf '%s\n' "$prefix"
    elif [ -d "$FUSION_ROOT/wineprefixes/default" ]; then
        printf '%s\n' "$FUSION_ROOT/wineprefixes/default"
    else
        die "could not find Fusion Wine prefix. Use --fusion-root PATH."
    fi
}

resolve_wine_user_dir() {
    local wine_prefix="$1"
    local user_name
    user_name="$(id -un)"

    local candidates=(
        "$wine_prefix/drive_c/users/$USER"
        "$wine_prefix/drive_c/users/$user_name"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate/AppData/Roaming" ] || [ -d "$candidate/Application Data" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    shopt -s nullglob
    for candidate in "$wine_prefix"/drive_c/users/*; do
        case "$(basename "$candidate")" in
            Public|Default|"All Users")
                continue
                ;;
        esac
        if [ -d "$candidate/AppData/Roaming" ] || [ -d "$candidate/Application Data" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    shopt -u nullglob

    printf '%s\n' "$wine_prefix/drive_c/users/$user_name"
}

install_bridge() {
    local source_file="$SCRIPT_DIR/src/spacenav-fusion-bridge.c"
    local source_target="$HOME/.local/share/autodesk-fusion-spacenav/spacenav-fusion-bridge.c"
    local binary_target="$HOME/.local/bin/spacenav-fusion-bridge"

    need_file "$source_file"
    mkdir -p "$(dirname "$source_target")" "$(dirname "$binary_target")"
    cp "$source_file" "$source_target"

    if command -v cc >/dev/null 2>&1; then
        log "Compiling native spacenav bridge"
        cc -O2 -Wall -Wextra -o "$binary_target" "$source_target" -lspnav
    elif [ -x "$SCRIPT_DIR/bin/spacenav-fusion-bridge" ]; then
        warn "C compiler not found; installing bundled binary"
        cp "$SCRIPT_DIR/bin/spacenav-fusion-bridge" "$binary_target"
    else
        die "C compiler not found and no bundled bridge binary exists"
    fi

    chmod 755 "$binary_target"
}

install_addin() {
    local wine_user_dir="$1"
    local addin_target="$wine_user_dir/AppData/Roaming/Autodesk/Autodesk Fusion 360/API/AddIns/SpacenavBridge"

    need_file "$SCRIPT_DIR/addin/SpacenavBridge.py"
    need_file "$SCRIPT_DIR/addin/SpacenavBridge.manifest"

    mkdir -p "$addin_target"
    cp "$SCRIPT_DIR/addin/SpacenavBridge.py" "$addin_target/SpacenavBridge.py"
    cp "$SCRIPT_DIR/addin/SpacenavBridge.manifest" "$addin_target/SpacenavBridge.manifest"

    # Verify the orthographic camera fix is present (added 2026-05-26)
    if ! grep -qF 'camera.cameraType' "$addin_target/SpacenavBridge.py"; then
        warn "Installed add-in is missing the orthographic camera fix — Z-axis zoom may not work"
    fi

    log "Installed Fusion add-in to $addin_target"
}

patch_launcher() {
    local launcher="$FUSION_ROOT/bin/autodesk_fusion_launcher.sh"
    local python_bin

    [ "$SKIP_LAUNCHER_PATCH" -eq 0 ] || return
    need_file "$launcher"

    python_bin="$(find_python)" || die "python3 is required to patch the launcher"
    cp "$launcher" "$launcher.bak.spacemouse360.$(date +%Y%m%d%H%M%S)"

    FUSION_LAUNCHER="$launcher" "$python_bin" <<'PY'
import os
import sys
from pathlib import Path

path = Path(os.environ["FUSION_LAUNCHER"])
text = path.read_text()
original = text

block = '''SPNAV_FUSION_BRIDGE="$HOME/.local/bin/spacenav-fusion-bridge"
SPNAV_FUSION_BRIDGE_PID=""
SPNAV_FUSION_BRIDGE_LOG="$AUTODESK_ROOT_DIRECTORY/logs/spacenav-fusion-bridge.log"

function start_spacenav_fusion_bridge() {
    SPNAV_FUSION_BRIDGE_PID=""

    if [ -x "$SPNAV_FUSION_BRIDGE" ]; then
        mkdir -p "$AUTODESK_ROOT_DIRECTORY/logs"
        "$SPNAV_FUSION_BRIDGE" >> "$SPNAV_FUSION_BRIDGE_LOG" 2>&1 &
        SPNAV_FUSION_BRIDGE_PID=$!
    fi
}

function stop_spacenav_fusion_bridge() {
    if [ -n "$SPNAV_FUSION_BRIDGE_PID" ]; then
        kill "$SPNAV_FUSION_BRIDGE_PID" >/dev/null 2>&1
        wait "$SPNAV_FUSION_BRIDGE_PID" >/dev/null 2>&1
        SPNAV_FUSION_BRIDGE_PID=""
    fi
}

'''

if "# >>> spacemouse360_linux" not in text:
    anchor = 'PROTON_VERSION=$(awk \'NR == 4\' "$WINEPREFIX_LOG_FILE")\n'
    if anchor not in text:
        sys.exit("Could not find PROTON_VERSION anchor in launcher.")
    marked_block = "# >>> spacemouse360_linux\n" + block + "# <<< spacemouse360_linux\n"
    text = text.replace(anchor, anchor + marked_block, 1)

def insert_after_all(src, needle, insert):
    pos = 0
    while True:
        idx = src.find(needle, pos)
        if idx < 0:
            return src
        after = idx + len(needle)
        if not src.startswith(insert, after):
            src = src[:after] + insert + src[after:]
            after += len(insert)
        pos = after

text = insert_after_all(text, '    echo $LAUNCHER\n', '    start_spacenav_fusion_bridge\n')
text = insert_after_all(text, '    echo "$LAUNCHER"\n', '    start_spacenav_fusion_bridge\n')
text = insert_after_all(text, '    wait "$WINEPID"\n', '    stop_spacenav_fusion_bridge\n')
text = insert_after_all(text, '    wait $WINEPID\n', '    stop_spacenav_fusion_bridge\n')

proton_anchor = '    PROTON_LOG=0 \\\n'
idx = text.find(proton_anchor)
if idx >= 0 and 'start_spacenav_fusion_bridge' not in text[max(0, idx - 160):idx]:
    text = text[:idx] + '    start_spacenav_fusion_bridge\n\n' + text[idx:]

if text != original:
    path.write_text(text)
PY

    bash -n "$launcher"
    log "Patched Fusion launcher: $launcher"
}

patch_spacemouse_option() {
    local wine_user_dir="$1"
    local options_file=""
    local python_bin

    for candidate in \
        "$wine_user_dir/Application Data/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml" \
        "$wine_user_dir/AppData/Roaming/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml"; do
        if [ -f "$candidate" ]; then
            options_file="$candidate"
            break
        fi
    done

    if [ -z "$options_file" ]; then
        warn "Fusion machine-specific options file was not found; skipping SpaceMouse SDK preference."
        return
    fi

    python_bin="$(find_python)" || die "python3 is required to patch Fusion options"
    SPACEMOUSE_OPTIONS_FILE="$options_file" "$python_bin" <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["SPACEMOUSE_OPTIONS_FILE"])
raw = path.read_bytes()
encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) or raw[:200].count(b"\x00") > 20 else "utf-8"
text = raw.decode(encoding)
new, count = re.subn(
    r'(<spacemouseDriverOptionId\b[^>]*\bValue=")[^"]*(")',
    r'\g<1>0\2',
    text,
    count=1,
)
if count:
    path.write_bytes(new.encode(encoding))
PY
    log "Set Fusion SpaceMouse driver option to Older/Legacy"
}

smoke_test_bridge() {
    local bridge="$HOME/.local/bin/spacenav-fusion-bridge"

    if "$bridge" --check; then
        return
    fi

    warn "Bridge installed, but it could not connect to spacenavd yet."
    warn "Confirm the SpaceMouse is plugged in and spacenavd.service is running."
}

main() {
    local wine_prefix
    local wine_user_dir

    install_deps
    start_spacenavd
    install_bridge

    wine_prefix="$(resolve_wine_prefix)"
    wine_user_dir="$(resolve_wine_user_dir "$wine_prefix")"

    install_addin "$wine_user_dir"
    patch_launcher
    patch_spacemouse_option "$wine_user_dir"
    smoke_test_bridge

    log "Done. Restart Fusion 360 through the normal Linux launcher."
}

main "$@"
