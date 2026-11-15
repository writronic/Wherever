#!/bin/sh
set -eu
: "${CARGO_TARGET_DIR:?set CARGO_TARGET_DIR to a Cargo output folder outside the source tree}"
export MACOSX_DEPLOYMENT_TARGET=13.0
cd "$(dirname "$0")/.."
OUT=$(pwd)/WhereverKit/Engine
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$(pwd)=/wherever"
T=$CARGO_TARGET_DIR
GEN=$T/wherever-gen
UNIVERSAL=$T/universal/libwherever_core.a
cd Engine

cargo build --release -p wherever-core --target aarch64-apple-darwin
cargo build --release -p wherever-core --target x86_64-apple-darwin
cargo build --release -p wherever-cli --bin wherever --target aarch64-apple-darwin
cargo build --release -p wherever-cli --bin wherever --target x86_64-apple-darwin

mkdir -p "$T/universal" "$OUT"
lipo -create \
  "$T/aarch64-apple-darwin/release/libwherever_core.a" \
  "$T/x86_64-apple-darwin/release/libwherever_core.a" \
  -output "$UNIVERSAL"
lipo -create \
  "$T/aarch64-apple-darwin/release/wherever" \
  "$T/x86_64-apple-darwin/release/wherever" \
  -output "$OUT/wherever"
for BINARY in "$UNIVERSAL" "$OUT/wherever"; do
  ARCHS=$(file "$BINARY")
  echo "$ARCHS"
  case $ARCHS in
    *"universal binary with 2 architectures"*) ;;
    *) echo "build-engine: expected a universal binary with 2 architectures in $BINARY" >&2; exit 1 ;;
  esac
done

LIB=$T/aarch64-apple-darwin/release/libwherever_core.a
FFI=wherever_coreFFI
rm -rf "$GEN"
cargo run -q -p uniffi-bindgen-swift -- "$LIB" "$GEN/swift" --swift-sources
cargo run -q -p uniffi-bindgen-swift -- "$LIB" "$GEN/Headers/$FFI" \
  --headers --modulemap --module-name "$FFI" --modulemap-filename module.modulemap
grep -qx "import $FFI" "$GEN/swift/wherever_core.swift" || {
  echo "build-engine: the generated Swift does not import $FFI" >&2
  exit 1
}

rm -rf "$OUT/WhereverCore.xcframework"
xcodebuild -create-xcframework \
  -library "$UNIVERSAL" \
  -headers "$GEN/Headers" \
  -output "$OUT/WhereverCore.xcframework"
cp "$GEN/swift/"*.swift "$OUT/"
