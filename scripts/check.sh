#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
cargo test --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
cargo clippy --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native --all-targets -- -D warnings
swift test
