#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

case "${1:-}" in
    "")
        # Run between validation cycles. Preserve release artifacts used by Swift.
        cargo clean --profile dev --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
        ;;
    --all)
        # Explicit full project cleanup; the packaged app in dist/ is preserved.
        cargo clean --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
        swift package clean
        ;;
    *)
        printf 'Uso: sh scripts/clean-builds.sh [--all]\n' >&2
        exit 2
        ;;
esac

# Also remove a duplicate target produced by running Cargo directly in the crate.
if [ -d crates/wallmotion-media/target ]; then
    cargo clean --manifest-path crates/wallmotion-media/Cargo.toml --target-dir crates/wallmotion-media/target
fi
