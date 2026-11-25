# Röstanalys

Spårseparationen ger "jag mot motparten". Det räcker för ett telefonsamtal,
men i ett möte med fyra personer är hela motpartsspåret en enda röst. Det här
steget delar upp motparten och sätter namn på personerna.

Allt här är uppmätt. Ändra ingen tröskel utan att köra om `--prov-röst`.

## Två modeller till två olika saker

**Uppdelningen** görs av **pyannote** (`pyannote/speaker-diarization-3.1`), som
är tränad och kalibrerad för just det och hittar antalet talare själv.

**Igenkänningen mellan samtal** görs av **ECAPA-TDNN**
(`speechbrain/spkrec-ecapa-voxceleb`), 192-dimensionella normerade vektorer.
Det är den som gör att någon man talat med förr känns igen nästa gång.

Båda körs i `scripts/rostanalys.py` som en Pythonprocess, eftersom det inte
finns någon motsvarighet inbyggd i macOS. Modellerna ligger i
`~/.cache/huggingface` respektive `~/.cache/speechbrain`; skriptet kör med
`HF_HUB_OFFLINE=1` så att pyannote använder cachen i stället för att kräva
ett konto.

### Egen klustring provades först, och höll inte

Uppdelningen byggde ursprungligen på att klustra ECAPA-avtryck. Det gick inte
att få att fungera på riktigt material:

| tröskel | 39 min, två personer | fem talare med facit |
|---|---|---|
| som kalibrerad | 58 röster | 12 röster, 91 % rätt |
| sänkt | 2 röster, men fel fördelning | 2 röster, 33 % rätt |

Ingen konstant klarade båda. Ett relativt klipp i sammanslagningskedjan löste
tvåpersonersfallet men slog ihop de två personerna i praktiken.

pyannote mot samma material:

| | pyannote |
|---|---|
| 39 min, två personer, inget antal angivet | **2 talare, 70,5 % / 29,5 %** |
| fem talare, antal angivet | **99 % av turerna rätt** |

Klustringen finns kvar som reserv om pyannote inte går att köra, men är
märkbart sämre. `Sökvägar.harDiarisering` säger om modellen finns.

Kostnad: 172 sekunder för 39 minuter ljud, alltså ungefär 14 gånger snabbare än
realtid. Körs i bakgrunden efter samtalet.

### Antalet talare hjälper fortfarande

Utan angivet antal slog pyannote ihop de fyra AI-rösterna i facitmaterialet till
en. Det är begripligt — röster ur samma TTS-modell *är* akustiskt lika. Med
antalet angivet blev fördelningen jämn (150, 147, 119, 112, 72 sekunder) och
träffsäkerheten 99 %.

Antalet kommer från kalendern när inspelningen startats från ett möte, eller
från knapparna i «Vem är vem». Miljön delas med `~/Projekt/transcriber`
(torch + speechbrain finns redan där).

Två fallgropar som redan är hanterade i skriptet:

- `torchaudio` 2.10 har tagit bort `list_audio_backends`, `AudioMetaData` och
  `info`, som speechbrain och pyannote fortfarande kallar på.
- speechbrain 1.0.3 skickar `use_auth_token` till `hf_hub_download`, som nyare
  `huggingface_hub` inte tar emot. Utan patchen faller modelladdningen.

## Kalibrering av igenkänningen: beror på hur långt ljudet är

Det här gäller ECAPA-avtrycken, alltså igenkänningen mellan samtal — inte
uppdelningen, som pyannote sköter.

Mätt på `afterwork_meeting.mp3` (fem talare, känt facit) genom att jämföra
klipp inom samma talare mot klipp mellan olika talare:

| Klipplängd | inom talare | mellan talare | rätt klassade par | bästa tröskel |
|---|---|---|---|---|
| 1 s | 0,335 | 0,212 | 83,4 % | 0,48 |
| 2 s | 0,535 | 0,345 | 87,5 % | 0,58 |
| 3 s | 0,626 | 0,399 | 90,4 % | 0,64 |
| 5 s | 0,735 | 0,478 | 91,9 % | 0,71 |
| 7 s | 0,796 | 0,501 | 95,6 % | 0,74 |
| 10 s | 0,819 | 0,589 | **100 %** | 0,78 |

Det här är hela skälet till att `Tröskel.samma(sekunder:)` finns. En fast
tröskel skulle antingen slå ihop olika personer på korta bitar eller dela upp
samma person på långa.

### Förbehåll: mätt på syntetiska röster

Facitmaterialet är ElevenLabs-röster. De är **svårare** än riktiga människor,
eftersom röster ur samma TTS-modell liknar varandra. Kontrollmätning på åtta
riktiga inspelningar ur `transcriber/storage`:

```
olika personer, riktiga röster : 0,23
olika personer, syntetiska     : 0,50  (upp till 0,82 för de mest lika)
```

Kurvan ovan är alltså konservativ. Trösklarna bör hålla med marginal på
riktiga kundsamtal, men en kalibrering på riktigt inom-talare-material
återstår att göra.

## Två rundor

**Första rundan** klustrar enskilda turer med tröskeln för den kortaste bitens
längd. Den håller hellre isär än slår ihop.

**Andra rundan** jämför medelavtryck över hela grupper. Nu finns mycket mer
ljud bakom varje jämförelse, så det som första rundan tvingades hålla isär kan
slås ihop. Men den behöver ett påslag: två personer med lika röster hamnar högt
även med mycket underlag. Uppmätt på samma facit:

| Påslag | Grupper | Turer i rätt grupp | Grupper med blandade talare |
|---|---|---|---|
| 0,00 | 7 | 72 % | **1** |
| 0,03 | 9 | 76 % | **1** |
| **0,06** | **12** | **91 %** | **0** |
| 0,09 | 13 | 87 % | 0 |
| 0,12 | 16 | 80 % | 0 |

0,06 är valt. Utan påslag slås Claude och Gemini ihop — de två mest lika
rösterna, som ligger på 0,77 redan i förmätningen.

## Fast tröskel fungerar inte — kalibreringen ovan räckte inte

Trösklarna ovan är mätta på ElevenLabs-röster. På ett riktigt 39 minuter långt
samtal mellan två personer gav de **58 röster**, där de två rätta täckte 59 %
av taltiden. Resten var smulor på 2–8 sekunder.

En sweep visade varför en konstant inte kan lösa det:

| justering | två riktiga personer | fem TTS-röster (facit) |
|---|---|---|
| 0,00 | 19 röster, 79 % | 6 röster, 75 % rätt |
| −0,10 | 13 röster, 85 % | 2 röster, 29 % rätt |
| −0,20 | **2 röster, 100 %** | 2 röster, 33 % rätt |

Tröskeln som gör tvåpersonersfallet perfekt slår ihop fem talare till två.
Orsaken syns i sammanslagningskedjorna: klippet sker vid likhet 0,38 i det
riktiga samtalet och vid 0,73 i TTS-materialet. Röster ur samma TTS-modell är
akustiskt lika varandra på ett sätt riktiga människor inte är, och samma person
varierar mer över 39 minuter än en syntetisk röst gör.

## Tre ändringar

**Kärnor först, korta turer sedan.** Klustring rakt över alla turer behandlar en
tresekunderstur som lika tillförlitlig som en tjugosekunderstur. Nu byggs
kärnor av de långa turerna, och varje kort tur läggs i den kärna den liknar
mest — jämförd mot kärnans medelavtryck, så bara ena sidan är brusig.

**Klippet är relativt, inte absolut.** Klustringen går hela vägen ner till en
grupp medan varje sammanslagnings likhet sparas. Likheten faller monotont, och
det största fallet är övergången från att slå ihop samma person till att slå
ihop olika. Där klipps det. Måttet blir relativt inspelningen i stället för en
konstant som passar ett material och inte ett annat.

**Kalendern vet ofta svaret.** Startas inspelningen från ett möte finns
deltagarlistan, och antalet kallade är antalet röster att vänta sig. Är antalet
känt väljs det läget direkt i stället för att gissas fram. Användaren kan också
ange antalet efteråt i «Vem är vem» — den som var med i samtalet vet hur många
som talade, och ett angivet antal är ett besked, inte en gissning: räcker inte
klustringen slås de minsta grupperna ihop tills antalet stämmer.

Uppmätt efter ändringen:

| | före | efter |
|---|---|---|
| 39 min, två personer, ingen ledtråd | 58 röster, 59 % täckning | **2 röster, 100 %** |
| Fem talare med facit, ledtråd 5 | 12 röster, 91 % rätt | **5 röster, 96 % rätt** |

## Felprofilen är medvetet sned

Med kalibrerade trösklar blir resultatet 12 grupper för 5 talare: fem stora
grupper som nästan exakt motsvarar personerna, plus sju korta restbitar på
7–17 s som inte gick att placera säkert.

Det är rätt sorts fel. **Ingen grupp innehåller två personer.** Att samma
person dyker upp som två rader är något användaren rättar på en sekund; ett
fel namn i ett kundtranskript upptäcks kanske aldrig. Därför:

- namngivning kräver högre säkerhet än gruppering (`Tröskel.namnge`)
- osäkra grupper lämnas namnlösa i stället för att gissa
- samma sparade profil sätts aldrig på två grupper i samma samtal

## Profiler

Röstavtryck sparas per kund i `Kontakter/röstprofiler.json`, inte globalt.
Samma person kan förekomma hos flera kunder, och profilerna ska inte läcka
mellan kundärenden.

En profil samlar upp till åtta avtryck och behåller de längsta. Vid jämförelse
räknas bästa träffen, inte medelvärdet — samma person kan låta olika i olika
samtal, och ett dåligt avtryck ska inte dra ned de bra. Bara turer på minst
`Tröskel.minstaProfilLängd` (4 s) får bygga profil.

## Köra provet

```bash
Kundkoll --prov-röst <ljud.wav> <whisper.json> [facit.json] [--väntade N]
Kundkoll --prov-omröst <inspelningsmapp> [antal röster]   # mot en färdig inspelning
KUNDKOLL_VISA_KEDJA=1 Kundkoll --prov-omröst ...          # visa sammanslagningskedjan
KUNDKOLL_JUSTERING=-0.1 Kundkoll --prov-omröst ...        # sweepa trösklarna
```

`--prov-omröst` cachar röstavtrycken i inspelningsmappen så att en tröskelsweep
tar sekunder i stället för minuter. Ta bort `.avtryck-cache.json` när du är klar.

Facit är en lista med `{"namn", "start", "slut"}`. Provet skriver ut en
förvirringsmatris och andelen turer som hamnat i rätt grupp.

## Möte i rummet

I rummet talar alla, jag också, in i samma mikrofon. Mitt spår är då inte
bara jag, och tvåspårsmodellen («Jag» mot «Motpart») lägger hela mötet under
«Jag». Uppmätt 24 november 2026: fyra möten på plats, datorljudet rena nollor
i alla fyra, mikrofonen 1–4 minuters tal — allt hamnade under «Jag».

Vägen nu:

- **Var** väljs vid start, «Via datorn» eller «I rummet». Kalendern
  föreslår: en möteslänk är via datorn, inget länk är på plats. Tyst
  datorljud och minst 30 s tal i mikrofonen gör mötet till ett rumsmöte
  oavsett val (`Inspelningssession.låterSomRummet`). Varningen om dött
  datorljud har en knapp «Mötet är i rummet».
- Efter mötet blandas mikrofon och datorljud till `motpart.wav`
  (`Rumsljud`); originalen sparas som `mikrofon.wav` och `datorljud.wav`.
  Sitter några med via datorn samtidigt hörs de i blandningen. Sedan tar
  passet samma väg som en importerad fil: ett spår, pyannote delar upp alla.
  Antalet från kalendern räknas +1, eftersom de kallade räknas utan mig.
- **Min röst** är den enda profil som är gemensam för alla kunder, i
  `<Kunder>/.kundkoll/min-röst.json`. Den lärs in (1) ur mitt spår i möten
  via datorn — bara när datorljudet haft minst 60 s tal, annars satt alla
  troligen i rummet och mitt spår är också de andra — och (2) från
  «Det här är jag» i «Vem är vem». Den känns igen som gruppen «Jag», blir
  aldrig kontakt hos kunden och länkas inte som deltagare.
- Äldre möten kan göras om: högerklick → «Det var ett möte i rummet».

Uppmätt med pyannote på tre av mötena från 24 november: 3, 3 och 3 röster
där allt tidigare var «Jag». Min röst mellan två mikrofoner (MacBook mot
AirPods, möten via datorn): likhet 0,26–0,57. Ingen av rösterna i de tre
rumsmötena liknade min (0,05–0,22) — troligen sa jag lite i dem, men det är
inte bekräftat. Igenkänningen av mig i rummet är alltså inte bevisad på
riktigt material än; «Det här är jag» ger ett avtryck från rummets mikrofon.
