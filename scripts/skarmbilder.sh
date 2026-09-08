#!/bin/bash
# Tar dokumentationens och produktvideons skärmbilder ur demokunden, till docs/bilder/.
#
#   python3 scripts/demokund.py --elevenlabs --kalender   # först: demokunden måste finnas
#   scripts/demolive.py                                   # samtalet som spelas upp under livedemon
#   scripts/skarmbilder.sh                                # fotograferar
#
# Den vanliga appen stängs, och en demoinstans startas med KUNDKOLL_ROT
# pekande på en färsk kopia av demokunden — inga riktiga kunder i sidopanelen.
# Appen styrs via System Events: paletten (⌘K) för att hoppa, flikar och
# knappar via beskrivning, hjälptext eller accessibilityIdentifier (textknappar
# i SwiftUI exponerar ingen titel på macOS 26, därför har de knappar skriptet
# behöver en identifierare i koden). Bilderna tas som skärmområde över
# fönstret, så att blad, menyer och paneler kommer med. Sist spelas ett riktigt
# möte in: demolive-samtalet spelas upp genom högtalarna medan appen lyssnar
# på datorljudet, så att livetranskriptet och insikterna är på riktigt.
# Efteråt startas den vanliga appen igen.
set -uo pipefail
cd "$(dirname "$0")/.."
UT="docs/bilder"; mkdir -p "$UT"
APP="$(pwd)/dist/Bjarbys kundkoll.app"
BIN="$APP/Contents/MacOS/Kundkoll"
DEMO="${KUNDKOLL_DEMOROT:-/tmp/kundkoll-demo/Kunder}"
KALLA="$HOME/Documents/Kunder/Fjällbo Energi"
LIVE="$(dirname "$DEMO")/live.mp3"
KOD="$(dirname "$DEMO")/kod/matplattform"

# ---------------------------------------------------------------- demoroten
[ -d "$KALLA" ] || python3 scripts/demokund.py --elevenlabs
rm -rf "$DEMO"; mkdir -p "$DEMO"
cp -Rp "$KALLA" "$DEMO/"                      # -p: ändringstiderna avgör om lägesbilden räknas som gammal
# Uppgifterna pekar på mötesmappar med absolut sökväg — skriv om dem till kopian.
python3 - "$KALLA" "$DEMO/Fjällbo Energi" <<'EOF'
import sys, pathlib
gammal, ny = sys.argv[1], sys.argv[2]
for fil in pathlib.Path(ny).rglob("*.json"):
    t = fil.read_text(encoding="utf-8")
    if gammal in t:
        fil.write_text(t.replace(gammal, ny), encoding="utf-8")
EOF

# En liten kodbas att koppla till projektet Dataplattform, så att chatten
# har något att låta Claude Code genomsöka.
mkdir -p "$KOD/inlasning" "$KOD/rapport"
cat > "$KOD/README.md" <<'EOF'
# Mätplattform — Fjällbo Energi

Inläsning av elnätets mätvärden till Fabric, och veckorapporten som byggs ur dem.
Körs som en daglig pipeline: `python -m inlasning.elnat` läser gårdagens värden,
`python -m rapport.vecka` bygger rapporten varje måndag 06:00.
EOF
cat > "$KOD/inlasning/elnat.py" <<'EOF'
"""Läser elnätets mätvärden ur mätdatabasen och skriver dem till lagret i Fabric.

Mätvärdena hämtas per mätpunkt och timme. Varje körning tar gårdagen, och
en mätpunkt som saknar värden för mer än två timmar flaggas i loggen så att
driften ser det innan veckorapporten byggs.
"""
import datetime as dt
import logging

from .lager import Lager
from .matdatabas import Matdatabas

logg = logging.getLogger(__name__)
LUCKA_TIMMAR = 2


def las_dag(dag: dt.date, db: Matdatabas, lager: Lager) -> int:
    """Läser in en dags mätvärden. Returnerar antalet rader som skrevs."""
    rader = db.timvarden(dag)
    for punkt, varden in rader.items():
        saknade = 24 - len(varden)
        if saknade > LUCKA_TIMMAR:
            logg.warning("mätpunkt %s saknar %d timmar %s", punkt, saknade, dag)
    return lager.skriv("elnat_timvarden", rader)


def main() -> None:
    igar = dt.date.today() - dt.timedelta(days=1)
    antal = las_dag(igar, Matdatabas.fran_miljo(), Lager.fran_miljo())
    logg.info("%d rader inlästa för %s", antal, igar)


if __name__ == "__main__":
    main()
EOF
cat > "$KOD/inlasning/lager.py" <<'EOF'
"""Lagret i Fabric: ett lakehouse där varje tabell fylls på per dag."""
import os


class Lager:
    def __init__(self, arbetsyta: str, lakehouse: str) -> None:
        self.arbetsyta, self.lakehouse = arbetsyta, lakehouse

    @classmethod
    def fran_miljo(cls) -> "Lager":
        return cls(os.environ["FABRIC_ARBETSYTA"], os.environ.get("FABRIC_LAKEHOUSE", "matvarden"))

    def skriv(self, tabell: str, rader: dict) -> int:
        """Skriver rader till tabellen; en rad per mätpunkt och timme."""
        antal = sum(len(v) for v in rader.values())
        # Skrivningen görs med Fabrics Delta-API; utelämnad här.
        return antal
EOF
cat > "$KOD/inlasning/matdatabas.py" <<'EOF'
"""Mätdatabasen hos elnätet: SQL Server med en tabell per mätpunkt."""
import datetime as dt
import os


class Matdatabas:
    def __init__(self, dsn: str) -> None:
        self.dsn = dsn

    @classmethod
    def fran_miljo(cls) -> "Matdatabas":
        return cls(os.environ["MATDB_DSN"])

    def timvarden(self, dag: dt.date) -> dict[str, list[float]]:
        """Timvärden per mätpunkt för en dag, i kWh. Mätpunkter utan värden utelämnas."""
        return {}
EOF
cat > "$KOD/rapport/vecka.py" <<'EOF'
"""Veckorapporten: summerar elnätets timvärden per mätpunkt och dag.

Ersätter den Excel som byggdes för hand varje måndag. Rapporten skrivs
som en Fabric-rapport och som en pdf som mejlas till driften.
"""
import datetime as dt

from inlasning.lager import Lager


def veckorapport(vecka_slut: dt.date, lager: Lager) -> dict:
    """Summerar sju dagar bakåt från vecka_slut. Toppförbrukning per dag
    och total per mätpunkt; saknade timmar räknas som noll och märks."""
    dagar = [vecka_slut - dt.timedelta(days=i) for i in range(6, -1, -1)]
    return {"dagar": dagar, "summor": {}, "toppar": {}, "saknade": []}
EOF
# Koppla mappen till projektet Dataplattform.
python3 - "$DEMO/Fjällbo Energi/Projekt/Dataplattform/kopplade-mappar.json" "$KOD" <<'EOF'
import sys, json
json.dump([{"väg": sys.argv[2], "namn": "", "ändelser": [], "tillagd": "2026-08-22T09:00:00Z"}],
          open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
EOF

# ----------------------------------------------------------------- hjälpare
se() { osascript -e "tell application \"System Events\" to tell process \"Kundkoll\" to $1" 2>/dev/null; }
# Klickar det första elementet vars beskrivning, hjälptext, identifierare eller
# titel är den givna, var i fönstret det än ligger.
# osascript utan tidsgräns kan hänga i «entire contents» på ett fönster med
# mycket innehåll (livetranskriptet), därför larmar perl efter 25 sekunder.
osa() { perl -e 'alarm 25; exec @ARGV' osascript "$@"; }
klicka() {
    local svar
    svar=$(osa -e "tell application \"System Events\" to tell process \"Kundkoll\"
        -- «entire contents» måste hämtas till en lista först — itereras det
        -- som referens går varje uppslag i baklås och inget klickas.
        set alla to entire contents of window 1
        repeat with el in alla
            try
                if description of el is \"$1\" then
                    click el
                    return true
                end if
            end try
            try
                if help of el is \"$1\" then
                    click el
                    return true
                end if
            end try
            try
                if (value of attribute \"AXIdentifier\" of el) is \"$1\" then
                    click el
                    return true
                end if
            end try
            try
                if title of el is \"$1\" then
                    click el
                    return true
                end if
            end try
        end repeat
        return false
    end tell" 2>/dev/null)
    [ "$svar" = "true" ] || echo "  (hittade inget att klicka för «$1»)" >&2
    sleep "${2:-1.3}"
}
# Klickar mitt på den första statiska texten med det givna värdet — för rader
# och kort som inte är knappar.
klickaText() {
    local svar
    svar=$(osascript -e "tell application \"System Events\" to tell process \"Kundkoll\"
        set alla to entire contents of window 1
        repeat with el in alla
            try
                if class of el is static text and value of el is \"$1\" then
                    set {x, y} to position of el
                    set {w, h} to size of el
                    click at {x + w / 2, y + h / 2}
                    return true
                end if
            end try
        end repeat
        return false
    end tell" 2>/dev/null)
    [ "$svar" = "true" ] || echo "  (hittade ingen text «$1» att klicka på)" >&2
    sleep "${2:-1.3}"
}
# Klickar i det första textfältet i fönstret, så att tangenttryck hamnar där.
klickaFält() {
    osascript -e "tell application \"System Events\" to tell process \"Kundkoll\"
        set alla to entire contents of window 1
        repeat with el in alla
            try
                if class of el is text field then
                    click el
                    return true
                end if
            end try
        end repeat
        return false
    end tell" >/dev/null 2>&1
    sleep 0.8
}
# Rullar den första rullningsytan i fönstret till slutet (0) eller början (1).
rulla() {
    osascript -e "tell application \"System Events\" to tell process \"Kundkoll\"
        set alla to entire contents of window 1
        repeat with el in alla
            try
                if class of el is scroll area then
                    set value of scroll bar 1 of el to $1
                    return true
                end if
            end try
        end repeat
        return false
    end tell" >/dev/null 2>&1
    sleep 1.2
}
# Klickar på en skärmpunkt med ett riktigt musklick (CGEvent). Rader, kort och
# popupmenyer syns inte i tillgänglighetsträdet, och System Events «click at»
# når inte SwiftUI:s onTapGesture — därför scripts/hjalp/klick.swift. Punkterna
# är tagna ur bilderna: fönstret står alltid på 40,50 i 1400×800, så en punkt
# i skärmbilden (2×) blir 40 + x/2, 50 + y/2.
klickaVid() { swift scripts/hjalp/klick.swift "$1" "$2" 2>/dev/null; sleep "${3:-1.3}"; }
# Utfällningsraden (Bilagor) nås tvärtom bara av System Events klick, inte av musen.
klickaAX() { se "click at {$1, $2}"; sleep "${3:-1.3}"; }
skriv() { se "keystroke \"$1\""; sleep 0.5; }
tangent() { se "key code $1"; sleep "${2:-1}"; }       # 36 retur, 53 esc
palett() {
    se 'keystroke "k" using command down'; sleep 0.8
    se "keystroke \"$1\""; sleep 0.8
    se 'key code 36'; sleep 1.6
}
foto() {
    local ram; ram=$(se 'get {position, size} of window 1' | tr -d ' ')
    local x y w h; IFS=',' read -r x y w h <<< "$ram"
    screencapture -x -R "$x,$y,$w,$h" "$UT/$1.png" && echo "  $UT/$1.png"
}
fotoRuta() { screencapture -x -R "$2" "$UT/$1.png" && echo "  $UT/$1.png"; }
verktyg() { se "click (first button of toolbar 1 of window 1 whose description is \"$1\")"; sleep "${2:-1.5}"; }
ram() { se 'set position of window 1 to {40, 50}'; se 'set size of window 1 to {1400, 800}'; sleep 0.8; }

# ------------------------------------------------------------------- start
pkill -f "dist/Bjarbys kundkoll" 2>/dev/null; sleep 3
KUNDKOLL_ROT="$DEMO" "$BIN" >/dev/null 2>&1 &
DEMOPID=$!
sleep 6
se 'set frontmost to true'; sleep 1; ram

# Kunden: översikten och flikarna.
palett "Fjällbo";        foto oversikt
klicka "avsnitt.Hantera" 2;  foto kontakter
klickaVid 456 412 2;   foto kontakt                 # raden «Karin Lindqvist» i Hantera-bladet
klicka "kontakt.avbryt"; klicka "kontakter.klar"
klicka "möte.förbered" 2;    foto brief
klicka "brief.stäng"
klicka "Att göra";       foto tavla
klickaVid 396 632 2;   foto uppgift                 # kortet «Ta fram driftkostnad per månad»
tangent 53
klickaVid 1230 179 1.2; foto tavla-person; tangent 53   # personmenyn
klicka "Inspelningar";   foto inspelningar
klicka "avsnitt.Lägg till" 2; foto import
klicka "import.avbryt"
klicka "Anteckningar";   foto anteckningar
klickaVid 400 210 2;   foto anteckning              # raden «Bakgrund och nuläge»
klicka "anteckning.klar"
klicka "Mail";           foto mail
klickaAX 369 628 1.5;  foto mail-bilagor            # raden «Bilagor · 4 av 4 sökbara»
klickaAX 369 628 1                                     # …och ihop igen, läget minns till nästa körning
klicka "Översikt"

# Min vecka, sökningen och paletten.
palett "Min vecka";      foto min-vecka
se 'keystroke "f" using {command down, shift down}'; sleep 1.5
skriv "Fabric"; sleep 2.5; foto sok; tangent 53
se 'keystroke "k" using command down'; sleep 0.8; skriv "upp"; sleep 1.2; foto palett; tangent 53

# Projektet: läget, mötena, kopplade mappar, tiden.
palett "Dataplattform";  foto projekt
klicka "Tid";            foto tid
klicka "Översikt"

# Mötesvyn: sammanfattningen, transkriptet med spelaren igång, att göra,
# efterbearbetningsmenyn och Vem är vem.
palett "Uppstart";       foto mote
klicka "Transkript"
klicka "Spela upp mötet" 5
foto mote-transkript
klicka "Pausa"
klicka "Att göra 3";     foto mote-attgora
klicka "arrow.trianglehead.2.clockwise" 1.5; foto mote-efterbearbeta; tangent 53
klicka "möte.vem-är-vem" 4
foto vem-ar-vem
klicka "röster.avbryt"
klicka "möte.stäng"

# Chattpanelen: det sparade samtalet hos kunden, och en ny fråga i projektet
# som också går till den kopplade kodmappen.
palett "Fjällbo"
verktyg "Chatt" 2;       foto chatt
verktyg "Chatt" 1
palett "Dataplattform"
verktyg "Chatt" 2;       foto projekt-mappar          # projektet med kopplade mappar och chattpanelen
klicka "Nytt samtal" 1
klickaVid 1230 820 0.8                                    # frågefältet längst ned i panelen
skriv "Hur räknas veckorapporten fram, och vad händer om en mätpunkt saknar timmar?"
tangent 36 50
foto chatt-mapp
verktyg "Chatt" 1

# Inställningarna, flik för flik.
se 'keystroke "," using command down'; sleep 1.5
klicka "Modell" 1.5;         foto installningar-modell
klicka "Transkribering" 1.5; foto installningar-transkribering
klicka "Röster och insikter" 1.5; foto installningar-roster
klicka "Diagnos"; sleep 4;   foto installningar
klicka "inställningar.avbryt"

# Om-rutan.
se 'click menu item 1 of menu 1 of menu bar item 2 of menu bar 1'; sleep 2
foto om
klicka "om.stäng"

# Finder och Obsidian: samma kund som filer och som valv.
osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
    activate
    set w to make new Finder window to (POSIX file "$KALLA" as alias)
    set current view of w to list view
    set sidebar width of w to 0
    set bounds of w to {40, 50, 1240, 720}
end tell
EOF
sleep 2; fotoRuta finder "40,50,1200,670"
osascript -e 'tell application "Finder" to close front window' >/dev/null 2>&1
python3 - "$KALLA" <<'EOF'
# Obsidian öppnar bara filer i valv den känner till — registrera kundens valv,
# precis som appens «Öppna i Obsidian» gör.
import json, sys, time, pathlib, hashlib
fil = pathlib.Path.home() / "Library/Application Support/obsidian/obsidian.json"
d = json.loads(fil.read_text()) if fil.exists() else {"vaults": {}}
väg = sys.argv[1]
if not any(v.get("path") == väg for v in d["vaults"].values()):
    d["vaults"][hashlib.md5(väg.encode()).hexdigest()[:16]] = {"path": väg, "ts": int(time.time() * 1000)}
    fil.write_text(json.dumps(d))
EOF
open "obsidian://open?path=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$KALLA/Projekt/Dataplattform/Inspelningar/2026-08-20 0930 Uppstart dataplattform/Transkript.md")"
sleep 6
osascript -e 'tell application "System Events" to tell process "Obsidian"
    set frontmost to true
    set position of window 1 to {40, 50}
    set size of window 1 to {1400, 800}
end tell' >/dev/null 2>&1; sleep 1.5
fotoRuta obsidian "40,50,1400,800"
osascript -e 'tell application "Obsidian" to quit' >/dev/null 2>&1; sleep 1
se 'set frontmost to true'; sleep 1

# Inspelningsfönstret, och sedan ett riktigt möte: demolive-samtalet spelas
# upp genom högtalarna medan appen fångar datorljudet. Mikrofonen tystas och
# högtalarna dämpas — ScreenCaptureKit fångar ljudet ändå.
palett "Fjällbo"
verktyg "Spela in" 2
ram;                     foto inspelning
if [ -f "$LIVE" ]; then
    UTVOL=$(osascript -e 'output volume of (get volume settings)')
    INVOL=$(osascript -e 'input volume of (get volume settings)')
    osascript -e 'set volume input volume 0' -e 'set volume output volume 6'
    klicka "inspelning.starta" 5
    ram
    afplay "$LIVE" & AFPID=$!
    sleep 32;            foto live-transkript
    sleep 34;            foto live-insikt
    wait $AFPID 2>/dev/null; sleep 4
    klickaVid 1378 820 4                                  # Stoppa — tillgänglighetsträdet hänger på livefönstret
    osascript -e "set volume input volume $INVOL" -e "set volume output volume $UTVOL"
else
    echo "  (ingen $LIVE — kör scripts/demolive.py för livebilderna)" >&2
    klicka "inspelning.avbryt"
fi

kill "$DEMOPID" 2>/dev/null; sleep 2
open -a "$APP"
echo "klart"
