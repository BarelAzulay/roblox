#!/bin/bash
# Double-click this file to start the Rojo server for Nimbus Climb (macOS).
# Rojo 7.7.1 matches the "Rojo 7.7.1" Studio plugin. Downloaded once, then reused.

cd "$(dirname "$0")" || exit 1

ROJO_VERSION="7.7.1"
ROJO_DIR="$HOME/Library/Application Support/NimbusClimb/rojo-$ROJO_VERSION"
ROJO_BIN="$ROJO_DIR/rojo"

finish() {
	echo
	read -r -p "Press Enter to close this window..." _
	exit "${1:-0}"
}

echo
echo " ===== Nimbus Climb - Rojo server ====="
echo

if [ ! -f "default.project.json" ]; then
	echo " ERROR: I can't find default.project.json next to this file."
	echo " Open the unzipped \"nimbus-climb\" folder and double-click this file from there."
	finish 1
fi

if [ ! -x "$ROJO_BIN" ]; then
	case "$(uname -m)" in
		arm64) ARCH="aarch64" ;;
		x86_64) ARCH="x86_64" ;;
		*)
			echo " ERROR: unsupported Mac processor: $(uname -m)"
			finish 1
			;;
	esac
	URL="https://github.com/rojo-rbx/rojo/releases/download/v$ROJO_VERSION/rojo-$ROJO_VERSION-macos-$ARCH.zip"
	echo " First run: downloading Rojo $ROJO_VERSION (about 5 MB). Please wait..."
	mkdir -p "$ROJO_DIR" || finish 1
	if ! curl -fsSL -o "$ROJO_DIR/rojo.zip" "$URL"; then
		echo
		echo " ERROR: the download failed. Check your internet connection and try again."
		finish 1
	fi
	unzip -o -q "$ROJO_DIR/rojo.zip" -d "$ROJO_DIR" && chmod +x "$ROJO_BIN"
	rm -f "$ROJO_DIR/rojo.zip"
	if [ ! -x "$ROJO_BIN" ]; then
		echo
		echo " ERROR: could not unpack Rojo."
		finish 1
	fi
fi

echo " Starting the Rojo server..."
echo
echo " NEXT STEPS"
echo "   1. Leave THIS window open. Closing it stops the server."
echo "   2. In Roblox Studio: open a Baseplate place, then Plugins > Rojo > Connect."
echo "   3. Press Play."
echo

"$ROJO_BIN" serve default.project.json
echo
echo " The Rojo server stopped."
finish 0
