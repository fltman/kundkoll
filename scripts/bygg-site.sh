#!/bin/bash
# Bygger produktsidan i site/: sätter ihop sidorna ur _topp + _sida + _botten,
# kopierar skärmbilderna ur docs/bilder och zippar appen till nedladdning/.
#
#   ./scripts/bygg-app.sh          # först: appen som ska laddas ner
#   ./scripts/bygg-site.sh         # sedan: site/ är klar att ladda upp
#
# Sidan är statisk — en vanlig webbserver räcker. Ladda upp hela site/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="dist/Bjarbys kundkoll.app"
ZIP="Bjarbys-kundkoll-$VERSION.zip"

echo "→ bilder"
mkdir -p site/bilder site/nedladdning
# Skärmbilderna är 2800 px breda retina-fångster; sidan visar dem som mest
# 1080 px breda, så 1600 px räcker med råge och väger en tredjedel.
for bild in docs/bilder/*.png; do
    sips -Z 1600 "$bild" --out "site/bilder/$(basename "$bild")" >/dev/null
done
VIDEO=nej
if [ -f docs/produktvideo.mp4 ]; then
    mkdir -p site/video
    # Videon i docs/ är arkivkvalitet (crf 18). Sidan får en lättare kodning,
    # ungefär en tredjedel så stor; byggs bara om när källan är nyare.
    if [ ! -f site/video/produktvideo.mp4 ] || [ docs/produktvideo.mp4 -nt site/video/produktvideo.mp4 ]; then
        echo "→ kodar videon för webben"
        ffmpeg -v error -y -i docs/produktvideo.mp4 -c:v libx264 -preset slow -crf 24 -profile:v high \
            -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 128k site/video/produktvideo.mp4
    fi
    [ -f docs/produktvideo-affisch.jpg ] && cp docs/produktvideo-affisch.jpg site/bilder/
    VIDEO=ja
fi

if [ -d "$APP" ]; then
    echo "→ zippar $APP"
    rm -f "site/nedladdning/$ZIP"
    # ditto bevarar signaturen och resursgafflarna; zip gör det inte.
    ditto -c -k --keepParent "$APP" "site/nedladdning/$ZIP"
    STORLEK="$(( ($(stat -f %z "site/nedladdning/$ZIP") + 524288) / 1048576 )) MB"
else
    echo "  (ingen app i dist/ — kör scripts/bygg-app.sh först; sidan byggs ändå)"
    STORLEK="?"
fi

echo "→ sidor"
sida() {
    local namn="$1" titel="$2" beskrivning="$3"
    { cat site/_topp.html; cat "site/_$namn.html"; cat site/_botten.html; } \
    | sed -e "s|TITEL|$titel|" -e "s|BESKRIVNING|$beskrivning|" \
          -e "s|VERSION|$VERSION|g" -e "s|ZIPNAMN|$ZIP|g" -e "s|STORLEK|$STORLEK|g" \
          -e "s|class=\"NAV_$namn\"|class=\"aktiv\"|" -e "s| class=\"NAV_[a-z-]*\"||g" \
    > "site/$namn.html"
    # Utan video: klipp bort avsnittet mellan markörerna på startsidan.
    if [ "$VIDEO" = nej ]; then
        sed -i '' '/<!-- VIDEO-START -->/,/<!-- VIDEO-SLUT -->/d' "site/$namn.html"
    fi
    echo "  site/$namn.html"
}
sida index        "Bjarbys kundkoll" "Spelar in möten, transkriberar lokalt och håller reda på vad som lovades — per kund och projekt, på din Mac."
sida ladda-ner    "Ladda ner · Bjarbys kundkoll" "Ladda ner Bjarbys kundkoll för macOS."
sida installation "Installation · Bjarbys kundkoll" "Så sätter du upp whisper.cpp, KB-Whisper, röstanalysen och Ollama."
sida manual       "Manual · Bjarbys kundkoll" "Så används Bjarbys kundkoll, vy för vy."
sida faq          "Vanliga frågor · Bjarbys kundkoll" "Vad som lämnar datorn, vad som krävs och hur saker hänger ihop."
echo "→ klart: site/ (version $VERSION)"
