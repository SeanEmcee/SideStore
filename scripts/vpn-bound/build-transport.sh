#!/bin/bash
set -euo pipefail
cd build/idevice
rustfmt --edition 2024 ffi/src/vpn_binding.rs ffi/src/tunnel_provider.rs
# Native Darwin tests exercise actual scoped sockets and reject an invalid interface.
cargo test --locked -p idevice-ffi --lib vpn_binding::tests
cd ffi
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  cargo build --locked --release --target aarch64-apple-ios --features obfuscate
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  cargo build --locked --release --target aarch64-apple-ios-sim
cd ..
cp ffi/idevice.h swift/include/idevice.h
grep -q tunnel_create_rppairing_with_options_bound swift/include/idevice.h
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libidevice_ffi.a -headers swift/include \
  -library target/aarch64-apple-ios-sim/release/libidevice_ffi.a -headers swift/include \
  -output swift/IDevice.xcframework
