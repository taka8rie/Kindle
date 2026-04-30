#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
EXECUTABLE_PATH="$BUILD_DIR/Kindle"
HELPER_SRC="$ROOT_DIR/Helpers/mtp-kindle-ls.c"
HELPER_BUILD="$ROOT_DIR/.build/mtp-kindle-ls"
APP_NAME="Kindle 导书助手"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LIBMTP_PREFIX="${LIBMTP_PREFIX:-}"

if [[ -z "$LIBMTP_PREFIX" ]]; then
  for candidate in /opt/homebrew/opt/libmtp /usr/local/opt/libmtp; do
    if [[ -d "$candidate/include" && -d "$candidate/lib" ]]; then
      LIBMTP_PREFIX="$candidate"
      break
    fi
  done
fi

echo "Building release binary..."
cd "$ROOT_DIR"
swift build -c release

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Release executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

if [[ -z "$LIBMTP_PREFIX" ]]; then
  echo "libmtp headers not found. Please run: brew install libmtp" >&2
  exit 1
fi

echo "Building MTP helper..."
clang -O2 -Wall -Wextra \
  -I"$LIBMTP_PREFIX/include" \
  "$HELPER_SRC" \
  -L"$LIBMTP_PREFIX/lib" \
  -Wl,-rpath,"$LIBMTP_PREFIX/lib" \
  -lmtp \
  -o "$HELPER_BUILD"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/Kindle"
cp "$HELPER_BUILD" "$MACOS_DIR/mtp-kindle-ls"
chmod +x "$MACOS_DIR/Kindle"
chmod +x "$MACOS_DIR/mtp-kindle-ls"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo
echo "App created:"
echo "$APP_DIR"
