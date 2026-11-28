#!/usr/bin/env bash
# build fw-fetcher.zip (runs via Android app_process). env: SDK_STUB (android.jar), BUILD_TOOLS
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build dist; mkdir -p build/classes dist
javac --release 8 -encoding UTF-8 -d build/classes FwFetcher.java
"$BUILD_TOOLS/d8" --lib "$SDK_STUB" --min-api 33 --output dist/fw-fetcher.zip build/classes/*.class
sha256sum dist/fw-fetcher.zip
