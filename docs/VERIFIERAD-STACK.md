# Verifierad stack

Allt här är **empiriskt uppmätt på den här maskinen** (M-serie, macOS 26.1, SDK 26.2),
inte hämtat ur dokumentation. Ändra inget här utan att köra om mätningen.

## Bygga utan Xcode

Bara Command Line Tools är installerat (`xcodebuild` saknas). Verifierat att
`swiftc` ändå kompilerar mot SwiftUI, AVFoundation, EventKit, Contacts,
ScreenCaptureKit, Speech och FoundationModels. Appen byggs med SwiftPM och
paketeras till en `.app` av `scripts/bygg-app.sh`.

Signering: `Developer ID Application: Brattoo AB (V783A2L763)` finns i nyckelringen.
Det spelar roll — en stabil signatur gör att TCC-behörigheter (mikrofon,
skärminspelning, kalender, kontakter) överlever ombyggen i stället för att
behöva godkännas om varje gång.

## Transkribering av svenska

### Apples SpeechTranscriber — DUGER INTE till svenska

```
SpeechTranscriber.supportedLocales → 31 språk, inget nordiskt
AssetInventory.status(sv_SE)       → unsupported
```

Fallgrop: `SpeechTranscriber.supportedLocale(equivalentTo: sv_SE)` returnerar
`sv_SE` trots att språket inte stöds. Lita inte på den — fråga `AssetInventory.status`.

### Apples DictationTranscriber — fungerar, men behövs inte

Används inte i appen. Dokumenterad här för att valet ska gå att ompröva.

```
DictationTranscriber.supportedLocales → 43 språk, sv_SE ingår (även da, nb, fi)
```

Modellen laddas ned automatiskt via `AssetInventory.assetInstallationRequest`.
Uppmätt på 90 s svenskt mötesljud: **3,1 s ≈ 29× realtid**, on-device.

Begränsningar: ingen interpunktion, ingen talaridentifiering, svag på
egennamn ("Anthropic" → "en Tropic", "GPT" → "GP E.T.").

Slutsats: KB-Whisper small är både bättre och snabb nog, se nedan. Att köra en
enda modellfamilj i stället för två parallella transkriberingsstackar är värt mer
än det ord-för-ord-strömmande som Apple ensam kan ge.

### KB-Whisper — appens transkribering, i två storlekar

Kungliga bibliotekets svenska finetune, `~/Projekt/whisper.cpp/models/kb_whisper_ggml_medium.bin`,
kört via `~/Projekt/whisper.cpp/build/bin/whisper-cli`.

Samma 90 s, samma maskin:

| Modell | Tid | Anthropic | GPT | Interpunktion | Svåra ord |
|---|---|---|---|---|---|
| Apple Dictation | 3,1 s | nej | nej | nej | – |
| whisper large-v3-turbo | 5,9 s | ja | ja | ja | "britta ner", "den äldre syskonet" |
| KB-Whisper medium | 6,6 s | ja | ja | ja | allt rätt |

KB-Whisper *medium* slår alltså large-v3-turbo på svenska trots mindre modell.
14× realtid → en timmes möte efterbearbetas på ca 4 minuter.

#### Fallgrop: mät i det läge modellen faktiskt körs i

På 90 s i ett svep **tappade både tiny och small ett helt stycke** som medium
fick med. Utelämnat innehåll är värre än felstavat, och slutsatsen hade blivit
att bara medium duger.

Men live körs modellen på korta fönster, inte på hela filen. Samma ljud i
15-sekundersfönster:

| Modell | per fönster | tappat stycke | egennamn |
|---|---|---|---|
| KB tiny | 0,24 s | kommer med | "Klåd", "Entropic" |
| KB small | 0,70 s | kommer med | Claude, Anthropic, GPT, OpenAI |

Utelämningen var alltså en artefakt av långa filer, inte av modellstorleken.

#### Roller i appen

| | modell | hur | uppmätt |
|---|---|---|---|
| Live under samtal | `kb_whisper_ggml_small` | `whisper-server`, modellen kvar i minnet | 0,47 s per 15 s-fönster |
| Arkiv efter samtal | `kb_whisper_ggml_medium` | `whisper-cli` en gång per spår | 14× realtid |

Att hålla `whisper-server` igång är hela poängen med live-läget: startas
processen om per fönster laddas modellen varje gång.

#### Hela kedjan, uppmätt

`Kundkoll --prov-ljud <fil.wav>` kör ljud → buffring → fönster → whisper →
yttranden skarpt. På samma 90 s:

```
14 fönster, 1,5–15 s långa, delade vid naturliga pauser
0,23–0,54 s per fönster
5,0 s totalt för 90 s ljud = 18× realtid
189 ord, korrekt interpunktion, egennamn rätt
```

Obs: binären `main` i whisper.cpp är en deprecated stub som returnerar direkt
utan att göra något. Använd `whisper-cli`.

## Whisper hittar på text ur tystnad

Det här är den allvarligaste fällan i hela transkriberingen. Uppmätt med
KB-Whisper small:

```
5 s ren tystnad, utan VAD  →  " Tack."
5 s svagt brus,  utan VAD  →  " Tack."
samma ljud,      med VAD   →  ""
```

I skarp drift blev det värre än så: ett samtal med pauser gav rader som
"Tack för hjälpen", "En bra berättelse", "Ett brev från mig" — och en modell
som fastnat i en loop: "Ett stort stort stort stort stort stelt stort …".
Ingenting av det hade sagts.

Tre lager skyddar mot det, i den ordningen:

1. **Fönster utan tal skickas aldrig iväg.** `Ljudbuffring` väger ljudet mot
   rummets egen bakgrund och kastar fönstret om det innehåller mindre än
   0,25 s tal. Billigast, och tar bort problemet vid källan. Måttet måste vara
   relativt — se nästa avsnitt.
2. **Silero VAD i whisper**, både i servern och i `whisper-cli`:
   `--vad -vm models/ggml-silero-v5.1.2.bin`. Modellen finns redan i
   whisper.cpp-uppsättningen.
3. **Filter på det som ändå slinker igenom.** Några stående fraser whisper
   lägger i munnen på tystnad, och en loopdetektor: samma ord fyra gånger i rad,
   eller ett fåtal unika ord utspridda över en lång text.

Validerat åt båda hållen på en fil med 12 s tystnad + 8 s tal + 10 s svagt brus
+ 12 s tystnad: buffringen gav två fönster, båda inom talpartiet. Tystnaden och
bruset gav noll.

## ⚠️ Taldetekteringen måste mäta mot rummet, inte mot en konstant

Den filen var inte representativ, och det kostade en hel funktion. Dess tal låg
på RMS 0,15–0,23. Så låter ingen mikrofon. Uppmätt på riktigt material:

| källa                              | tal (RMS)     | bakgrund  |
|------------------------------------|---------------|-----------|
| MacBook Pro-mikrofonen             | 0,004–0,016   | 0,0003    |
| datorljud från videosamtal         | 0,05–0,25     | ~0        |
| kalibreringsfilen (syntetiskt tal) | 0,15–0,23     | 0,0017    |

Trösklarna som föll ut ur kalibreringsfilen — enskilda prov över 0,02, minst
12 % av fönstret — hamnade i ett glapp som inte finns i verkligheten.
Mätt på en 51 s inspelning där användaren talade: **noll fönster** släpptes
igenom, de fyra som innehöll tal hade talandel 0,076 / 0,064 / 0,0045 / 0,052.
Arkivpasset, som läser filen i ett svep, hittade samma tal utan problem — så
live var tyst medan transkriptet efteråt var fullständigt. Motpartsspåret
fungerade hela tiden, eftersom datorljud ligger tio till fyrtio gånger högre.

Ingen konstant klarar båda spåren. `Ljudbuffring` skattar därför bakgrunden
löpande — 10:e percentilen av RMS per 20 ms-block över de senaste 20 sekunderna
— och räknar ett block som tal när det är fyra gånger starkare än så. Ett golv
på 0,0005 hindrar digital tystnad från att göra minsta knäpp till tal.

Percentilen är låg med flit: det är i pauserna mellan orden bakgrunden syns.
Med kort historik faller den tillbaka på det tystaste blocket, vilket är rätt
vid start — ett brusigt rum känns igen direkt, och en inspelning som börjar
mitt i en mening hittar sitt golv i första pausen.

Uppmätt efter ändringen:

| material                          | före        | efter                    |
|-----------------------------------|-------------|--------------------------|
| 51 s mikrofon, användaren talar    | 0 fönster   | 4 fönster, allt fyra sagt |
| 39 min motpartsspår, riktigt samtal | 91,3 % av talet | 92,7 % (212 fönster, 194 rader) |
| kalibreringsfilens brus och tystnad | 0 fönster   | 0 fönster                |

Testljudet i sviten pulserar i stavelsetakt i stället för att ligga still. En
konstant nivå är inte tal utan ett brummande fläktljud, och det var just en
konstant som förde kalibreringen vilse. Samma tal provas på RMS 0,004 till 0,2
— hela spannet mellan mikrofon och datorljud.

## Ljudinfångning — vald mikrofon + datorljud

ScreenCaptureKit ger båda spåren separat i en och samma ström:

```
SCStreamOutputTypeAudio       macOS 13+   datorljud (motparten)
SCStreamOutputTypeMicrophone  macOS 15+   mikrofon (jag)
SCStreamConfiguration.microphoneCaptureDeviceID   väljer mikrofon
SCStreamConfiguration.excludesCurrentProcessAudio  hindrar återkoppling
```

Att spåren är separata ger "vem sa vad" utan diarisering.

Kostnad: kräver behörighet för skärminspelning även när bara ljud används,
eftersom en SCStream måste ha ett innehållsfilter. Appen fångar minsta möjliga
yta och kastar videorutorna.

## Apples on-device-LLM (FoundationModels)

```
SystemLanguageModel.default.availability  → available
supportedLanguages                        → sv-Latn-SE ingår
```

Uppmätt svarstid på en svensk sammanfattningsfråga: **1,2 s**. Gratis, lokalt.

Roll i appen: realtidsassistansen under samtal (etapp 4).

## Sökning i kunskapsbanken

`NLEmbedding.sentenceEmbedding(for: "sv")` och `wordEmbedding` returnerar **nil** —
Apple har inga svenska vektorer. Kunskapsbankens sökning kan därför inte byggas
på inbyggda embeddings. Planen är SQLite FTS5 med BM25.


## Bygga och köra

```bash
./scripts/bygg-app.sh          # bygger och signerar dist/Kundkoll.app
swift build                    # bara kompilering
.build/arm64-apple-macosx/debug/Kundkoll --test              # 61 enhetstester
.build/arm64-apple-macosx/debug/Kundkoll --prov-ljud f.wav   # hela kedjan skarpt
```

Testramverk: varken Swift Testing eller XCTest följer med Command Line Tools.
De finns i Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`),
men testerna kör i stället som ett läge i appen så att de fungerar oavsett
vilken verktygskedja `xcode-select` pekar på.

## Buggar som proven har fångat

Noterade för att de visar vad proven är värda:

**Tystnaden räknades från fel ände.** `tystSedan` sattes till slutet av den
tysta ljudbiten i stället för dess början, så en enda lång tyst bit aldrig hann
bli 0,6 s gammal. Fönstret stängdes då först vid 15-sekundersgränsen — live-
transkriptet hade kommit med 15 sekunders fördröjning i stället för 1–2.

**Deadlock i ljudprovet.** En semafor på huvudtråden väntade på arbete som
behövde huvudtråden för att köra.

**En mätning som var för bra för att stämma.** Första mätningen av
`whisper-server` gav 8 ms per fönster. Porten var upptagen av ett annat lokalt
projekt, så curl träffade fel tjänst. Därav `Whisper.ledigPort()`, som frågar
operativsystemet i stället för att anta att en port är ledig.

## Mail: AppleScript eller filerna direkt

Mejlen går att komma åt på två sätt. Båda uppmätta på den här maskinen
(43 138 meddelanden i huvudkontots INBOX, 78 136 `.emlx`-filer, 5,5 GB):

| | AppleScript | grep i ~/Library/Mail |
|---|---|---|
| specifik adress | 0,7 s | 3,5 s |
| 64 träffar | 4,8 s | 3,5 s |
| 450 träffar | 31,4 s | 3,5 s |
| behörighet | Automatisering | Full Disk Access |

Filvägen är konstant i tid, AppleScript skalar med antalet träffar. Men appen
söker alltid på en bestämd kundadress, aldrig på breda domäner — och där är
AppleScript snabbast och kräver den mindre behörigheten. Därför AppleScript.

Spotlight fungerar inte: `mdutil -s ~/Library/Mail` svarar "unknown indexing
state" och `mdfind` ger noll träffar trots att filerna finns.

Att grep:a brett är dessutom missvisande — "apple.com" matchar 75 532 av
78 136 filer, eftersom strängen förekommer i huvuden och signaturer.

### Fallgropar i AppleScript

- **Identifierare måste vara ASCII.** `set gräns to …` ger
  `A unknown token can't go after this identifier (-2740)`. Kommentarer med
  å ä ö går bra.
- `≥` i en skriptfil ger samma fel; skriv `>=`.
- Datumfiltrering med `whose date received > date "…"` fungerar inte
  tillförlitligt. Mail lämnar datum som `"Tuesday, 18 August 2026 at 00:49:37"`
  och det får tolkas i efterhand.
- Ämnesrader innehåller både `|` och tabbar. Fälten avgränsas därför med
  ASCII 31.

## ⚠️ Allt som ligger på disk läses för hand

Swift använder inte standardvärden när en nyckel saknas. Ett nytt fält på en
typ som sparas gör därför alla tidigare filer oläsbara — och eftersom de läses
med `try?` försvinner de utan ett ord. Det har hänt två gånger här: mejlcachen
tömdes när `text` lades till på `Mejl`, och en inspelning slutade synas i
listan.

Mätt på hela kodbasen 2026-09-01: **alla** sparade typer utan handskriven
`init(from:)` föll på den minsta JSON en äldre version kan ha lämnat efter sig
— sammanfattningen inne i `möte.json` (som tar hela inspelningen med sig),
röstprofilerna som byggts upp över månader, chattarnas meddelanden, de
kopplade mapparna och modellvalet. 19 prov, 19 fällda.

Regeln är därför: **varje typ som skrivs till disk har en handskriven
`init(from:)` där varje fält läses med `decodeIfPresent` och ett standardvärde.**
Provsviten `Lagring` håller efter det med en minsta JSON per typ, och provar
också åt andra hållet — ett okänt fält från en nyare version får inte fälla
läsningen.

Andra ledet: en `möte.json` som ändå blir oläslig — avbruten skrivning, trasig
disk — får inspelningen att listas som påbörjad i stället för att bara
försvinna.

## Fyra arkivmotorer, uppmätta på samma inspelning

Livetranskriberingen är alltid whisper.cpp — fönstren är sekunder långa och
kräver en varm server. Arkivpasset kan däremot väljas, och alla fyra är
uppmätta på samma 51-sekundersinspelning genom appens egen kodväg:

| motor | modell | tid | notering |
|---|---|---|---|
| whisper.cpp | kb_whisper_ggml_medium | 12,8 s | bäst svenska: enda som tog «upp ett 20-tal uppgifter» rätt tillsammans med Scribe |
| MLX | whisper-large-v3-turbo | 3,3 s | «definierat öppet 20-tal», sista raden blev fel |
| OpenAI | whisper-1 | 2,6 s | «definierat i öppet 20-tal»; ljudet skickas ut, m4a-komprimerat (WAV-gränsen är 25 MB) |
| ElevenLabs | scribe_v2 | 1,9 s | «upp ett tjugotal uppgifter» — rätt; ord med tider, inte segment; sys ihop vid pauser ≥ 0,9 s |

⚠️ **mlx-whisper kräver mlx == 0.31.2 på den här maskinen.** Nyare mlx (0.32.2)
faller mot macOS 26.1:s Metal-kompilator med «unsupported
deferred-static-alloca-size function body» och lämnar ingen utdata. Paketet
ligger i transcriber-venven, samma som röstanalysen lånar.

Scribe finns som scribe_v1 och scribe_v2 — båda svarar, v2 är standard.
Svarsformatet är ord (word/spacing/audio_event) med start/slut; bara
word-raderna används. Whispers påhittsfilter (`ärTomtLjud`, loopdetektorn)
körs på alla motorers utdata — text är text, oavsett var den kom ifrån.

## ⚠️ KB-Whisper översätter engelska till svenska — oavsett språkflagga

Uppmätt på ett riktigt engelskt möte (19 min, Teams): kb_medium med `-l sv`
översatte hela mötet till svenska («Jag har inte sett en respons från Nina»),
och med `-l en` och `-l auto` **också** — finjusteringen har i praktiken
tappat förmågan att skriva engelska. kb_small behåller mer («I say we go
ahead and get started», men «sänt … weeknd»), duger för live men inte arkiv.

MLX large-v3-turbo med språket utelämnat: «Detected language: English» och
felfri engelska. Därför:

- Språk väljs per import och per inspelning: Svenska (standard), Engelska,
  eller Avgör själv.
- **Vägvalet**: whisper.cpp med KB-modell + annat språk än svenska routas
  till MLX (eller stopp i klartext om mlx-whisper saknas). Molnmotorer och
  icke-KB-modeller rör inte vägvalet.
- Livefönstren skickar `language` per anrop till whisper-server.
- Mötesvyn kan **transkribera om** en importerad inspelning på valt språk —
  ljudet finns ju kvar. Även headless: `--transkribera-om <mapp> [sv|en|auto]`.

## ⚠️ Wav-huvudet skrevs först vid stopp

Spårskrivaren fyllde i längderna i wav-huvudet när filen stängdes. En krasch
eller ⌘Q mitt i ett möte lämnade huvudet med längden noll, och whisper,
AVAudioFile och spelaren läste filen som tom fast ljudet låg där. Nu skrivs
huvudet om var femte sekund ljud, `Wav.rättaHuvud` rättar ett trasigt huvud
ur filens storlek innan arkivpasset, och en avslutshanterare stoppar en
pågående inspelning innan appen går ned. Provat i sviten Robusthet: en fil
med huvudlängd noll läses som en sekund ljud efter rättningen.

## ⚠️ whisper-server överlevde appen

`Whisper.avsluta()` anropades aldrig. Uppmätt 2026-09-02: 33 föräldralösa
whisper-server på maskinen efter två dagars byggen, en per appstart. Litet
minne var för sig — modellen är minnesmappad — men de försvinner aldrig.
Avslutshanteraren i `Appdelegat` dödar servern när appen stängs.

## Underprocesser väntas in utan att låsa trådar

`waitUntilExit` inne i en async-funktion blockerade en av Swifts
samarbetstrådar — pyannote i minuter — och ett osascript som stod och
väntade på en behörighetsfråga hängde mejlsökningen för evigt. `Underprocess`
väntar in avslutet med en continuation, läser rören på GCD-trådar och
avslutar processen vid tidsgräns eller avbrott. Tidsgränserna: osascript
3 respektive 10 minuter, python 30 minuter, whisper-cli och mlx fyra gånger
ljudets längd (minst en kvart), claude 5 minuter.

## Arkivpasset är ett, och det går att köra om

Efter mötet, efter en import, vid omkörning från mötesvyn och när ett
avbrutet pass tas upp igen körs samma `Efterbearbetning`. Den skriver
`bearbetas` i möte.json medan den pågår och `arkivfel` om den faller — så
att ett möte aldrig mer står som «live» för alltid utan förklaring. Faller
ett spår behålls livetranskriptet: ett arkivtranskript med bara ena parten
vore en försämring förklädd till förbättring.

## Sökvägar i två skepnader

`/var` är en länk till `/private/var`. Det som listas ur en mapp kommer
upplöst medan det som byggts ur kundmappen inte gör det, och
`resolvingSymlinksInPath` lämnar en väg som inte finns orörd — precis
läget efter en flytt. `Arkivet.kanonisk` tar bort `/private` för hand, och
alla jämförelser av sökvägar går genom den. Sviten Robusthet fällde de
första försöken på just detta.
