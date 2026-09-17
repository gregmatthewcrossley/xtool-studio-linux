#!/usr/bin/env bash
#
# Install xTool Studio (Windows build) on Linux under Wine.
#
# See README.md for why this is necessary and why stock distro Wine fails.
#
set -euo pipefail

# Wine older than this hangs on startup with a stack overflow inside builtin
# DWrite.dll and never shows a window. See README.md § Why stock Wine fails.
MIN_WINE_MAJOR=11
MIN_WINE_MINOR=5

# Pinned known-good generic Wine build, used only if the system Wine is too old.
WINE_BUILD_VERSION="${WINE_BUILD_VERSION:-11.17}"
WINE_BUILD_URL_BASE="https://github.com/Kron4ek/Wine-Builds/releases/download"

APP_NAME="xTool Studio"
SLUG="xtool-studio"
PREFIX="${WINEPREFIX:-$HOME/.local/share/wineprefixes/$SLUG}"
SUPPORT_DIR="$HOME/.local/share/$SLUG"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"

EXE=""
WINE_ROOT=""
ALLOW_DOWNLOAD=1

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

usage() {
	cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --exe PATH        Path to xTool-Studio-x64-<version>.exe
                    (default: newest match in ~/Downloads)
  --wine PATH       Use this Wine installation. PATH is either the `wine`
                    binary or the directory containing bin/wine.
                    Skips the version check -- you are on your own.
  --prefix PATH     Wine prefix location
                    (default: ~/.local/share/wineprefixes/xtool-studio)
  --no-download     Never download Wine. Fail instead if the system Wine
                    is too old.
  -h, --help        Show this help.

Environment:
  WINE_BUILD_VERSION   Wine version to fetch if the system Wine is too old.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--exe)          EXE="${2:?--exe needs a path}"; shift 2 ;;
		--wine)         WINE_ROOT="${2:?--wine needs a path}"; shift 2 ;;
		--prefix)       PREFIX="${2:?--prefix needs a path}"; shift 2 ;;
		--no-download)  ALLOW_DOWNLOAD=0; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              die "unknown option: $1 (try --help)" ;;
	esac
done

# ---------------------------------------------------------------- dependencies

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1${2:+  (Fedora: sudo dnf install $2)}"
}

# 7-Zip is packaged under several names depending on distro and version.
SEVENZIP=""
for c in 7z 7zz 7za; do
	if command -v "$c" >/dev/null 2>&1; then SEVENZIP="$c"; break; fi
done
[ -n "$SEVENZIP" ] || die "missing required command: 7z  (Fedora: sudo dnf install p7zip)"

need_cmd winetricks winetricks
need_cmd cabextract cabextract   # winetricks needs this to unpack the font cabs
need_cmd curl curl
need_cmd tar tar

# Optional: only used to give the desktop entry a real icon.
HAVE_ICOTOOLS=0
if command -v wrestool >/dev/null 2>&1 && command -v icotool >/dev/null 2>&1; then
	HAVE_ICOTOOLS=1
fi

# ------------------------------------------------------------------- installer

if [ -z "$EXE" ]; then
	# Newest matching download wins, so re-running after an upgrade does the
	# right thing without needing --exe.
	EXE="$(ls -1t "$HOME"/Downloads/xTool-Studio-x64-*.exe 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ]   || die "no installer found in ~/Downloads; pass --exe /path/to/xTool-Studio-x64-<version>.exe
       Download it from https://www.xtool.com/pages/software (choose Windows)."
[ -f "$EXE" ]   || die "no such file: $EXE"

# Guard against being handed the wrong file: the installer is an NSIS archive
# whose payload is app-64.7z. Anything else will fail later and confusingly.
if ! "$SEVENZIP" l -- "$EXE" 2>/dev/null | grep -q 'app-64\.7z'; then
	die "$EXE does not look like an xTool Studio NSIS installer (no app-64.7z inside)."
fi
info "Installer: $EXE"

# ------------------------------------------------------------------------ wine

wine_version_of() {
	# Prints "MAJOR MINOR" for a wine binary, or nothing if unparseable.
	# Handles "wine-11.0", "wine-11.5 (Staging)", "wine-11.5.r0.g1dbc94083d1 (TkG)".
	"$1" --version 2>/dev/null \
		| sed -n 's/^wine-\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\1 \2/p'
}

wine_is_new_enough() {
	local v major minor
	v="$(wine_version_of "$1")" || return 1
	[ -n "$v" ] || return 1
	major="${v% *}"; minor="${v#* }"
	[ "$major" -gt "$MIN_WINE_MAJOR" ] && return 0
	[ "$major" -eq "$MIN_WINE_MAJOR" ] && [ "$minor" -ge "$MIN_WINE_MINOR" ]
}

download_wine() {
	local ver="$WINE_BUILD_VERSION"
	local name="wine-${ver}-staging-amd64-wow64"
	local url="$WINE_BUILD_URL_BASE/${ver}/${name}.tar.xz"
	local dest="$SUPPORT_DIR/wine-${ver}"

	# Everything except the final path must go to stderr: this function's
	# stdout is captured by the caller.
	if [ -x "$dest/bin/wine" ]; then
		info "Using previously downloaded Wine $ver" >&2
		printf '%s' "$dest"
		return
	fi

	info "Downloading Wine $ver (~100 MB) from Kron4ek/Wine-Builds" >&2
	local tmp
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN

	curl -fL --progress-bar -o "$tmp/wine.tar.xz" "$url" >&2 \
		|| die "download failed: $url"

	mkdir -p "$SUPPORT_DIR"
	tar -xf "$tmp/wine.tar.xz" -C "$tmp" || die "could not extract the Wine tarball"
	[ -x "$tmp/$name/bin/wine" ] || die "unexpected tarball layout: no $name/bin/wine"

	rm -rf "$dest"
	mv "$tmp/$name" "$dest"
	printf '%s' "$dest"
}

if [ -n "$WINE_ROOT" ]; then
	# --wine may point at the binary or at the tree containing bin/wine.
	if [ -x "$WINE_ROOT" ] && [ ! -d "$WINE_ROOT" ]; then
		WINE_ROOT="$(dirname "$(dirname "$(readlink -f "$WINE_ROOT")")")"
	fi
	[ -x "$WINE_ROOT/bin/wine" ] || die "no wine binary at $WINE_ROOT/bin/wine"
	info "Using Wine at $WINE_ROOT (version check skipped)"
elif command -v wine >/dev/null 2>&1 && wine_is_new_enough "$(command -v wine)"; then
	WINE_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v wine)")")")"
	info "Using system Wine ($(wine --version))"
else
	sysver="$(command -v wine >/dev/null 2>&1 && wine --version || echo 'not installed')"
	warn "System Wine is $sysver; need >= ${MIN_WINE_MAJOR}.${MIN_WINE_MINOR}."
	warn "Older Wine hangs on startup with no window (see README.md)."
	[ "$ALLOW_DOWNLOAD" -eq 1 ] \
		|| die "refusing to download because --no-download was given"
	WINE_ROOT="$(download_wine)"
fi

WINE="$WINE_ROOT/bin/wine"
export PATH="$WINE_ROOT/bin:$PATH"
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=-all

# ---------------------------------------------------------------------- vulkan

# The launcher passes --use-angle=vulkan. Without it ANGLE falls back to its
# D3D11 backend, which Wine cannot service, and the renderer ends up with no
# WebGL at all -- the app opens fine but a new project shows a blank workspace.
# That needs a host Vulkan driver plus Wine's winevulkan. Warn rather than fail:
# everything except the editor canvas still works.
check_vulkan() {
	local d found=0
	for d in /usr/share/vulkan/icd.d /etc/vulkan/icd.d \
	         /usr/local/share/vulkan/icd.d "$HOME/.local/share/vulkan/icd.d"; do
		if [ -d "$d" ] && [ -n "$(ls -1 "$d"/*.json 2>/dev/null)" ]; then
			found=1
			break
		fi
	done

	if [ "$found" -eq 0 ]; then
		warn "no Vulkan driver (ICD) found; the workspace canvas will stay blank."
		warn "  Install your GPU vendor's Vulkan driver, then re-run this script."
		warn "  (Fedora, Mesa GPUs: sudo dnf install vulkan-loader mesa-vulkan-drivers)"
		return
	fi

	if ! ls "$WINE_ROOT"/lib*/wine/x86_64-windows/winevulkan.dll >/dev/null 2>&1; then
		warn "this Wine build ships no winevulkan.dll; the workspace may stay blank."
	fi
}
check_vulkan

# ----------------------------------------------------------------- wine prefix

info "Preparing Wine prefix at $PREFIX"
mkdir -p "$(dirname "$PREFIX")"
"$WINE_ROOT/bin/wineboot" -u >/dev/null 2>&1 || die "wineboot failed"
"$WINE_ROOT/bin/wineserver" -w

# Electron 36 expects to be running on Windows 10.
"$WINE_ROOT/bin/winecfg" -v win10 >/dev/null 2>&1 || true

# A prefix with no fonts makes Chromium's font fallback recurse until the stack
# is gone. This is required even on a Wine new enough to otherwise work.
if [ ! -e "$PREFIX/drive_c/windows/Fonts/corefonts.installed" ]; then
	info "Installing core fonts (downloads ~4 MB)"
	WINE="$WINE" winetricks -q corefonts >/dev/null 2>&1 \
		|| die "winetricks corefonts failed; re-run manually to see why:
       WINEPREFIX=$PREFIX WINE=$WINE winetricks corefonts"
else
	info "Core fonts already installed"
fi

# ------------------------------------------------------------------- unpack app

# The NSIS installer exits silently under Wine without installing anything, so
# unpack its payload directly instead of trying to run it.
APPDIR="$PREFIX/drive_c/Program Files/$APP_NAME"
info "Unpacking application (~1.3 GB) to $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

"$SEVENZIP" e -bso0 -bsp0 -o"$TMPD" -- "$EXE" '$PLUGINSDIR/app-64.7z' \
	|| die "could not extract app-64.7z from the installer"
"$SEVENZIP" x -bso0 -bsp0 -y -o"$APPDIR" "$TMPD/app-64.7z" \
	|| die "could not unpack app-64.7z"
[ -f "$APPDIR/$APP_NAME.exe" ] || die "unpacked payload has no $APP_NAME.exe"

VERSION="$(basename "$EXE" | sed -n 's/.*x64-\(.*\)\.exe/\1/p')"
info "Installed $APP_NAME ${VERSION:-(unknown version)}"

# -------------------------------------------------------------------- launcher

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/$SLUG" <<EOF
#!/usr/bin/env bash
# Generated by install.sh from https://github.com/gregmatthewcrossley/xtool-studio-linux
#
# Do not repoint this at a stock distro Wine: anything older than
# ${MIN_WINE_MAJOR}.${MIN_WINE_MINOR} hangs before the window appears.
#
# Wine maps /dev/ttyUSB* and /dev/ttyACM* to COM ports by itself; no manual
# serial mapping is needed here.
#
# stdio MUST go to a regular file -- see the redirect on the exec line below.
# Node (inside Electron) cannot wrap a pipe or a socket as process.stderr under
# Wine: new Socket({fd:2}) fails with EBADF. Because Node initialises stderr
# lazily, this only bites when the app has an error to report, and it then
# replaces that error with a modal "A JavaScript error occurred in the main
# process" dialog -- hiding the very message you need. Launching from the
# desktop entry gives stdio a journald socket and '| tee' gives it a pipe; both
# fail. A regular file makes Node pick fs.SyncWriteStream instead, which works.
# So: keep '>', never '| tee', and never drop the redirect.
#
# --use-angle=vulkan is load-bearing for the workspace canvas. Without it ANGLE
# picks its D3D11 backend, which Wine cannot service: direct_composition fails,
# the GPU process dies 3x per launch with STATUS_BREAKPOINT
# (exit_code=-2147483645), and the renderer is left with no WebGL at all.
# Chromium removed the silent auto-fallback to software WebGL, so PixiJS throws
# "WebGL unsupported in this browser" and the editor canvas paints nothing --
# the app opens fine, but starting a new project shows a blank workspace.
# Routing ANGLE through winevulkan instead gives real GPU-backed WebGL.
#
# Do NOT substitute --use-angle=gl: on Windows builds that backend needs the
# WGL_NV_DX_interop2 extension, which Wine's opengl32 does not expose, and the
# app black-screens entirely.
export WINEPREFIX="$PREFIX"
export WINEDEBUG="\${WINEDEBUG:-fixme-all,err-all}"
export PATH="$WINE_ROOT/bin:\$PATH"

# One previous run is kept as .1 -- the log is chatty (~14k lines a launch).
LOG_DIR="\$HOME/.local/share/$SLUG/logs"
LOG="\$LOG_DIR/$SLUG.log"
mkdir -p "\$LOG_DIR"
[ -f "\$LOG" ] && mv -f "\$LOG" "\$LOG.1"

cd "$APPDIR" || exit 1
exec "$WINE" "$APP_NAME.exe" --no-sandbox --use-angle=vulkan "\$@" > "\$LOG" 2>&1
EOF
chmod +x "$BIN_DIR/$SLUG"
info "Launcher: $BIN_DIR/$SLUG"

# ------------------------------------------------------------------------ icon

ICON_NAME="$SLUG"
if [ "$HAVE_ICOTOOLS" -eq 1 ]; then
	mkdir -p "$ICON_DIR"
	if wrestool -x -t 14 "$APPDIR/$APP_NAME.exe" > "$TMPD/app.ico" 2>/dev/null \
		&& [ -s "$TMPD/app.ico" ] \
		&& icotool -x -i 1 -o "$ICON_DIR/$ICON_NAME.png" "$TMPD/app.ico" 2>/dev/null; then
		:
	else
		warn "could not extract the application icon; using a generic one"
		ICON_NAME="application-x-executable"
	fi
else
	warn "icoutils not installed; desktop entry will use a generic icon"
	warn "  (Fedora: sudo dnf install icoutils)"
	ICON_NAME="application-x-executable"
fi

# --------------------------------------------------------------- desktop entry

mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/$SLUG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=xTool laser/CNC software (Windows build running under Wine)
Exec=$BIN_DIR/$SLUG
Icon=$ICON_NAME
Terminal=false
Categories=Graphics;Engineering;
StartupWMClass=xtool studio.exe
EOF
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
info "Desktop entry: $DESKTOP_DIR/$SLUG.desktop"

# ----------------------------------------------------------------------- finish

echo
info "Done."
echo "    Launch from your application menu, or run: $SLUG"
if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
	echo
	warn "$BIN_DIR is not on your PATH; add it to use the 'xtool-studio' command."
fi
echo
echo "    First launch shows prompts to install CH340 and RNDIS drivers."
echo "    Dismiss them. Linux has both drivers in-kernel; installing the"
echo "    Windows ones inside Wine does nothing."
