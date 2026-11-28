#!/usr/bin/env bash
# build xos-bridge.zip (runs via Android app_process). env: SDK_STUB (android.jar), BUILD_TOOLS
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build dist; mkdir -p build/classes dist
javac --release 8 -encoding UTF-8 -cp "$SDK_STUB" -d build/classes XosBridge.java
"$BUILD_TOOLS/d8" --lib "$SDK_STUB" --min-api 33 --output dist/xos-bridge.zip build/classes/*.class
sha256sum dist/xos-bridge.zip
