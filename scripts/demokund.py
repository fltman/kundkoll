#!/usr/bin/env python3
"""Skapar en påhittad kund för skärmbilder och demonstrationer.

  scripts/demokund.py              # skapar «Fjällbo Energi» under ~/Documents/Kunder
  scripts/demokund.py --utan-ljud  # hoppar över talsyntesen (snabbare, men spelaren saknar ljud)
  scripts/demokund.py --kalender   # lägger dessutom tre kommande möten i kalendern «Kundkoll demo»
  scripts/demokund.py --elevenlabs # riktiga röster via ElevenLabs (ELEVENLABS_API_KEY i miljön)
  scripts/demokund.py --ta-bort    # flyttar kunden till papperskorgen och tar bort kalendern
  scripts/demokund.py --rot MAPP   # en annan rot än ~/Documents/Kunder, till exempel för skärmbilder

Allt är påhittat: företaget, personerna, mejlen och mötena. Ljudet görs med
macOS egen talsyntes (rösten Alva) ur transkripten, så att spelaren i
mötesvyn har något att spela. Filformaten är desamma som appen skriver, och
mejlcachen får ett hämtningsdatum långt fram i tiden så att appen inte
söker om i Mail och skriver över de påhittade mejlen.
"""
import array, hashlib, json, os, random, shutil, subprocess, sys, tempfile, uuid, wave
from datetime import datetime, timedelta, timezone
from pathlib import Path

KUND = "Fjällbo Energi"
ROT = Path.home() / "Documents" / "Kunder"
if "--rot" in sys.argv:
    ROT = Path(sys.argv[sys.argv.index("--rot") + 1]).expanduser()
MAPP = ROT / KUND
KALENDER = "Kundkoll demo"
random.seed(2026)

def uid(): return str(uuid.uuid4()).upper()
def iso(d): return d.astimezone().isoformat(timespec="seconds")
def dag(y, m, d, h=9, mi=0): return datetime(y, m, d, h, mi).astimezone()
def skriv_json(väg, obj):
    väg.parent.mkdir(parents=True, exist_ok=True)
    väg.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
def skriv(väg, text):
    väg.parent.mkdir(parents=True, exist_ok=True)
    väg.write_text(text, encoding="utf-8")

# ---------------------------------------------------------------- personer
KONTAKTER = [
    ("Karin Lindqvist", "IT-chef", "karin.lindqvist@fjallboenergi.se", "070-123 45 01"),
    ("Sara Holm", "Dataanalytiker", "sara.holm@fjallboenergi.se", "070-123 45 02"),
    ("Johan Berg", "Projektledare kundtjänst", "johan.berg@fjallboenergi.se", "070-123 45 03"),
    ("Erik Nyström", "Ekonomichef", "erik.nystrom@fjallboenergi.se", "070-123 45 04"),
]
JAG = "Anders Bjarby"

def enhetsvektor():
    v = [random.gauss(0, 1) for _ in range(192)]
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v]
def brusad(bas, brus=0.25):
    v = [x + random.gauss(0, brus / 192 ** 0.5) for x in bas]
    n = sum(x * x for x in v) ** 0.5
    return [round(x / n, 5) for x in v]
RÖSTER = {namn: enhetsvektor() for namn, *_ in KONTAKTER}

# ---------------------------------------------------------------- möten
PROJEKT = ["Dataplattform", "AI-assistent kundtjänst", "Kundregister"]

MÖTEN = [
    dict(titel="Uppstart dataplattform", när=dag(2026, 8, 20, 9, 30), projekt="Dataplattform",
         enspårig=False, talare=["Karin Lindqvist", "Sara Holm"],
         rader=[
             ("Karin Lindqvist", "Välkommen Anders, kul att du kunde komma. Vi tänkte gå igenom nuläget för dataplattformen."),
             ("jag", "Tack. Jag har läst underlaget ni skickade, men berätta gärna hur ni jobbar i dag."),
             ("Sara Holm", "I dag ligger mätvärdena i tre olika system. Elnätet i ett, fjärrvärmen i ett annat och kunddata i ekonomisystemet."),
             ("Karin Lindqvist", "Och rapporterna byggs för hand i Excel varje måndag. Det tar Sara en halv dag."),
             ("jag", "Då är första steget att få ihop källorna i ett gemensamt lager. Har ni tittat på Databricks eller Fabric?"),
             ("Sara Holm", "Vi har en Fabric-licens sedan i våras men har inte kommit igång."),
             ("jag", "Bra, då utgår vi från den. Jag föreslår att vi börjar med mätvärdena från elnätet, det är den största nyttan."),
             ("Karin Lindqvist", "Det låter rimligt. Kan du skicka ett förslag på upplägg och tidplan före fredag?"),
             ("jag", "Absolut, jag skickar ett förslag på torsdag. Sara, kan du ge mig läsbehörighet till mätdatabasen?"),
             ("Sara Holm", "Jag fixar det i dag."),
             ("Karin Lindqvist", "Vi behöver också bestämma vem som äger datamodellen. Det får vi ta i styrgruppen."),
             ("jag", "Noterat. Ska vi säga att vi ses igen om två veckor för en avstämning?"),
             ("Karin Lindqvist", "Passar bra. Jag bokar."),
         ],
         kärna="Uppstart för dataplattformen. Mätvärdena ligger i tre system och veckorapporterna byggs för hand i Excel. Fabric-licensen finns men är oanvänd; elnätets mätvärden blir första steget.",
         beslut=["Fabric blir plattformen", "Elnätets mätvärden tas in först"],
         åtaganden=[("Skicka förslag på upplägg och tidplan", "Anders", "torsdag", "2026-08-21", True),
                    ("Ge Anders läsbehörighet till mätdatabasen", "Sara Holm", "i dag", "2026-08-20", True),
                    ("Boka avstämning om två veckor", "Karin Lindqvist", "om två veckor", "2026-09-03", False)],
         öppet=["Vem äger datamodellen? Tas i styrgruppen."]),
    dict(titel="Avstämning AI-assistent", när=dag(2026, 8, 27, 13, 0), projekt="AI-assistent kundtjänst",
         enspårig=False, talare=["Johan Berg"],
         rader=[
             ("Johan Berg", "Hej Anders. Vi har testat prototypen med tre handläggare den här veckan."),
             ("jag", "Vad säger de?"),
             ("Johan Berg", "Svaren om fakturor är bra, men den gissar när det gäller flyttar och avslut."),
             ("jag", "Det är för att flyttflödet inte finns i underlaget än. Jag lägger in rutinerna från intranätet."),
             ("Johan Berg", "Kan den hänvisa till vilken rutin svaret kommer ifrån? Handläggarna vill kunna kontrollera."),
             ("jag", "Ja, det är redan inbyggt, men jag kan göra hänvisningarna tydligare."),
             ("Johan Berg", "Vi vill också att den säger ifrån när den inte vet, hellre än att gissa."),
             ("jag", "Det är grundinställningen. Jag skärper instruktionen och skickar en ny version nästa vecka."),
             ("Johan Berg", "Bra. Ekonomi undrar vad driften kostar per månad."),
             ("jag", "Jag tar fram en uppskattning tillsammans med förslaget."),
             ("Johan Berg", "Då säger vi så."),
         ],
         kärna="Prototypen har testats av tre handläggare. Fakturafrågorna fungerar, men flytt och avslut saknar underlag och assistenten gissar. Handläggarna vill se vilken rutin ett svar bygger på.",
         beslut=["Flyttflödet från intranätet läggs in i underlaget", "Assistenten ska säga ifrån hellre än gissa"],
         åtaganden=[("Lägga in flyttrutinerna i underlaget", "Anders", "nästa vecka", "2026-09-04", False),
                    ("Ta fram driftkostnad per månad", "Anders", "med förslaget", "2026-09-04", False),
                    ("Skicka ny version av prototypen", "Anders", "nästa vecka", "2026-09-04", False)],
         öppet=["Hur ska hänvisningarna visas för handläggarna?"]),
    dict(titel="Styrgrupp september", när=dag(2026, 9, 1, 15, 0), projekt=None,
         enspårig=True, talare=["Karin Lindqvist", "Erik Nyström", JAG], källfil="Styrgrupp 2026-09-01.mp4",
         rader=[
             ("Karin Lindqvist", "Då kör vi igång styrgruppen. Anders, vill du börja med dataplattformen?"),
             (JAG, "Gärna. Förslaget är skickat och Sara har gett mig tillgång till mätdatabasen. Vi är igång med elnätets mätvärden."),
             ("Erik Nyström", "Vad landar det på i kostnad det första halvåret?"),
             (JAG, "Ungefär trehundra tusen för plattformen, sedan löpande licens. Det står i förslaget."),
             ("Erik Nyström", "Då behöver vi ett beslut i ledningsgruppen. Jag tar det på måndag."),
             ("Karin Lindqvist", "Datamodellen då, vem äger den?"),
             ("Erik Nyström", "Jag tycker att det ska vara IT, med ekonomi som beställare."),
             ("Karin Lindqvist", "Då säger vi så. Anders, kan du skriva ner rollerna?"),
             (JAG, "Jag skickar ett förslag på rollfördelning tillsammans med mötesanteckningarna."),
             ("Karin Lindqvist", "Nästa styrgrupp om en månad."),
         ],
         kärna="Styrgruppen gick igenom dataplattformen: förslaget är skickat och arbetet med elnätets mätvärden är igång. Kostnaden första halvåret är omkring 300 000 kronor och tas till ledningsgruppen.",
         beslut=["IT äger datamodellen, ekonomi är beställare", "Nästa styrgrupp om en månad"],
         åtaganden=[("Ta investeringsbeslutet i ledningsgruppen", "Erik Nyström", "på måndag", "2026-09-07", False),
                    ("Skriva ner rollfördelningen", "Anders", "med mötesanteckningarna", "2026-09-03", False)],
         öppet=[]),
]

RÖSTHASTIGHET = {"jag": 175, JAG: 175, "Karin Lindqvist": 165, "Sara Holm": 190,
                 "Johan Berg": 170, "Erik Nyström": 150}

# ---------------------------------------------------------------- ElevenLabs
# Riktiga röster i stället för talsyntesen, när ELEVENLABS_API_KEY finns i
# miljön (eller nyckeln ligger i appens nyckelring). Fem talare får var sin
# röst: svenska röster i kontot först, sedan förinställda efter kön.
ELEVEN = {"nyckel": None, "röster": {}}
KÖN = {"jag": "male", JAG: "male", "Karin Lindqvist": "female", "Sara Holm": "female",
       "Johan Berg": "male", "Erik Nyström": "male"}

def eleven_nyckel():
    n = os.environ.get("ELEVENLABS_API_KEY")
    if n: return n
    r = subprocess.run(["security", "find-generic-password", "-s", "com.brattoo.kundkoll",
                        "-a", "kundkoll-elevenlabs", "-w"], capture_output=True, text=True)
    return r.stdout.strip() or None

def eleven_förbered():
    import urllib.request
    nyckel = eleven_nyckel()
    if not nyckel:
        print("  ingen ElevenLabs-nyckel — talsyntesen används")
        return False
    req = urllib.request.Request("https://api.elevenlabs.io/v1/voices", headers={"xi-api-key": nyckel})
    try:
        with urllib.request.urlopen(req, timeout=30) as svar:
            röster = json.load(svar)["voices"]
    except Exception as fel:
        print(f"  ElevenLabs svarade inte ({fel}) — talsyntesen används")
        return False
    def kön(v): return (v.get("labels") or {}).get("gender", "")
    def svensk(v):
        etiketter = " ".join(str(x) for x in (v.get("labels") or {}).values()).lower()
        språk = [s.get("language", "") for s in (v.get("verified_languages") or [])]
        return "sv" in språk or "swedish" in etiketter or "svensk" in etiketter
    kandidater = {"male": [], "female": []}
    for v in sorted(röster, key=lambda v: (not svensk(v), v.get("category") != "cloned")):
        k = kön(v)
        if k in kandidater: kandidater[k].append(v)
    valda = {}
    använda = set()
    for talare, k in KÖN.items():
        if talare == JAG and "jag" in valda:
            valda[talare] = valda["jag"]; continue
        lista = [v for v in kandidater.get(k, []) if v["voice_id"] not in använda] or kandidater.get(k, []) or röster
        if not lista: return False
        v = lista[0]
        valda[talare] = v["voice_id"]; använda.add(v["voice_id"])
        print(f"  röst: {talare} ← {v['name']}")
    ELEVEN["nyckel"], ELEVEN["röster"] = nyckel, valda
    return True

SKILL = Path(os.environ.get("ELEVENLABS_SKILL") or Path.home()
             / "Projekt/hooklinecoder/.claude/skills/elevenlabs-skill/scripts/generate_dialogue.py")

def tala_eleven(text, talare):
    """En replik via elevenlabs-skillens generate_dialogue.py (dialog-API:t) —
    aldrig egna anrop mot text-to-speech. Skillen cachar per replik under
    arbetskatalogens .segments, så samma rad hämtas inte om. Resultatet
    avkodas till 16 kHz mono pcm, som resten av skriptet väntar sig."""
    if not SKILL.is_file():
        raise RuntimeError(f"hittar inte elevenlabs-skillen: {SKILL} (peka ut den med ELEVENLABS_SKILL)")
    arbete = Path(tempfile.gettempdir()) / "kundkoll-demo-tal"
    arbete.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha1(f"{ELEVEN['röster'][talare]}\n{text}".encode()).hexdigest()[:12]
    dialog, mp3 = arbete / f"{h}.json", arbete / f"{h}.mp3"
    dialog.write_text(json.dumps([{"text": text, "voice_id": ELEVEN["röster"][talare]}], ensure_ascii=False))
    svar = subprocess.run([sys.executable, str(SKILL), "--input", str(dialog), "--output", str(mp3)],
                          capture_output=True, text=True, env={**os.environ, "ELEVENLABS_API_KEY": ELEVEN["nyckel"]})
    if svar.returncode != 0 or not mp3.is_file():
        raise RuntimeError("skillen misslyckades: " + (svar.stdout + svar.stderr)[-600:])
    rå = subprocess.run(["ffmpeg", "-v", "error", "-i", str(mp3), "-f", "s16le", "-ac", "1", "-ar", "16000", "-"],
                        capture_output=True, check=True).stdout
    prov = array.array("h"); prov.frombytes(rå)
    if sys.byteorder != "little": prov.byteswap()
    return prov

def tala(text, hastighet, tmp, talare=None):
    if ELEVEN["nyckel"] and talare in ELEVEN["röster"]:
        try:
            return tala_eleven(text, talare)
        except Exception as fel:
            print(f"  ElevenLabs föll på en rad ({fel}) — talsyntesen tar den")
    aiff = tmp / f"{uid()}.aiff"
    wav = tmp / f"{aiff.stem}.wav"
    subprocess.run(["say", "-v", "Alva", "-r", str(hastighet), "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with wave.open(str(wav)) as w:
        prov = array.array("h")
        prov.frombytes(w.readframes(w.getnframes()))
    return prov

def skriv_wav(väg, prov):
    with wave.open(str(väg), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(prov.tobytes())

def bygg_möte(m, mapp, med_ljud, tmp):
    rader, grupp = [], {}
    talare = m["talare"]
    for i, t in enumerate(talare): grupp[t] = i
    t = 0.8
    spår = {"jag": array.array("h"), "motpart": array.array("h")}
    for vem, text in m["rader"]:
        ljud = tala(text, RÖSTHASTIGHET.get(vem, 170), tmp, talare=vem) if med_ljud else None
        längd = (len(ljud) / 16000) if ljud is not None else max(1.5, 0.055 * len(text))
        start, slut = round(t, 2), round(t + längd, 2)
        egen = (vem == "jag") and not m["enspårig"]
        röst = "jag" if egen else "motpart"
        rad = {"id": uid(), "röst": röst, "text": text, "start": start, "slut": slut}
        if not egen: rad["röstgrupp"] = grupp[vem if vem != "jag" else JAG]
        rader.append(rad)
        if ljud is not None:
            s = spår[röst]
            behov = int(start * 16000)
            if len(s) < behov: s.extend(array.array("h", [0]) * (behov - len(s)))
            s.extend(ljud)
        t = slut + random.uniform(0.4, 1.1)
    total = t + 0.5
    if med_ljud:
        n = int(total * 16000)
        for namn, s in spår.items():
            if m["enspårig"] and namn == "jag": continue
            if len(s) < n: s.extend(array.array("h", [0]) * (n - len(s)))
            skriv_wav(mapp / f"{namn}.wav", s)
    röstnamn = {str(i): t for i, t in enumerate(talare)}
    röstavtryck = {str(i): {"vektor": brusad(RÖSTER.get(t, enhetsvektor())), "sekunder": 9.5}
                   for i, t in enumerate(talare)}
    åtaganden = [{"id": uid(), "vad": vad, "vem": vem, "när": när, "senast": iso(dag(*map(int, senast.split("-")))),
                  "klart": klart} for vad, vem, när, senast, klart in m["åtaganden"]]
    inspelning = {
        "id": uid(), "titel": m["titel"], "inledd": iso(m["när"]), "längd": round(total, 1),
        "kund": KUND, "projekt": m["projekt"], "mikrofon": None if m["enspårig"] else "MacBook Pro-mikrofon",
        "liveYttranden": [], "arkivYttranden": rader, "röstnamn": röstnamn,
        "kallade": [] if m["enspårig"] else talare, "enspårig": m["enspårig"],
        "källfil": m.get("källfil"), "språk": "sv",
        "sammanfattning": {"kärna": m["kärna"], "beslut": m["beslut"], "åtaganden": åtaganden,
                           "öppet": m["öppet"], "skriven": iso(m["när"] + timedelta(minutes=int(total / 60) + 6))},
        "bearbetas": False, "röstmetod": "pyannote", "röstavtryck": röstavtryck,
    }
    skriv_json(mapp / "möte.json", inspelning)
    md = [f"---\ntyp: transkript\nkund: \"{KUND}\"\nprojekt: {('\"' + m['projekt'] + '\"') if m['projekt'] else ''}\n"
          f"datum: {m['när'].strftime('%Y-%m-%d %H:%M')}\nlängd: {int(total // 60):02d}:{int(total % 60):02d}\n"
          f"kvalitet: arkiv (KB-Whisper)\ngenererad: kundkoll\n---\n\n# {m['titel']}\n\n[[{KUND}]]"
          + (f" · [[{m['projekt']}]]" if m["projekt"] else "") + "\n\n"
          "*Skriven av Bjarbys kundkoll och byggs om vid varje sparning — ändra i appen, inte här.*\n\n"
          f"Deltagare: " + ", ".join(f"[[{t}]]" for t in talare) + f"\n\n{m['kärna']}\n"]
    md.append("\n## Beslut\n\n" + "".join(f"- {b}\n" for b in m["beslut"]))
    md.append("\n## Att göra\n\n" + "".join(f"- [{'x' if å['klart'] else ' '}] **{å['vem']}** {å['vad']} *({å['när']})*\n" for å in åtaganden))
    if m["öppet"]: md.append("\n## Öppna frågor\n\n" + "".join(f"- {o}\n" for o in m["öppet"]))
    md.append("\n## Transkript\n\n")
    for r in rader:
        namn = "Jag" if r["röst"] == "jag" else röstnamn[str(r["röstgrupp"])]
        md.append(f"**{namn}** `{int(r['start'] // 60):02d}:{int(r['start'] % 60):02d}`\n{r['text']}\n\n")
    skriv(mapp / "Transkript.md", "".join(md))
    return inspelning

# ---------------------------------------------------------------- skapa
def skapa(med_ljud):
    if MAPP.exists():
        sys.exit(f"{MAPP} finns redan — kör --ta-bort först.")
    tmp = Path("/tmp") / f"kundkoll-demo-{uid()}"
    tmp.mkdir(parents=True)
    for d in ["Projekt", "Samtal", "Kontakter", "Mail/Bilagor", "Anteckningar", ".kundkoll/samtal", ".obsidian"]:
        (MAPP / d).mkdir(parents=True, exist_ok=True)
    if ELEVEN.get("röster"):
        # Vilka röster som valdes, så att demolive.py kan använda samma.
        skriv_json(MAPP / ".kundkoll" / "demoröster.json", ELEVEN["röster"])
    skriv(MAPP / ".obsidian" / "app.json",
          '{\n  "alwaysUpdateLinks": true,\n  "newLinkFormat": "shortest",\n  "useMarkdownLinks": false,\n  "attachmentFolderPath": "./"\n}\n')
    skriv(MAPP / f"{KUND}.md", f"---\ntyp: kund\n---\n\n# {KUND}\n\nRegionalt energibolag med elnät, fjärrvärme och 40 000 kunder. "
          "Tre uppdrag under 2026: en gemensam dataplattform, en AI-assistent för kundtjänsten och ett nytt kundregister.\n\n"
          "## Projekt\n\n" + "".join(f"- [[{p}]]\n" for p in PROJEKT) + "\n## Kontakter\n\n"
          + "".join(f"- [[{n}]] — {r}\n" for n, r, *_ in KONTAKTER) + "\n## Anteckningar\n\n- [[Bakgrund och nuläge]]\n")

    # Projekt
    for p in PROJEKT:
        for d in ["Inspelningar", "Dokument", "Anteckningar"]:
            (MAPP / "Projekt" / p / d).mkdir(parents=True, exist_ok=True)
        skriv(MAPP / "Projekt" / p / f"{p}.md", f"---\ntyp: projekt\nkund: \"{KUND}\"\n---\n\n# {p}\n\n[[{KUND}]]\n\n## Anteckningar\n\n")

    # Kontakter, med noter och röstprofiler
    kontakter = []
    for namn, roll, epost, tel in KONTAKTER:
        kontakter.append({"id": uid(), "namn": namn, "roll": roll, "epost": [epost], "telefon": [tel],
                          "systemID": None, "bild": None})
        skriv(MAPP / "Kontakter" / f"{namn}.md",
              f"---\ntyp: kontakt\nkund: \"{KUND}\"\nroll: \"{roll}\"\nepost:\n  - {epost}\ntelefon:\n  - \"{tel}\"\n---\n\n# {namn}\n\n[[{KUND}]]\n")
    kontakter.append({"id": uid(), "namn": JAG, "roll": None, "epost": ["anders@brattoo.com"], "telefon": [],
                      "systemID": None, "bild": None})
    skriv_json(MAPP / "Kontakter" / "kontakter.json", kontakter)
    skriv_json(MAPP / "Kontakter" / "röstprofiler.json", [
        {"id": uid(), "namn": namn, "avtryck": [{"vektor": brusad(RÖSTER[namn]), "sekunder": 11.2},
                                                 {"vektor": brusad(RÖSTER[namn]), "sekunder": 8.4}],
         "uppdaterad": iso(dag(2026, 8, 27)), "samtal": 2} for namn, *_ in KONTAKTER])

    # Möten
    inspelningar = []
    for m in MÖTEN:
        rot = MAPP / "Projekt" / m["projekt"] / "Inspelningar" if m["projekt"] else MAPP / "Samtal"
        mapp = rot / f"{m['när'].strftime('%Y-%m-%d %H%M')} {m['titel']}"
        mapp.mkdir(parents=True, exist_ok=True)
        print(f"  möte: {m['titel']}" + (" (talsyntes …)" if med_ljud else ""))
        inspelningar.append((bygg_möte(m, mapp, med_ljud, tmp), mapp))

    # Uppgifter: mötenas åtaganden, ett par ur mejl, en för hand
    uppgifter = []
    for i, mapp in inspelningar:
        for å in i["sammanfattning"]["åtaganden"]:
            uppgifter.append({"id": uid(), "vad": å["vad"], "vem": å["vem"], "när": å["när"], "senast": å["senast"],
                              "påminnelse": None, "läge": "klart" if å["klart"] else "attGöra", "ursprung": "möte",
                              "källa": str(mapp), "källtitel": i["titel"], "projekt": i["projekt"],
                              "skapad": i["inledd"], "ändrad": i["inledd"]})
    uppgifter[3]["läge"] = "pågår"    # flyttrutinerna
    uppgifter += [
        {"id": uid(), "vad": "Skicka mätvärden för juli till Anders", "vem": "Sara Holm", "när": "senast fredag",
         "senast": iso(dag(2026, 8, 29)), "påminnelse": None, "läge": "attGöra", "ursprung": "mejl", "källa": None,
         "källtitel": "Behörighet till mätdatabasen", "projekt": "Dataplattform",
         "skapad": iso(dag(2026, 8, 25, 10)), "ändrad": iso(dag(2026, 8, 25, 10))},
        {"id": uid(), "vad": "Svara på frågan om personuppgiftsbiträdesavtalet", "vem": "Anders", "när": "före styrgruppen",
         "senast": iso(dag(2026, 9, 5)), "påminnelse": None, "läge": "attGöra", "ursprung": "mejl", "källa": None,
         "källtitel": "Personuppgiftsbiträdesavtal", "projekt": None,
         "skapad": iso(dag(2026, 8, 29, 14)), "ändrad": iso(dag(2026, 8, 29, 14))},
        {"id": uid(), "vad": "Boka workshop om kundregistret med Johan och Sara", "vem": "Johan Berg", "när": "i september",
         "senast": iso(dag(2026, 9, 12)), "påminnelse": None, "läge": "attGöra", "ursprung": "mejl", "källa": None,
         "källtitel": "Kundregistret — nästa steg", "projekt": "Kundregister",
         "skapad": iso(dag(2026, 8, 31, 9)), "ändrad": iso(dag(2026, 8, 31, 9))},
        {"id": uid(), "vad": "Läs på om Fabrics prisnivåer inför ledningsgruppens beslut", "vem": None, "när": None,
         "senast": None, "påminnelse": None, "läge": "attGöra", "ursprung": "egen", "källa": None,
         "källtitel": None, "projekt": "Dataplattform",
         "skapad": iso(dag(2026, 9, 1, 17)), "ändrad": iso(dag(2026, 9, 1, 17))},
    ]
    skriv_json(MAPP / "uppgifter.json", uppgifter)
    md = [f"---\ntyp: uppgifter\nkund: \"{KUND}\"\ngenererad: kundkoll\n---\n\n# Att göra — {KUND}\n\n[[{KUND}]]\n\n"
          "*Skriven av Bjarbys kundkoll och byggs om vid varje sparning — ändra i appen, inte här.*\n"]
    for läge, rubrik in [("attGöra", "Att göra"), ("pågår", "Pågår"), ("klart", "Klart")]:
        ivarje = [u for u in uppgifter if u["läge"] == läge]
        if ivarje:
            md.append(f"\n## {rubrik}\n\n" + "".join(
                f"- [{'x' if läge == 'klart' else ' '}] {('**' + u['vem'] + '** ') if u['vem'] else ''}{u['vad']}"
                f"{(' *(' + u['när'] + ')*') if u['när'] else ''}{(' — ' + u['källtitel']) if u['källtitel'] else ''}\n" for u in ivarje))
    skriv(MAPP / "Att göra.md", "".join(md))

    # Mejl med bilagor
    bilagemapp = MAPP / "Mail" / "Bilagor"
    kravlista = ("# Kravlista dataplattform\n\n- Mätvärden från elnätet var 15:e minut\n- Fjärrvärmens flöden per dygn\n"
                 "- Kunddata ur ekonomisystemet, uppdaterat varje natt\n- Veckorapporten ska gå att ta fram utan handpåläggning\n"
                 "- Behörigheter per roll: analytiker, ekonomi, ledning\n")
    skriv(bilagemapp / "Kravlista dataplattform.md", kravlista)
    csv = "datum,mätpunkt,kWh\n2026-07-01,Norra elnätet,18420\n2026-07-01,Södra elnätet,15110\n2026-07-02,Norra elnätet,18705\n2026-07-02,Södra elnätet,14980\n"
    skriv(bilagemapp / "Mätvärden juli.csv", csv)
    offert = ("Offert: dataplattform på Microsoft Fabric\n\nOmfattning: inläsning av elnätets mätvärden, datamodell, veckorapport.\n"
              "Tid: sex veckor från start.\nPris: 285 000 kr exklusive moms, fast pris.\nLicens: Fabric F2, cirka 3 200 kr per månad.\n"
              "Förutsättningar: läsbehörighet till mätdatabasen och en kontaktperson hos IT.\n")
    txt = tmp / "offert.txt"; txt.write_text(offert, encoding="utf-8")
    subprocess.run(["textutil", "-convert", "docx", "-output", str(bilagemapp / "Offert dataplattform.docx"), str(txt)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pub = ("Personuppgiftsbiträdesavtal — utkast\n\nParter: Fjällbo Energi (personuppgiftsansvarig) och Brattoo AB (biträde).\n"
           "Behandling: kunduppgifter i samband med AI-assistenten för kundtjänst.\nLagring: inom EU.\nGallring: 90 dagar efter avslutat uppdrag.\n")
    txt2 = tmp / "pub.txt"; txt2.write_text(pub, encoding="utf-8")
    subprocess.run(["textutil", "-convert", "docx", "-output", str(bilagemapp / "Personuppgiftsbiträdesavtal utkast.docx"), str(txt2)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def mejl(när, från, ämne, text, skickat=False, n=0):
        avs = f"{JAG} <anders@brattoo.com>" if skickat else f"{från} <{[e for nm, r, e, t in KONTAKTER if nm == från][0]}>"
        return {"datum": iso(när), "datumText": när.strftime("%A, %-d %B %Y at %H:%M:%S"), "avsändare": avs, "ämne": ämne,
                "meddelandeID": f"<demo-{n}@fjallboenergi.se>", "konto": "Demo", "låda": "Sent Messages" if skickat else "INBOX",
                "riktning": "till" if skickat else "från", "text": text}
    mejlen = [
        mejl(dag(2026, 9, 2, 8, 41), "Karin Lindqvist", "Re: Mötesanteckningar styrgrupp 1 september",
             "Hej Anders,\n\nTack för anteckningarna, de stämmer med hur jag uppfattade mötet. Erik tar investeringsbeslutet på måndag. Kan du lägga till rollfördelningen som bilaga när den är klar?\n\nHälsningar\nKarin", n=7),
        mejl(dag(2026, 9, 1, 17, 12), "Karin Lindqvist", "Mötesanteckningar styrgrupp 1 september",
             "Hej!\n\nTack för i dag. Så här uppfattade jag att vi landade:\n\nBeslut:\n• IT äger datamodellen, ekonomi är beställare\n• Nästa styrgrupp om en månad\n\nAtt göra:\n• Ta investeringsbeslutet i ledningsgruppen (Erik, på måndag)\n• Skriva ner rollfördelningen (Anders)\n\nHälsningar\nAnders", skickat=True, n=6),
        mejl(dag(2026, 8, 31, 9, 5), "Johan Berg", "Kundregistret — nästa steg",
             "Hej Anders,\n\nnär AI-assistenten är i hamn vill vi ta tag i kundregistret. Kan vi boka en workshop i september med dig, mig och Sara? Vi behöver gå igenom vilka fält som faktiskt används i dag.\n\n/Johan", n=5),
        mejl(dag(2026, 8, 29, 14, 20), "Erik Nyström", "Personuppgiftsbiträdesavtal",
             "Hej,\n\nbifogar ett utkast till personuppgiftsbiträdesavtal för AI-assistenten. Vår jurist undrar om kunduppgifterna lämnar EU när assistenten svarar. Kan du svara på det före styrgruppen?\n\nMvh\nErik", n=4),
        mejl(dag(2026, 8, 28, 11, 33), "Johan Berg", "Re: Prototyp AI-assistent — återkoppling från handläggarna",
             "Hej,\n\nhandläggarna är nöjda med fakturasvaren. Två saker återkommer: den gissar om flyttar, och de vill se vilken rutin svaret bygger på. Tar vi det på avstämningen?\n\n/Johan", n=3),
        mejl(dag(2026, 8, 25, 10, 2), "Sara Holm", "Behörighet till mätdatabasen",
             "Hej Anders,\n\nnu har du läsbehörighet till mätdatabasen, kontot heter anders_las. Bifogar också mätvärdena för juli som exempel. Säg till om något saknas.\n\nSara", n=2),
        mejl(dag(2026, 8, 21, 16, 48), "Karin Lindqvist", "Förslag: dataplattform på Fabric",
             "Hej Karin,\n\nhär kommer förslaget på upplägg och tidplan som vi pratade om i onsdags. Sex veckor från start, fast pris, elnätets mätvärden först. Offerten ligger som bilaga.\n\nHälsningar\nAnders", skickat=True, n=1),
        mejl(dag(2026, 8, 18, 9, 12), "Karin Lindqvist", "Inför uppstart dataplattform",
             "Hej Anders,\n\nvälkommen på onsdag. Jag bifogar den kravlista Sara och jag satt ihop, så att du kan läsa på innan. Vi ses 9:30 i Björnen.\n\nHälsningar\nKarin", n=0),
    ]
    def bilaga(ämne, fil, text):
        väg = bilagemapp / fil
        return {"ämne": ämne, "namn": fil, "fil": str(väg), "storlek": väg.stat().st_size, "text": text}
    bilagor = [
        bilaga("Inför uppstart dataplattform", "Kravlista dataplattform.md", kravlista),
        bilaga("Förslag: dataplattform på Fabric", "Offert dataplattform.docx", offert),
        bilaga("Behörighet till mätdatabasen", "Mätvärden juli.csv", csv),
        bilaga("Personuppgiftsbiträdesavtal", "Personuppgiftsbiträdesavtal utkast.docx", pub),
    ]
    # Hämtad långt fram: annars söker appen om i Mail och skriver över.
    skriv_json(MAPP / "Mail" / "mail.json", {"hämtad": iso(dag(2030, 1, 1)), "mejl": mejlen, "bilagor": bilagor})
    md = [f"---\ntyp: mail\nkund: \"{KUND}\"\nhämtad: 2026-09-02 08:45\ngenererad: kundkoll\n---\n\n# Mail — {KUND}\n\n[[{KUND}]]\n\n"
          "*Skriven av Bjarbys kundkoll och byggs om vid varje sparning — ändra i appen, inte här.*\n\n## Bilagor\n\n"
          + "".join(f"- [[Bilagor/{b['namn']}]] — {b['ämne']} · text inläst\n" for b in bilagor)]
    for m in mejlen:
        d = datetime.fromisoformat(m["datum"])
        md.append(f"\n## {d.strftime('%-d %B %Y')}\n\n- {'→' if m['riktning'] == 'till' else '←'} **{m['ämne']}** · "
                  f"{'jag' if m['riktning'] == 'till' else m['avsändare'].split(' <')[0]} {d.strftime('%H:%M')}\n")
    skriv(MAPP / "Mail" / "Mail.md", "".join(md))

    # Anteckningar
    skriv(MAPP / "Anteckningar" / "Bakgrund och nuläge.md",
          "# Bakgrund och nuläge\n\nFjällbo Energi är ett kommunägt energibolag med elnät, fjärrvärme och omkring 40 000 kunder.\n\n"
          "- IT-avdelningen är fem personer; Karin Lindqvist är chef sedan 2024.\n- Rapporteringen sker i Excel och tar en halv dag i veckan.\n"
          "- Fabric-licensen köptes i våras men har inte tagits i bruk.\n- Kundtjänsten tar 300 samtal om dagen; flytt och fakturafrågor dominerar.\n\n"
          "## Att hålla i minnet\n\nErik vill se kostnaden per månad, inte per projekt. Skriv alltid ut licensen separat.\n")
    skriv(MAPP / "Projekt" / "Dataplattform" / "Anteckningar" / "Arkitekturskiss.md",
          "# Arkitekturskiss\n\n1. Mätdatabasen läses in var 15:e minut till ett landningslager.\n2. Ett kuraterat lager med en tabell per mätpunkt och dygn.\n"
          "3. Veckorapporten byggs som en Power BI-rapport ovanpå det kuraterade lagret.\n\n"
          "Öppet: fjärrvärmen levererar bara dygnsvärden — räcker det för rapporten?\n")
    skriv(MAPP / "Projekt" / "AI-assistent kundtjänst" / "Anteckningar" / "Provfrågor från handläggarna.md",
          "# Provfrågor från handläggarna\n\n- Kunden flyttar den 15:e, när stängs abonnemanget?\n- Varför är fakturan högre i februari?\n"
          "- Kan man dela upp betalningen?\n- Vem kontaktar man vid strömavbrott?\n")

    # Tidslogg
    tid = [
        {"id": uid(), "vad": "Förslag och offert dataplattform", "projekt": "Dataplattform", "start": iso(dag(2026, 8, 21, 13)), "sekunder": 9000},
        {"id": uid(), "vad": "Läsa in mätvärden, första körningen", "projekt": "Dataplattform", "start": iso(dag(2026, 8, 26, 9)), "sekunder": 12600},
        {"id": uid(), "vad": "Prototyp: flyttflödet in i underlaget", "projekt": "AI-assistent kundtjänst", "start": iso(dag(2026, 8, 28, 13)), "sekunder": 10800},
        {"id": uid(), "vad": "Förberedelser inför styrgruppen", "projekt": None, "start": iso(dag(2026, 9, 1, 10)), "sekunder": 5400},
        {"id": uid(), "vad": "Mötesanteckningar och rollfördelning", "projekt": None, "start": iso(dag(2026, 9, 1, 16, 30)), "sekunder": 2700},
    ]
    skriv_json(MAPP / "tid.json", tid)
    per = {}
    for t in tid: per.setdefault(t["projekt"] or KUND, []).append(t)
    md = [f"---\ntyp: tid\nkund: \"{KUND}\"\ngenererad: kundkoll\n---\n\n# Tid · {KUND}\n\n*Skriven av Bjarbys kundkoll och byggs om vid varje sparning — ändra i appen, inte här.*\n"]
    for p, rader in sorted(per.items()):
        s = sum(r["sekunder"] for r in rader)
        md.append(f"\n## {p} · {int(s // 3600)}:{int(s % 3600 // 60):02d}\n\n" + "".join(
            f"- {datetime.fromisoformat(r['start']).strftime('%Y-%m-%d %H:%M')} · {int(r['sekunder'] // 3600)}:{int(r['sekunder'] % 3600 // 60):02d} · {r['vad']}\n" for r in rader))
    skriv(MAPP / "Tid.md", "".join(md))

    # Chatt
    m1, mapp1 = inspelningar[0]
    skriv_json(MAPP / ".kundkoll" / "samtal" / f"{uid()}.json", {
        "id": uid(), "titel": "Vad lovade vi Karin senast?", "projekt": None, "möte": None,
        "meddelanden": [
            {"id": uid(), "roll": "människa", "text": "Vad lovade vi Karin senast?", "tid": iso(dag(2026, 8, 31, 8, 10)),
             "hänvisningar": [], "ursprung": "kunskapsbank", "mapp": None},
            {"id": uid(), "roll": "assistent",
             "text": "På uppstartsmötet den 20 augusti lovade Anders att skicka ett förslag på upplägg och tidplan före fredag [1]. Förslaget gick i väg den 21 augusti med offerten som bilaga [2]. Karin skulle i sin tur boka en avstämning om två veckor [1].",
             "tid": iso(dag(2026, 8, 31, 8, 10, )), "ursprung": "kunskapsbank", "mapp": None,
             "hänvisningar": [{"nummer": 1, "titel": "Uppstart dataplattform — sammanfattning", "typ": "sammanfattning",
                               "källa": str(mapp1 / "möte.json"), "datum": iso(dag(2026, 8, 20, 9, 30))},
                              {"nummer": 2, "titel": "Förslag: dataplattform på Fabric", "typ": "mejl",
                               "källa": str(MAPP / "Mail" / "mail.json"), "datum": iso(dag(2026, 8, 21, 16, 48))}]},
        ],
        "skapad": iso(dag(2026, 8, 31, 8, 10)), "ändrad": iso(dag(2026, 8, 31, 8, 11)),
    })

    # Lägesbild för dataplattformen
    läget = ("Dataplattformen är beställd och igång: förslaget på Fabric är skickat, Sara har gett läsbehörighet till mätdatabasen "
             "och elnätets mätvärden läses in i en första körning. Styrgruppen har pekat ut IT som ägare av datamodellen med ekonomi som beställare.\n\n"
             "**Närmast**\n- Investeringsbeslut i ledningsgruppen på måndag (Erik)\n- Rollfördelningen skrivs ner och skickas med mötesanteckningarna (Anders)\n\n"
             "**Väntar på**\n- Mätvärdena för juli från Sara, som skulle ha kommit senast fredag\n\n"
             "**Risker**\n- Fjärrvärmen levererar bara dygnsvärden, vilket kan bli för glest för veckorapporten")
    # Skriven strax efter allt annat, annars räknas bilden som gammal så
    # fort en anteckning har en senare ändringstid än sekunden den skrevs.
    skriv_json(MAPP / ".kundkoll" / "läget-Dataplattform.json",
               {"text": läget, "skriven": iso(datetime.now() + timedelta(minutes=2))})
    skriv(MAPP / "Projekt" / "Dataplattform" / "Läget.md",
          f"---\ntyp: läget\nprojekt: \"Dataplattform\"\nkund: \"{KUND}\"\nskriven: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n---\n\n# Läget · Dataplattform\n\n{läget}\n\n---\nSkriven av Bjarbys kundkoll ur uppgifter, möten och mejl. Skrivs om när underlaget ändras — redigera inte här.\n")
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"Klart: {MAPP}")

# ---------------------------------------------------------------- kalender
def kalender():
    skript = f'''
    tell application "Calendar"
        if not (exists calendar "{KALENDER}") then make new calendar with properties {{name:"{KALENDER}"}}
        tell calendar "{KALENDER}"
            set d1 to current date
            set day of d1 to (day of d1) + 1
            set hours of d1 to 10
            set minutes of d1 to 0
            set seconds of d1 to 0
            make new event with properties {{summary:"{KUND}: avstämning dataplattform", start date:d1, end date:d1 + 45 * minutes, location:"https://teams.microsoft.com/l/meetup-join/demo"}}
            set d2 to d1 + 2 * days
            set hours of d2 to 14
            make new event with properties {{summary:"{KUND}: demo AI-assistent för kundtjänsten", start date:d2, end date:d2 + 60 * minutes, location:"Björnen, Fjällbo"}}
            set d3 to d1 + 6 * days
            set hours of d3 to 9
            make new event with properties {{summary:"{KUND}: workshop kundregister", start date:d3, end date:d3 + 120 * minutes, location:"https://teams.microsoft.com/l/meetup-join/demo2"}}
        end tell
    end tell
    '''
    r = subprocess.run(["osascript", "-e", skript], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("Kalendern gick inte att skriva: " + r.stderr.strip())
    print(f"Tre möten ligger i kalendern «{KALENDER}».")

def ta_bort():
    if MAPP.exists():
        r = subprocess.run(["osascript", "-e", f'tell application "Finder" to delete POSIX file "{MAPP}"'],
                           capture_output=True, text=True)
        print("Kunden ligger i papperskorgen." if r.returncode == 0 else "Kunde inte flytta kunden: " + r.stderr.strip())
    r = subprocess.run(["osascript", "-e", f'tell application "Calendar" to if exists calendar "{KALENDER}" then delete calendar "{KALENDER}"'],
                       capture_output=True, text=True)
    print("Kalendern är borta." if r.returncode == 0 else "Kalendern: " + r.stderr.strip())

if __name__ == "__main__":
    arg = sys.argv[1:]
    if "--ta-bort" in arg:
        ta_bort()
    else:
        med_ljud = "--utan-ljud" not in arg
        if med_ljud and "--elevenlabs" in arg:
            eleven_förbered()
        skapa(med_ljud=med_ljud)
        if "--kalender" in arg:
            kalender()
