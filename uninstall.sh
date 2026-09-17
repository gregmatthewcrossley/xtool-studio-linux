#!/usr/bin/env bash
#
# Remove everything install.sh created.
#
set -euo pipefail

SLUG="xtool-studio"
PREFIX="${WINEPREFIX:-$HOME/.local/share/wineprefixes/$SLUG}"
SUPPORT_DIR="$HOME/.local/share/$SLUG"
BIN="$HOME/.local/bin/$SLUG"
DESKTOP="$HOME/.local/share/applications/$SLUG.desktop"
ICON="$HOME/.local/share/icons/hicolor/256x256/apps/$SLUG.png"

KEEP_WINE=0
ASSUME_YES=0

usage() {
	cat <<'USAGE'
Usage: ./uninstall.sh [options]

Options:
  --keep-wine   Keep the downloaded Wine build, remove everything else.
  -y, --yes     Do not ask for confirmation.
  -h, --help    Show this help.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--keep-wine) KEEP_WINE=1; shift ;;
		-y|--yes)    ASSUME_YES=1; shift ;;
		-h|--help)   usage; exit 0 ;;
		*)           echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

targets=("$BIN" "$DESKTOP" "$ICON" "$PREFIX")
if [ "$KEEP_WINE" -eq 1 ]; then
	# --keep-wine keeps the downloaded Wine build, which lives in SUPPORT_DIR
	# alongside the launcher logs. The logs are ours, so drop them regardless.
	targets+=("$SUPPORT_DIR/logs")
else
	targets+=("$SUPPORT_DIR")
fi

echo "This will permanently delete:"
for t in "${targets[@]}"; do
	[ -e "$t" ] && echo "    $t" || echo "    $t  (not present)"
done
echo
echo "Your saved projects live inside the Wine prefix, under:"
echo "    $PREFIX/drive_c/users/$USER/"
echo "Back them up first if you want to keep them."
echo

if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Continue? [y/N] '
	read -r reply
	case "$reply" in
		[yY]|[yY][eE][sS]) ;;
		*) echo "Aborted."; exit 0 ;;
	esac
fi

# Stop anything still running in the prefix, so files are not held open.
if [ -d "$PREFIX" ] && command -v wineserver >/dev/null 2>&1; then
	WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
	sleep 1
fi
for ws in "$SUPPORT_DIR"/wine-*/bin/wineserver; do
	[ -x "$ws" ] || continue
	WINEPREFIX="$PREFIX" "$ws" -k 2>/dev/null || true
	sleep 1
done

for t in "${targets[@]}"; do
	rm -rf -- "$t"
done

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo "Removed."
