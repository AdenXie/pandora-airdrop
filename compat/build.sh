#!/usr/bin/env bash
# build Pandora-XOS-Compat.apk (LSPosed module). env: SDK_STUB (android.jar), BUILD_TOOLS
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build; mkdir -p build/stubs build/classes build/dex dist
javac --release 8 -encoding UTF-8 -d build/stubs $(find stubs -name '*.java')
javac --release 8 -encoding UTF-8 -Xlint:-options -cp "$SDK_STUB:build/stubs" -d build/classes src/org/pandora/xoscompat/*.java
"$BUILD_TOOLS/d8" --lib "$SDK_STUB" --classpath build/stubs --min-api 33 --output build/dex build/classes/org/pandora/xoscompat/*.class
"$BUILD_TOOLS/aapt2" compile --dir res -o build/res.zip
"$BUILD_TOOLS/aapt2" link -I "$SDK_STUB" --manifest AndroidManifest.xml -A assets -o build/unsigned.apk build/res.zip
(cd build/dex && zip -q ../unsigned.apk classes.dex)
KS=${SIGN_KEYSTORE:-$HOME/.pandora-xoscompat.jks}
test -f "$KS" || keytool -genkeypair -keystore "$KS" -storepass pandora-local -keypass pandora-local -alias pandora -dname "CN=PandoraXosCompat" -keyalg RSA -validity 3650 >/dev/null 2>&1
"$BUILD_TOOLS/apksigner" sign --ks "$KS" --ks-pass pass:pandora-local --out dist/Pandora-XOS-Compat.apk build/unsigned.apk
"$BUILD_TOOLS/apksigner" verify dist/Pandora-XOS-Compat.apk && rm -f dist/*.idsig && sha256sum dist/Pandora-XOS-Compat.apk
