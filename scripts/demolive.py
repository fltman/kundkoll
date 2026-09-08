#!/usr/bin/env python3
"""Ett kort samtal att spela upp under en livedemo av inspelningen.

    set -a; source ~/Projekt/aipresenter/.env; set +a
    scripts/demolive.py                      # → /tmp/kundkoll-demo/live.mp3
    scripts/demolive.py --ut fil.mp3

Karin och Sara hos Fjällbo Energi pratar, och undrar över sådant som står i
kundens material — licenskostnaden i offerten och biträdesavtalet — så att
insiktspanelen har något att slå upp. Rösterna är samma som demokund.py
valde (sparade i kundens .kundkoll/demoröster.json), så att «Vem är vem»
känner igen dem. Ljudet görs av elevenlabs-skillens generate_dialogue.py,
hela samtalet i ett anrop, så att repliker och pauser hänger ihop.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SKILL = Path(os.environ.get("ELEVENLABS_SKILL") or Path.home()
             / "Projekt/hooklinecoder/.claude/skills/elevenlabs-skill/scripts/generate_dialogue.py")
DEMOROT = Path(os.environ.get("KUNDKOLL_DEMOROT") or "/tmp/kundkoll-demo/Kunder")
# Rösterna läses ur den riktiga demokunden — kopian i demoroten byggs om av skarmbilder.sh.
KUND = Path(os.environ.get("KUNDKOLL_ROT") or Path.home() / "Documents/Kunder") / "Fjällbo Energi"

SAMTAL = [
    ("Karin Lindqvist", "Hej Anders, kul att du kunde. Sara är med också. Vi tänkte stämma av läget innan styrgruppen."),
    ("Sara Holm", "Inläsningen av elnätets mätvärden går bra. Jag har fått in tre veckors data i lagret nu, och veckorapporten byggs av det."),
    ("Karin Lindqvist", "Bra. En sak jag måste ha till ledningsgruppen: vad var det Fabric-licensen kostade per månad enligt offerten?"),
    ("Sara Holm", "Jag minns inte på rak arm, det stod i offerten som Anders skickade."),
    ("Karin Lindqvist", "Okej, vi kollar. Och personuppgiftsbiträdesavtalet, vad var det Erik ville ha ändrat i utkastet?"),
    ("Sara Holm", "Något om lagringstiden tror jag. Vi tar det när vi har mejlet framför oss."),
    ("Karin Lindqvist", "Då gör vi så. Sara, kan du skicka mätvärdena för augusti till Anders före måndag?"),
    ("Sara Holm", "Absolut, det fixar jag i morgon."),
]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ut", default=str(DEMOROT.parent / "live.mp3"))
    val = p.parse_args()
    if not os.environ.get("ELEVENLABS_API_KEY"):
        sys.exit("ELEVENLABS_API_KEY saknas i miljön")
    if not SKILL.is_file():
        sys.exit(f"hittar inte elevenlabs-skillen: {SKILL}")
    röster = json.loads((KUND / ".kundkoll" / "demoröster.json").read_text())
    dialog = [{"text": text, "voice_id": röster[talare]} for talare, text in SAMTAL]
    ut = Path(val.ut); ut.parent.mkdir(parents=True, exist_ok=True)
    infil = ut.with_suffix(".json")
    infil.write_text(json.dumps(dialog, ensure_ascii=False, indent=2), encoding="utf-8")
    svar = subprocess.run([sys.executable, str(SKILL), "--input", str(infil), "--output", str(ut)],
                          capture_output=True, text=True)
    if svar.returncode != 0 or not ut.is_file():
        sys.exit("skillen misslyckades:\n" + (svar.stdout + svar.stderr)[-800:])
    längd = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(ut)],
                           capture_output=True, text=True).stdout.strip()
    print(f"klart: {ut} ({float(längd):.0f} s)")


if __name__ == "__main__":
    main()
