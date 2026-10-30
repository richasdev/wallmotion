#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
swift run Wallmotion
