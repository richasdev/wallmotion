#!/bin/sh
set -eu
# Do not let shell directory search select a different project.
unset CDPATH
wallmotion_script_dir=$(dirname "$0")
if [ -L "$wallmotion_script_dir" ]; then
    printf 'Limpeza recusada: a pasta do script é um link simbólico.\n' >&2
    exit 2
fi
cd "$wallmotion_script_dir/.."
wallmotion_root=$(pwd -P)

case "${1:-}" in
    "") wallmotion_clean_all=0 ;;
    --all) wallmotion_clean_all=1 ;;
    *)
        printf 'Uso: sh scripts/clean-builds.sh [--all]\n' >&2
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    printf 'Uso: sh scripts/clean-builds.sh [--all]\n' >&2
    exit 2
fi

# Complete preflight before the first cleaner runs. A link in an ancestor can
# redirect even an explicit --target-dir outside this checkout.
for wallmotion_path in .build .build/native crates crates/wallmotion-media crates/wallmotion-media/target; do
    if [ -L "$wallmotion_path" ] || { [ -e "$wallmotion_path" ] && [ ! -d "$wallmotion_path" ]; }; then
        printf 'Limpeza recusada: %s precisa ser uma pasta real deste checkout.\n' "$wallmotion_path" >&2
        exit 2
    fi
    if [ -d "$wallmotion_path" ]; then
        wallmotion_canonical=$(cd "$wallmotion_path" && pwd -P)
        case "$wallmotion_canonical" in
            "$wallmotion_root"/*) ;;
            *)
                printf 'Limpeza recusada: %s está fora da raiz do checkout.\n' "$wallmotion_path" >&2
                exit 2
                ;;
        esac
    fi
done
for wallmotion_path in Package.swift crates/wallmotion-media/Cargo.toml; do
    if [ -L "$wallmotion_path" ] || [ ! -f "$wallmotion_path" ]; then
        printf 'Limpeza recusada: %s precisa ser um arquivo real do projeto.\n' "$wallmotion_path" >&2
        exit 2
    fi
done

if [ "$wallmotion_clean_all" -eq 1 ]; then
    # Full project cleanup; the packaged app in dist/ is preserved.
    cargo clean --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
    # SwiftPM may let this inherited variable override even --scratch-path.
    # Only this script process is changed; the caller's environment is intact.
    unset SWIFTPM_BUILD_DIR
    swift package --scratch-path .build clean
else
    # Between validation cycles, preserve release artifacts used by Swift.
    cargo clean --profile dev --manifest-path crates/wallmotion-media/Cargo.toml --target-dir .build/native
fi

# Duplicate Cargo target in this checkout, validated before either cleaner ran.
if [ -d crates/wallmotion-media/target ]; then
    cargo clean --manifest-path crates/wallmotion-media/Cargo.toml --target-dir crates/wallmotion-media/target
fi
