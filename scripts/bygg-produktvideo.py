#!/usr/bin/env python3
"""Bygger produktvideon ur skärmbilderna och manuset.

    set -a; source ~/Projekt/aipresenter/.env; set +a   # ELEVENLABS_API_KEY i miljön
    scripts/bygg-produktvideo.py                        # → docs/produktvideo.mp4 + docs/produktvideo-affisch.jpg
    scripts/bygg-produktvideo.py --utan-ljud            # stum video, ingen nyckel behövs
    scripts/bygg-produktvideo.py --bara-kort            # ritar bara titel- och slutkortet, för att titta

Manuset i docs/produktvideo-manus.md styr allt: vilka bilder som visas, i vilken
ordning, vad som sägs och vilken röst som läser. Ändras en skärmbild räcker det
att köra om skriptet. Berättarljudet ligger kvar i arbetskatalogen, en fil per
rad, hashad på röst och text — oförändrade rader hämtas inte om från ElevenLabs.

Så byggs videon:
  1. Varje skärmbild får fönstrets rundade hörn maskade mot den mörka botten
     (utanför hörnen syns annars några pixlar skrivbord), skalas in i en
     16:9-yta med bevarade proportioner och får en långsam zoom på 3 %.
  2. Titel- och slutkort ritas med Pillow: appikonen och texterna ur manuset.
  3. Varje bild ligger kvar så länge dess berättarstycke varar plus 0,8 s.
     Bilderna tonar över i varandra på 0,5 s; första tonar in från svart,
     sista tonar ut till svart.
  4. Ljudet läggs på sina tidpunkter, videon kodas till H.264 + AAC, och
     affischen tas ur första hela bildrutan efter titelkortet.

Rösten görs av elevenlabs-skillens generate_dialogue.py (ElevenLabs dialog-API),
ett stycke i taget så att varje bild kan tajmas mot sitt stycke. Skillen har en
egen cache per stycke, så oförändrad text hämtas inte om.

Miljö:   ELEVENLABS_API_KEY  nyckeln — läses av skillen ur miljön och skrivs aldrig ut
         ELEVENLABS_SKILL    sökväg till skillens generate_dialogue.py (standard: se SKILL nedan)
         KUNDKOLL_VIDEOROT   arbetskatalog för mellanfiler (standard .build/produktvideo)
Kräver:  ffmpeg och ffprobe (/opt/homebrew/bin), Python 3 med Pillow och paketet elevenlabs.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROT = Path(__file__).resolve().parent.parent
MANUS = ROT / "docs" / "produktvideo-manus.md"
IKON = ROT / "site" / "bilder" / "ikon.png"
UT_VIDEO = ROT / "docs" / "produktvideo.mp4"
UT_AFFISCH = ROT / "docs" / "produktvideo-affisch.jpg"
ARBETE = Path(os.environ.get("KUNDKOLL_VIDEOROT") or ROT / ".build" / "produktvideo")

# Homebrews ffmpeg först, annars det som finns i PATH.
_SOK = "/opt/homebrew/bin:" + os.environ.get("PATH", "")
FFMPEG = shutil.which("ffmpeg", path=_SOK) or "ffmpeg"
FFPROBE = shutil.which("ffprobe", path=_SOK) or "ffprobe"

# Bild
BREDD, HOJD, FPS = 1920, 1080, 30
# Zoomen görs av ffmpeg:s zoompan, som flyttar beskärningen i hela bildpunkter.
# I utdatans storlek syns stegen som ett litet hack; på en fyra gånger större
# arbetsyta blir varje steg en kvarts bildpunkt och rörelsen ser mjuk ut.
KANVAS = (BREDD * 4, HOJD * 4)
BOTTEN = "#101012"                      # samma mörka botten som sajten
TEXT, DAMPAD, ACCENT = "#f5f5f7", "#a1a1a6", "#4c8dff"   # sajtens mörka läge, site/stil.css
ZOOM = 0.03                             # 3 % in under bildens visningstid
HORNRADIE = 40                          # fönstrets hörnradie i skärmbilderna (retina, 2×), i bildpunkter

# Tid (sekunder)
TONING = 0.5        # övertoning mellan bilderna
PAUS = 0.8          # bilden ligger kvar berättarstycket + detta
FORSPRANG = 0.3     # ...varav så här mycket före stycket börjar, resten efter
INTRO = 0.8         # titelkortet: svart → in, berättaren börjar här
INTONING = 0.6      # längden på intoningen från svart
UTGANG = 1.5        # slutkortet ligger kvar så här länge efter sista ordet
UTTONING = 0.8      # ...och tonar sedan ut till svart

# Röst: elevenlabs-skillen. Skriptet kopieras inte hit — det är skillen som äger
# hur ElevenLabs anropas, och den byts ut på ett ställe.
SKILL = Path(os.environ.get("ELEVENLABS_SKILL") or Path.home()
             / "Projekt/hooklinecoder/.claude/skills/elevenlabs-skill/scripts/generate_dialogue.py")
TALTAKT = 14.0      # tecken per sekund — bara för stum video, där ljudlängden får gissas


@dataclass
class Avsnitt:
    nr: int
    typ: str                       # "bild" eller "kort"
    bild: Path | None              # skärmbilden, för typ "bild"
    kortrader: list[str]           # texterna på kortet, för typ "kort"
    text: str                      # berättartexten
    ljud: Path | None = None       # mp3 (None utan ljud)
    ljudlangd: float = 0.0
    klipp: Path | None = None
    langd: float = 0.0             # klippets längd inklusive övertoningar
    start: float = 0.0             # var i den färdiga videon klippet börjar
    talstart: float = 0.0          # var i den färdiga videon berättaren börjar


def kor(kommando, **extra):
    """Kör ett kommando och stannar med ffmpegs felutskrift om det går fel."""
    svar = subprocess.run(kommando, capture_output=True, text=True, **extra)
    if svar.returncode != 0:
        sys.exit(f"fel i {kommando[0]}:\n{svar.stderr[-3000:]}")
    return svar


def ljudlangd(fil: Path) -> float:
    svar = kor([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(fil)])
    return float(svar.stdout.strip())


def las_manus(sokvag: Path) -> tuple[str, list[Avsnitt]]:
    """Plockar röst-id och bildmanuset ur markdown-filen."""
    text = sokvag.read_text(encoding="utf-8")
    rost = re.search(r"^Röst-id:\s*(\S+)", text, re.M)
    if not rost:
        sys.exit(f"{sokvag}: hittar ingen rad «Röst-id: …»")
    # Bara det som står efter rubriken «Bildmanus» är bilder.
    _, _, kropp = text.partition("## Bildmanus")
    avsnitt = []
    for block in re.split(r"^(?=\d+\.\s)", kropp, flags=re.M):
        m = re.match(r"(\d+)\.\s+(.*)", block)
        if not m:
            continue
        nr, rubrik = int(m.group(1)), m.group(2).strip()
        citat = [" ".join(c.split()) for c in re.findall(r"«([^»]*)»", block[m.end():], re.S)]
        tal = " ".join(citat)
        if rubrik.lower().startswith(("titelkort", "slutkort")):
            avsnitt.append(Avsnitt(nr, "kort", None, re.findall(r"«([^»]*)»", rubrik), tal))
        else:
            bild = ROT / rubrik.split()[0]
            if not bild.is_file():
                sys.exit(f"manuset punkt {nr}: hittar inte bilden {bild}")
            avsnitt.append(Avsnitt(nr, "bild", bild, [], tal))
    if not avsnitt:
        sys.exit(f"{sokvag}: inga numrerade punkter under «## Bildmanus»")
    return rost.group(1), avsnitt


# ---------------------------------------------------------------- berättarröst

def hamta_tal(avsnitt: list[Avsnitt], rost: str, katalog: Path):
    """En mp3 per avsnitt, gjord av elevenlabs-skillens generate_dialogue.py.
    Varje stycke blir en egen dialogfil med en enda replik, så att bilden kan
    tajmas mot just sitt ljud. Skillen cachar per stycke under katalog/.segments,
    så ett stycke som inte ändrats kostar inget nytt anrop."""
    if not SKILL.is_file():
        sys.exit(f"hittar inte elevenlabs-skillen: {SKILL}\n"
                 "peka ut generate_dialogue.py med ELEVENLABS_SKILL=…")
    katalog.mkdir(parents=True, exist_ok=True)
    for a in avsnitt:
        dialog = katalog / f"{a.nr:02d}.json"
        fil = katalog / f"{a.nr:02d}.mp3"
        dialog.write_text(json.dumps([{"text": a.text, "voice_id": rost}], ensure_ascii=False, indent=2),
                          encoding="utf-8")
        svar = subprocess.run([sys.executable, str(SKILL), "--input", str(dialog), "--output", str(fil)],
                              capture_output=True, text=True)
        if svar.returncode != 0 or not fil.is_file():
            sys.exit(f"skillen misslyckades på punkt {a.nr}:\n{svar.stdout[-1500:]}{svar.stderr[-1500:]}")
        cachat = "cachat" if "CACHED" in svar.stdout else "hämtat"
        a.ljud = fil
        a.ljudlangd = ljudlangd(fil)
        print(f"  {a.nr:2d}. {a.ljudlangd:5.1f} s  {fil.name} ({cachat})")


# ------------------------------------------------------------------- korten

def typsnitt(storlek: int, vikt: str):
    """Systemets San Francisco om Pillow kan välja vikt i den, annars Helvetica Neue."""
    from PIL import ImageFont
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", storlek)
        try:
            f.set_variation_by_name(vikt)
        except Exception:
            f.set_variation_by_name(vikt.encode())
        return f
    except Exception:
        index = {"Semibold": 1, "Medium": 10, "Regular": 0}.get(vikt, 0)
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", storlek, index=index)


def rita_kort(rader: list[str], utfil: Path):
    """Ikonen och texterna centrerade på mörk botten. Ritas i dubbel storlek så
    att texten blir mjukt nedskalad i videon."""
    from PIL import Image
    from PIL import ImageDraw
    S = 2
    W, H = BREDD * S, HOJD * S
    kort = Image.new("RGB", (W, H), BOTTEN)
    rita = ImageDraw.Draw(kort)

    ikon = Image.open(IKON).convert("RGBA")
    ikonstorlek = 256 * S
    ikon = ikon.resize((ikonstorlek, ikonstorlek), Image.LANCZOS)

    # Första raden är namnet, resten är mindre och dämpade; sista raden (adressen) i accentfärg.
    typ_namn = typsnitt(92 * S, "Semibold")
    typ_liten = typsnitt(40 * S, "Medium")
    block = []                                  # (typsnitt, färg, text, höjd, mellanrum efter)
    for i, rad in enumerate(rader):
        if i == 0:
            block.append((typ_namn, TEXT, rad, 92 * S, 34 * S))
        else:
            farg = ACCENT if i == len(rader) - 1 and len(rader) > 2 else DAMPAD
            block.append((typ_liten, farg, rad, 40 * S, 16 * S))
    mellanrum_ikon = 44 * S
    total = ikonstorlek + mellanrum_ikon + sum(h + m for _, _, _, h, m in block) - (block[-1][4] if block else 0)
    y = (H - total) // 2
    kort.paste(ikon, ((W - ikonstorlek) // 2, y), ikon)
    y += ikonstorlek + mellanrum_ikon
    for typ, farg, rad, h, m in block:
        bredd = rita.textlength(rad, font=typ)
        # anchor "ls" = vänster baslinje; baslinjen läggs så att versalhöjden fyller h.
        rita.text(((W - bredd) / 2, y + h * 0.95), rad, font=typ, fill=farg, anchor="ls")
        y += h + m
    utfil.parent.mkdir(parents=True, exist_ok=True)
    kort.save(utfil)


def platta_skarmbild(bild: Path, utfil: Path):
    """Skärmbilderna är tagna som skärmområde över fönstret, så utanför de
    rundade hörnen syns några pixlar skrivbord. Här läggs bilden på den mörka
    botten med hörnen maskade, så att fönstret får rundade hörn mot botten.
    Masken ritas i dubbel storlek och skalas ned, så kanten blir mjuk."""
    from PIL import Image
    from PIL import ImageDraw
    im = Image.open(bild).convert("RGBA")
    S = 2
    mask = Image.new("L", (im.width * S, im.height * S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, im.width * S - 1, im.height * S - 1], radius=HORNRADIE * S, fill=255)
    mask = mask.resize(im.size, Image.LANCZOS)
    platt = Image.new("RGBA", im.size, BOTTEN)
    platt.paste(im, (0, 0), mask)
    utfil.parent.mkdir(parents=True, exist_ok=True)
    platt.convert("RGB").save(utfil)


# ------------------------------------------------------------------ klippen

def rendera_klipp(bild: Path, langd: float, zoom: float, utfil: Path):
    """Ett klipp av en stillbild: inskalad på 16:9-ytan med bevarade
    proportioner, mörk botten runt om, och en långsam zoom in mot mitten."""
    bildrutor = max(1, round(langd * FPS))
    z = f"min(1+{zoom}*(on-1)/{max(bildrutor - 1, 1)},{1 + zoom})"
    filter_ = ",".join([
        f"scale={KANVAS[0]}:{KANVAS[1]}:force_original_aspect_ratio=decrease:flags=lanczos",
        f"pad={KANVAS[0]}:{KANVAS[1]}:(ow-iw)/2:(oh-ih)/2:color={BOTTEN}",
        "format=yuv444p",       # full färgupplösning genom zoomen, 4:2:0 först i sista steget
        f"zoompan=z='{z}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d={bildrutor}:s={BREDD}x{HOJD}:fps={FPS}",
        "format=yuv420p",
    ])
    utfil.parent.mkdir(parents=True, exist_ok=True)
    kor([FFMPEG, "-y", "-v", "error", "-i", str(bild), "-vf", filter_, "-frames:v", str(bildrutor),
         "-r", str(FPS), "-c:v", "libx264", "-preset", "veryfast", "-crf", "12", str(utfil)])


def satt_ihop(avsnitt: list[Avsnitt], total: float, utfil: Path):
    """Övertonar klippen i varandra (xfade), lägger berättarljudet på sina
    tidpunkter (adelay + amix) och kodar det färdiga resultatet."""
    n = len(avsnitt)
    inmatning = []
    for a in avsnitt:
        inmatning += ["-i", str(a.klipp)]
    med_ljud = [a for a in avsnitt if a.ljud]
    for a in med_ljud:
        inmatning += ["-i", str(a.ljud)]

    graf = [f"[0:v]fade=t=in:st=0:d={INTONING}[v0]"]
    for i in range(1, n):
        graf.append(f"[v{i - 1}][{i}:v]xfade=transition=fade:duration={TONING}:offset={avsnitt[i].start:.3f}[v{i}]")
    graf.append(f"[v{n - 1}]fade=t=out:st={total - UTTONING:.3f}:d={UTTONING}[vut]")

    utdata = ["-map", "[vut]"]
    if med_ljud:
        for k, a in enumerate(med_ljud):
            graf.append(f"[{n + k}:a]adelay={round(a.talstart * 1000)}:all=1[a{k}]")
        graf.append("".join(f"[a{k}]" for k in range(len(med_ljud)))
                    + f"amix=inputs={len(med_ljud)}:normalize=0:duration=longest,apad=whole_dur={total:.3f}[aut]")
        utdata += ["-map", "[aut]", "-c:a", "aac", "-b:a", "160k", "-ar", "44100"]

    utfil.parent.mkdir(parents=True, exist_ok=True)
    kor([FFMPEG, "-y", "-v", "error", *inmatning, "-filter_complex", ";".join(graf), *utdata,
         "-t", f"{total:.3f}", "-r", str(FPS), "-c:v", "libx264", "-preset", "slow", "-crf", "18",
         "-profile:v", "high", "-pix_fmt", "yuv420p", "-g", str(FPS * 2), "-movflags", "+faststart", str(utfil)])


def ta_affisch(video: Path, tid: float, utfil: Path):
    """Stillbild ur videon, att använda som poster på webbsidan."""
    kor([FFMPEG, "-y", "-v", "error", "-ss", f"{tid:.3f}", "-i", str(video), "-frames:v", "1",
         "-q:v", "2", "-update", "1", str(utfil)])


# --------------------------------------------------------------------- main

def main():
    p = argparse.ArgumentParser(description="Bygger docs/produktvideo.mp4 ur docs/bilder och docs/produktvideo-manus.md.")
    p.add_argument("--utan-ljud", action="store_true", help="bygg stum video utan ElevenLabs")
    p.add_argument("--bara-kort", action="store_true", help="rita bara titel- och slutkortet och sluta")
    val = p.parse_args()

    rost, avsnitt = las_manus(MANUS)
    print(f"→ manus: {len(avsnitt)} bilder, röst {rost}, arbetskatalog {ARBETE}")

    # Korten
    print("→ kort")
    for a in avsnitt:
        if a.typ == "kort":
            a.bild = ARBETE / "kort" / f"{a.nr:02d}-kort.png"
            rita_kort(a.kortrader, a.bild)
            print(f"  {a.bild}")
    if val.bara_kort:
        return

    # Skärmbilderna, med hörnen maskade. Källbilderna i docs/bilder rörs inte.
    print("→ skärmbilder")
    for a in avsnitt:
        if a.typ == "bild":
            platt = ARBETE / "bilder" / a.bild.name
            platta_skarmbild(a.bild, platt)
            a.bild = platt
            print(f"  {platt.name}")

    # Berättarrösten
    nyckel = os.environ.get("ELEVENLABS_API_KEY")
    if val.utan_ljud or not nyckel:
        if not val.utan_ljud:
            print("→ ELEVENLABS_API_KEY saknas i miljön — bygger utan ljud")
        for a in avsnitt:
            a.ljudlangd = max(3.0, len(a.text) / TALTAKT)
    else:
        print("→ berättarröst (elevenlabs-skillen)")
        hamta_tal(avsnitt, rost, ARBETE / "ljud")

    # Tidslinjen. Ett klipp är: (övertoning in) + försprång + tal + paus + (övertoning ut).
    # Övertoningen delas med grannen, så klippen överlappar TONING sekunder.
    def rutor(s):        # rundar till hela bildrutor så att xfade-offseten träffar exakt
        return round(s * FPS) / FPS
    for i, a in enumerate(avsnitt):
        fore = INTRO if i == 0 else TONING + FORSPRANG
        efter = (UTGANG + UTTONING) if i == len(avsnitt) - 1 else (PAUS - FORSPRANG) + TONING
        a.langd = rutor(fore + a.ljudlangd + efter)
        a.start = 0.0 if i == 0 else rutor(avsnitt[i - 1].start + avsnitt[i - 1].langd - TONING)
        a.talstart = a.start + fore
    total = avsnitt[-1].start + avsnitt[-1].langd
    print(f"→ tidslinje: {total:.1f} s totalt")

    # Klippen. Namnet bär en hash av bilden och längden, så ett oförändrat klipp återanvänds.
    print("→ klipp")
    for a in avsnitt:
        zoom = ZOOM if a.typ == "bild" else 0.0
        h = hashlib.sha256(a.bild.read_bytes() + f"{a.langd}{zoom}{KANVAS}{FPS}".encode()).hexdigest()[:12]
        a.klipp = ARBETE / "klipp" / f"{a.nr:02d}-{h}.mp4"
        if a.klipp.exists():
            print(f"  {a.nr:2d}. {a.langd:5.1f} s  (finns) {a.bild.name}")
            continue
        print(f"  {a.nr:2d}. {a.langd:5.1f} s  {a.bild.name}")
        rendera_klipp(a.bild, a.langd, zoom, a.klipp)

    print("→ sätter ihop")
    satt_ihop(avsnitt, total, UT_VIDEO)
    # Affischen: första hela bildrutan efter titelkortet. xfade:s allra sista
    # ruta bär fortfarande några procent av den förra bilden, så den tas 0,1 s
    # efter att övertoningen formellt är klar — fortfarande före berättaren.
    ta_affisch(UT_VIDEO, avsnitt[1].start + TONING + 0.1 if len(avsnitt) > 1 else 0.0, UT_AFFISCH)
    print(f"→ klart: {UT_VIDEO} ({total:.1f} s, {UT_VIDEO.stat().st_size // 1024} kB) och {UT_AFFISCH}")


if __name__ == "__main__":
    main()
