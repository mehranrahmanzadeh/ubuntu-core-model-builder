#!/usr/bin/env bash
# Builds the Rust auth backend (libsnapstore_auth) and stages it next to the
# Flutter app's Linux executable so the FFI client finds it at runtime.
#
# Usage:
#   ./scripts/build_rust_backend.sh [path/to/snapstore-auth]
#
# The default crate location is /root/snapstore-auth (adjust or pass the
# path). The resulting shared library is copied to
#   linux/rust/libsnapstore_auth.so
# and into build/linux/x64/<config>/libsnapstore_auth.so when that tree
# exists (so `flutter run` picks it up without extra flags).
set -euo pipefail

CRATE_DIR="${1:-/root/snapstore-auth}"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

echo ">> cargo build --release ($CRATE_DIR)"
cd "$CRATE_DIR"
cargo build --release

SO="target/release/libsnapstore_auth.so"
[ -f "$SO" ] || { echo "missing $SO" >&2; exit 1; }

# Stage for `flutter run` / packaged app.
mkdir -p "$APP_DIR/linux/rust"
cp -f "$SO" "$APP_DIR/linux/rust/libsnapstore_auth.so"
echo ">> staged: $APP_DIR/linux/rust/libsnapstore_auth.so"

for cfg in debug release; do
  dst="$APP_DIR/build/linux/x64/$cfg"
  if [ -d "$dst" ]; then
    cp -f "$SO" "$dst/libsnapstore_auth.so"
    echo ">> staged: $dst/libsnapstore_auth.so"
  fi
done

echo ">> done. Run the app normally; for a manual build set:"
echo "   SNAPSTORE_AUTH_LIB=$PWD/linux/rust/libsnapstore_auth.so"
