#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT/rust"
OUT_DIR="$ROOT/Frameworks"
HEADERS_DIR="$ROOT/include"
BUILD_DIR="$ROOT/build"
PROFILE="${SHAKE_FEEDBACK_PROFILE:-release}"

export PATH="$HOME/.cargo/bin:$PATH"

profile_flag=()
profile_dir="debug"
if [ "$PROFILE" = "release" ]; then
  profile_flag=(--release)
  profile_dir="release"
fi

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios >/dev/null

cargo build --manifest-path "$RUST_DIR/Cargo.toml" --target aarch64-apple-ios "${profile_flag[@]}"
cargo build --manifest-path "$RUST_DIR/Cargo.toml" --target aarch64-apple-ios-sim "${profile_flag[@]}"
cargo build --manifest-path "$RUST_DIR/Cargo.toml" --target x86_64-apple-ios "${profile_flag[@]}"

rm -rf "$OUT_DIR/ShakeFeedbackCore.xcframework"
mkdir -p "$OUT_DIR"
rm -rf "$BUILD_DIR/ios-simulator"
mkdir -p "$BUILD_DIR/ios-simulator"

lipo -create \
  "$RUST_DIR/target/aarch64-apple-ios-sim/$profile_dir/libshake_feedback_core.a" \
  "$RUST_DIR/target/x86_64-apple-ios/$profile_dir/libshake_feedback_core.a" \
  -output "$BUILD_DIR/ios-simulator/libshake_feedback_core.a"

xcodebuild -create-xcframework \
  -library "$RUST_DIR/target/aarch64-apple-ios/$profile_dir/libshake_feedback_core.a" \
  -headers "$HEADERS_DIR" \
  -library "$BUILD_DIR/ios-simulator/libshake_feedback_core.a" \
  -headers "$HEADERS_DIR" \
  -output "$OUT_DIR/ShakeFeedbackCore.xcframework"

echo "Built $OUT_DIR/ShakeFeedbackCore.xcframework"
