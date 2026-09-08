#!/bin/bash
# Tar en skärmbild av Bjarbys kundkoll och skriver ut sökvägen.
#
#   scripts/skarmbild.sh            # appfönstret
#   scripts/skarmbild.sh --starta   # startar om appen först
#
# Fönstret måste ligga framme. Ligger appen bakom släpper macOS dess backing
# store, och screencapture -l svarar "could not create image from window" — utan
# att något är fel med behörigheterna. Därför lyfts appen fram först.
#
# Det stjäl fokus ett ögonblick. Det är priset för att kunna se fönstret alls.
set -uo pipefail
cd "$(dirname "$0")/.."

UT="${TMPDIR:-/tmp}/kundkoll-skarmbild.png"
FORSOK="${FORSOK:-12}"

if [ "${1:-}" = "--starta" ]; then
    pkill -f "dist/Bjarbys kundkoll" 2>/dev/null
    sleep 1
    open "dist/Bjarbys kundkoll.app"
    sleep 3
fi

# Lyft fram fönstret. Absolut sökväg, annars kan open hitta en annan kopia.
open -a "$(pwd)/dist/Bjarbys kundkoll.app" 2>/dev/null
sleep 1.5

hitta_id() {
    osascript -l JavaScript -e '
        const app = Application("System Events");
        const p = app.processes.whose({name: "Kundkoll"});
        p.length ? "finns" : "";
    ' >/dev/null 2>&1
    # Fönster-ID via CoreGraphics-listan, samma väg som skärmbildsskillen
    /Users/andersbj/.claude/skills/screenshot/scripts/list_windows.sh 2>/dev/null \
        | awk -F'\t' '$2 == "Kundkoll" || $2 == "Bjarbys kundkoll" {print $1; exit}'
}

for ((i = 1; i <= FORSOK; i++)); do
    ID=$(hitta_id)
    if [ -z "$ID" ]; then
        sleep 1
        continue
    fi
    if screencapture -x -o -l "$ID" "$UT" 2>/dev/null && [ -s "$UT" ]; then
        # En bild på under 20 kB är i praktiken tom.
        STORLEK=$(stat -f%z "$UT")
        if [ "$STORLEK" -gt 20000 ]; then
            echo "$UT"
            exit 0
        fi
    fi
    sleep 1
done

# Fönstret gick inte att fånga — ta hela skärmen i stället, hellre det än inget.
if screencapture -x "$UT" 2>/dev/null && [ -s "$UT" ]; then
    echo "$UT"
    echo "(fönstret gick inte att fånga efter $FORSOK försök — hela skärmen i stället)" >&2
    exit 0
fi

echo "Kunde inte ta någon skärmbild. Har Terminal behörigheten Skärminspelning?" >&2
exit 1
