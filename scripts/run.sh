#!/bin/sh
set -eu
unset CDPATH
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
swift run -j 2 Wallmotion
