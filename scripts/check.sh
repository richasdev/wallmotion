#!/bin/sh
set -eu
unset CDPATH
cd "$(dirname "$0")/.."
export CARGO_INCREMENTAL=0
sh scripts/build-native.sh
cargo test --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
cargo clippy --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native --all-targets -- -D warnings
python3 -m unittest discover -s Tests -p 'test_*.py'
swift test -j 2
