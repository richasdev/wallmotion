#!/bin/sh
set -eu
unset CDPATH
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --locked --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
