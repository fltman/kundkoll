#!/bin/bash
# Bygger Bjarbys kundkoll.app. Xcode behövs inte — Command Line Tools räcker.
set -euo pipefail
cd "$(dirname "$0")/.."

KONFIG="${1:-release}"
APP="dist/Bjarbys kundkoll.app"
# Eget certifikat: KUNDKOLL_SIGNERING="Developer ID Application: Ditt AB (XXXXXXXXXX)"
IDENTITET="${KUNDKOLL_SIGNERING:-Developer ID Application: Brattoo AB (V783A2L763)}"

echo "→ kompilerar ($KONFIG)"
swift build -c "$KONFIG" --disable-sandbox

# Bash tillåter bara ASCII i variabelnamn, till skillnad från zsh.
BIN="$(swift build -c "$KONFIG" --show-bin-path)/Kundkoll"

echo "→ paketerar"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kundkoll"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Kundkoll.icns "$APP/Contents/Resources/Kundkoll.icns"
# Röstanalysen körs som en Pythonprocess; skriptet måste följa med appen.
cp scripts/rostanalys.py "$APP/Contents/Resources/rostanalys.py"
cp Resources/mail-sok.applescript "$APP/Contents/Resources/mail-sok.applescript"
cp Resources/mail-bilagor.applescript "$APP/Contents/Resources/mail-bilagor.applescript"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ signerar"
# En stabil signatur gör att macOS kommer ihåg beviljade behörigheter
# mellan ombyggen i stället för att fråga om mikrofon och skärminspelning varje gång.
if security find-identity -v -p codesigning | grep -q "$IDENTITET"; then
    codesign --force --deep --options runtime --timestamp=none \
        --entitlements Resources/Kundkoll.entitlements \
        --sign "$IDENTITET" "$APP"
else
    echo "  (certifikatet hittades inte — signerar ad hoc, behörigheter kan behöva ges om vid varje bygge)"
    codesign --force --deep --sign - \
        --entitlements Resources/Kundkoll.entitlements "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo "→ klart: $APP"
