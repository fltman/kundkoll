# Kundkoll

[![Patreon](https://img.shields.io/badge/Patreon-st%C3%B6d%20projektet-f96854?logo=patreon&logoColor=white)](https://www.patreon.com/AndersBjarby)

Nativ macOS-app för att hålla ordning på mötes- och telefontranskriberingar
per kund och projekt. Allt ljud och all transkribering sker lokalt på datorn.

## Läge

Alla fyra etapper är klara.

| Etapp | Innehåll | Läge |
|---|---|---|
| 1 | Inspelning av vald mikrofon + datorljud, live-transkript på svenska, mappstruktur med Obsidian-vault per kund | klar |
| – | Röstanalys som delar upp motpartsspåret och känner igen vem som talar | klar |
| 2 | Kontakter, kalender och mejl kopplat till rätt kund | klar |
| 3 | Kunskapsbank och chatt per kund och projekt | klar |
| 4 | Insikter under samtal — fångar frågeställningar och svarar ur kunskapsbanken | klar |

## Layout

Kunder och deras projekt ligger som träd i sidopanelen. Innehållet har flikar —
översikt, inspelningar, anteckningar, mejl — i stället för en lång rulle.
Chatten är en panel som fälls ut till höger och följer det som är valt.

Inspelningen har ett **eget fönster**, som går att lägga bredvid Teams eller på
en andra skärm. Under tiden fungerar resten av appen som vanligt: slå upp vad
som sades förra gången, skriv en anteckning, fråga chatten. En rad längst ned i
huvudfönstret visar att inspelningen pågår och kan stoppa den.

Startas inspelningen från ett kalendermöte börjar den direkt — titel och
deltagare finns i mötet, och mikrofonen är den som användes sist.

Stängs inspelningsfönstret fortsätter inspelningen; «Visa» på raden längst
ned öppnar det igen. ⌘Q mitt i ett möte stoppar och sparar först, och
wav-filerna skrivs så att de är läsbara även om appen skulle falla mitt i.

## Så fungerar inspelningen

Mikrofonen och datorljudet fångas som **två skilda spår** i samma ström
(ScreenCaptureKit). Att de är åtskilda ger "vem sa vad" utan diarisering: ditt
spår är du, det andra är motparten.

Ljudet delas i fönster vid naturliga pauser i talet och skickas till KB-Whisper
(Kungliga bibliotekets svenska modell) medan samtalet pågår. Vilken lokal
modell liven använder väljs under ⌘,. Fönster utan tal
skickas aldrig iväg: whisper hittar annars på text ur tystnad — se avsnittet i
`docs/VERIFIERAD-STACK.md`. Efter samtalet går
en större modell igenom hela ljudet en gång till och ersätter live-transkriptet
med arkivkvalitet.

Färdiga inspelningar går också att lägga till: en mp4 från Teams eller Zoom, en
m4a från telefonen, en wav från diktafonen. Släpp filen på kunden eller använd
knappen i verktygsraden. Där finns ingen kanaluppdelning, så röstanalysen får
dela upp talarna — och en av dem kan vara du. Hittar transkriberingen inget
tal, eller faller den, ligger det omräknade ljudet kvar med felet i listan, så
att importen kan köras om på ett annat språk i stället för från början.

Sitter flera personer i mötet delas motpartsspåret upp per röst med pyannote,
och personer kunden är känd för sedan tidigare känns igen automatiskt via
röstavtryck. Vet du antalet röster kan du ange det i «Vem är vem» — det ger
märkbart bättre uppdelning. Osäkra röster lämnas
namnlösa hellre än att gissa fel.

Språket väljs per möte och import: svenska, engelska eller låt motorn avgöra.
KB-Whisper är svensktrimmad och översätter engelska till svenska — uppmätt
även med språket satt till engelska — så engelska möten tar automatiskt vägen
via MLX eller den valda molnmotorn, och varje möte går att transkribera om
från mötesvyn eller med högerklick i listan.

Arkivpasset — genomlyssningen efter mötet — har fyra valbara motorer:
whisper.cpp (standard, bäst svenska i mätningen), whisper via Apples MLX,
Whisper hos OpenAI och Scribe hos ElevenLabs. De lokala lämnar aldrig datorn;
molnen skickar ljudet och säger det i klartext i inställningarna. Alla fyra
är uppmätta på samma inspelning — tabellen står i `docs/VERIFIERAD-STACK.md`.

Se `docs/VERIFIERAD-STACK.md` och `docs/RÖSTANALYS.md` för mätningarna bakom
varje val.

## Omvärlden

Kundvyn visar kommande möten, kontakter och mejl som hör till kunden.

**Kalender** (EventKit): ett möte räknas som kundens om någon deltagare finns
bland kundens kontakter, har kundens e-postdomän, eller om kundnamnet står i
titeln. Startas inspelningen från ett möte följer titeln med — och de kallade
blir förslagen när rösterna ska märkas.

**Kontakter** (Contacts): personer hämtas ur adressboken eller skrivs upp för
hand, och redigeras i appen — namn, roll, flera adresser och telefonnummer. En
kontakt som skrivits upp för hand kan läggas upp i macOS Kontakter, och ändringar
skrivas tillbaka dit. Det sker bara på knapptryck: adressboken är din egen och
delas med telefonen, så appen ändrar inget där i bakgrunden. En person du satt
namn på i ett transkript läggs upp som kontakt automatiskt.

**Mail** (AppleScript): söker mejl på kundens adresser, öppnar dem i Mail.
Vägen är vald efter mätning — mejlen ligger också som filer under
`~/Library/Mail`, vilket är snabbare vid breda sökningar men kräver Full Disk
Access. Eftersom vi alltid söker på bestämda kundadresser räcker AppleScript,
som bara behöver automationsbehörighet.

## Efter mötet

Ett fyrtio minuter långt samtal blir fyra hundra rader transkript. Det man
behöver därifrån är tre saker, och de skrivs automatiskt efter
efterbearbetningen: vad mötet handlade om, vad som beslutades, och vad någon
lovade att göra. Allt hamnar i `Transkript.md`, så det syns i Obsidian.

Att öppna ett möte ger därför inte en vägg av text. Vyn har tre flikar —
sammanfattning, transkript, att göra — och en chattpanel där hela samtalet
ligger som underlag vid sidan av kunskapsbanken. Åtagandena är mötets egna
kort på tavlan, inte en kopia: bockar man av ett här syns det där. Varje
transkriptrad har en spelknapp — transkriptet är whispers ord, ljudet är
facit. En knapp skriver ett uppföljningsmejl som utkast i Mail, och när
efterbearbetningen blir klar i bakgrunden säger en notis till — klicket
öppnar mötet. Faller den säger notisen det också, och mötet får märket «fel»
i listan med orsaken i verktygstipset; stängs appen mitt i blir märket
«avbruten». Högerklick på mötet kör om hela passet — transkribering, röster,
sammanfattning — på valt språk. Mötet behåller sitt id, så chattar och
uppgifter följer med, och namn som satts för hand lärs in som röstavtryck
först så att personerna känns igen i den nya uppdelningen. Arbetet går i kön
längst ned i fönstret, som kan avbrytas och överlever en omstart.

Chattens svar strömmar in medan de skrivs, hos alla fem leverantörerna.

## Inför mötet

En kvart före varje kundmatchat möte kommer en notis; klicket öppnar briefen —
förra mötet i samma serie med kärna och obesvarade frågor, tavlans öppna
åtaganden och mejlen sedan sist. Samma sida nås med «Förbered» på mötesraden.
Briefen byggs helt ur det som redan finns: ingen modell, ingen väntan.

Återkommande möten kedjas till **serier** på titeln med siffrorna bortplockade.
Mötesvyn visar «Förra gången», och mötets chatt får förra sammanfattningen som
stående underlag.

## Läget och tiden i ett projekt

Projektöversikten inleds med **Läget just nu** — en lägesbild skriven av
modellen ur mötessammanfattningar, tavlan, mejl och anteckningar, cachead och
omskriven när underlaget ändrats. Bredvid en faktarad som alltid stämmer:
möten, öppna uppgifter, försenade. Bilden sparas som `Läget.md` i
projektmappen och syns i Obsidian.

Projektet har också en **tidslogg**: ett ur att starta och stoppa med en rad
om vad du gör, och fält för att skriva in tid i efterhand («1:30», «1,5»
eller «90»). Går datorn i vila fryser uret vid insomningen; vid uppvaknandet
frågar en notis om tiden ska loggas eller räknas vidare — sovtid smyger
aldrig in i loggen. En smal rad längst ned i fönstret visar uret var du än
är, och loggen skrivs som `Tid.md` med summor per projekt.

## Att göra

Åtaganden hamnar på en tavla med tre spalter, utan att någon skriver in dem.
Mötets sammanfattning bidrar med sina, och nya mejl gås igenom när de hämtas.
Samma sak nämnd i både ett möte och ett mejl blir ett kort, inte två.

Korten dras mellan spalterna och öppnas med ett klick — det mesta är utplockat
av en modell, och en modell formulerar sig inte alltid som man själv skulle ha
gjort. Tavlan skrivs som `Att göra.md` i kundens valv så den syns i Obsidian.

Tavlan filtreras på person: menyn i hörnet listar dem som har öppna kort,
med antal, och «Utan person». Namnen är rensade — «Röst 1 (Andreas)» blir
Andreas, och ett förnamn som passar en enda kontakt blir den kontakten. Står
filtret på någon får ett nytt kort den personen.

Modellen räknar också ut **riktiga datum**: «före fredag» sagt en onsdag blir
fredagens datum, och det som passerats utan att bli klart rödmarkeras. En
uppgift kan läggas i macOS Påminnelser — envägs: tavlan är sanningen och
påminnelsen en spegel. **Min vecka** i sidopanelen samlar allt öppet hos alla
kunder, försenat först.

## Söka

⇧⌘F söker i allt material hos alla kunder samtidigt — transkript,
sammanfattningar, anteckningar, mejl och bilagor. Träffarna grupperas per kund,
och orden kapas automatiskt så att «leverans» hittar «leveranstiden».

⌘K öppnar paletten: skriv några bokstäver, hoppa till kund, projekt, möte
eller uppgift.

Chatten söker dessutom på **betydelse**: bge-m3 via Ollama bäddar in allt
lokalt, och en hybrid av BM25 och cosinus väger ihop listorna. Uppmätt tog
hybriden 11 av 12 facitfrågor mot 9 för vardera ensam — det ordsökning aldrig
kan ta är svenska frågor mot engelska dokument. Utan Ollama söker appen som
förut; inget lämnar datorn. Mätningen står i `docs/KUNSKAPSBANK.md`.

## Insikter under samtal

Medan ett möte spelas in lyssnar appen efter sådant deltagarna behöver slå upp,
och svarar ur kunskapsbanken. Svaren dyker upp bredvid live-transkriptet.

En lokal modell via Ollama gör bedömningen, så allt som sägs granskas på
datorn — bara de frågeställningar som faktiskt hittas går vidare. Uppmätt på
riktiga möten: qwen3:8b 12 av 12 rätt utan ett enda falskt larm. Se
`docs/INSIKTER.md`.

## Fråga om kunden

Varje kund och projekt har en chatt som svarar ur kundens eget material —
transkript, anteckningar, mejlämnen och kontakter. Svaren hänvisar till vad de
bygger på, och modellen säger ifrån i stället för att gissa när svaret inte
finns i underlaget.

Chatten är uppdelad i samtal. Ett nytt startas med pennan, och menyn i toppen
bläddrar tillbaka till tidigare — ett samtal handlar oftast om en sak, och att
rensa skulle kasta det man kanske vill tillbaka till.

Underlaget är transkript, anteckningar, mejl **med bilagornas innehåll**,
kontakter och tidigare samtal. Tidigare samtal viktas ner: de säger vad modellen
svarade, inte vad som faktiskt hände. Ett svar kan sparas som anteckning direkt ur
chatten.

**Kopplade mappar** — källkod, ritningar, offerter — indexeras däremot inte.
De genomsöks i stället av en agent när du ställer frågan, så att svaret bygger
på hur filerna ser ut just nu. Det tar en halv minut, så det svaret dyker upp
asynkront efter det snabba ur kunskapsbanken. Agenten är Claude Code, och det
den läser ur mappen går till Anthropic.

Sökningen är SQLite FTS5 med trunkerade sökord; svenskans böjningar gör att rak
sökning bara träffar i ett fall av fyra. Mätningen står i
`docs/KUNSKAPSBANK.md`.

Modellen väljs med ⌘, och kan köras hos OpenRouter, Anthropic, OpenAI, Azure
eller lokalt (Ollama, LM Studio, MLX). De lokala servrarna talar alla
OpenAI-formatet; inställningarna har förvalsknappar som fyller i rätt port.
MLX startas med `mlx_lm.server --model mlx-community/…` och är uppmätt genom
hela provsviten — svar, hänvisningar, strömning och ärligt nej. Nyckeln
sparas i macOS nyckelring.

**Vad som går ut på nätet.** Transkribering och röstanalys körs alltid
lokalt. Chattens modell används däremot på fyra ställen till: sammanfattningen
efter varje möte, uppgiftsletningen i nyhämtade mejl, lägesbilden i
projektöversikten och insikterna under samtal. Med en molnmodell vald går
transkript och mejltexter dit i bakgrunden. Det står i klartext under ⌘, och
går att stänga av — då skrivs sammanfattning och lägesbild först på
knapptryck, och mejlen gås inte igenom. Väljer du en lokal modell lämnar
ingenting datorn, med ett undantag: kopplade mappar genomsöks av Claude Code,
som skickar det den läser till Anthropic. Molnmotorerna för transkribering
skickar ljudet, och säger det i inställningarna.

## Anteckningar

Kunder och projekt har anteckningar — vanliga markdownfiler i en
`Anteckningar`-mapp, alltså samma filer som Obsidian öppnar. En anteckning kan
innehålla skärmdumpar: knappen öppnar macOS egen områdesväljare, bilden läggs i
en `bilder`-mapp bredvid och länkas med `![[bilder/…]]` så att Obsidian visar
den. Bilder går också att klistra in eller dra och släppa.

## Data

Allt hamnar under `~/Documents/Kunder`, en Obsidian-vault per kund:

```
~/Documents/Kunder/
  Acme AB/
    .obsidian/
    Acme AB.md
    Projekt/
      Nytt lager/
        Nytt lager.md
        Inspelningar/
        Dokument/
        Anteckningar/
    Samtal/
      2026-08-31 0930 Avstämning/
        jag.wav          16 kHz mono, ditt spår
        motpart.wav      16 kHz mono, motpartens spår
        möte.json        metadata, transkript och vem som talar
        Transkript.md    det Obsidian visar, med wikilänkar
    Kontakter/
      kontakter.json     kundens personer
      Anna Svensson.md   en not per person; uppgifterna i frontmatter,
                         brödtexten din egen och skrivs aldrig över
      röstprofiler.json  kända röster hos den här kunden
    Mail/
    Anteckningar/
```

Filsystemet är sanningen — ingen databas. En kund eller ett projekt som skapas
för hand i Finder eller Obsidian dyker upp i appen utan vidare: mappen
bevakas. Åt andra hållet byts namn på kund, projekt och möte med högerklick i
appen, och möten flyttas mellan projekt och kunder på samma sätt — då skrivs
allt som hänger på namnet om: inspelningar, uppgifter, noter, mejlstämpeln
och Obsidians valvlista. Borttagning går till papperskorgen, alltid efter en
fråga.

`Att göra.md`, `Transkript.md`, `Mail.md`, `Tid.md` och `Läget.md` skrivs av
appen och byggs om vid varje sparning. De bär `genererad: kundkoll` i
frontmatter, och ändringar gjorda i Obsidian skrivs över. Anteckningarna och
kontaktnoternas brödtext är däremot dina: ändras en anteckning utanför appen
medan den är öppen läggs den versionen bredvid i stället för att skrivas
över.

## Krav

- macOS 26
- whisper.cpp byggd, med `kb_whisper_ggml_small.bin` och
  `kb_whisper_ggml_medium.bin` i `models/`; som standard `~/Projekt/whisper.cpp`,
  en annan mapp pekas ut under ⌘,
- Pythonmiljö med torch och speechbrain för röstanalysen; som standard
  `~/Projekt/transcriber/venv`, en annan pekas ut under ⌘,
- Behörighet för **Mikrofon** och **Skärminspelning** (den senare krävs för
  datorljudet — ScreenCaptureKit fångar bara ljud här, ingen bild sparas)
- Frivilligt: **Kalender**, **Kontakter** och **Automatisering** för Mail.
  Appen fungerar utan, men då syns inga möten, kontakter eller mejl.

Fliken **Diagnos** under ⌘, säger vad som finns på datorn — whisper,
modeller, Pythonmiljön, pyannote, Ollama, Claude Code — och vilka
behörigheter som är givna.

## Se appen

```bash
./scripts/skarmbild.sh            # fångar fönstret
./scripts/skarmbild.sh --starta   # startar om appen först
```

`screencapture -l <fönster-id>` svarar "could not create image from window" när
appen ligger bakom — macOS släpper backing store för dolda fönster, och det ser
ut som ett behörighetsfel utan att vara det. Skriptet lyfter därför fram
fönstret först, gör flera försök, och faller tillbaka på hela skärmen.

## Bygga

```bash
./scripts/bygg-app.sh                                        # dist/Kundkoll.app
.build/arm64-apple-macosx/debug/Kundkoll --test              # 603 enhetstester
.build/arm64-apple-macosx/debug/Kundkoll --prov-ljud f.wav   # hela kedjan skarpt
.build/arm64-apple-macosx/debug/Kundkoll --prov-röst ljud.wav w.json facit.json
.build/arm64-apple-macosx/debug/Kundkoll --prov-import fil.mp4 fil.m4a
.build/arm64-apple-macosx/debug/Kundkoll --prov-chatt [leverantör] [modell]
.build/arm64-apple-macosx/debug/Kundkoll --prov-bilaga fil.pdf bild.png
.build/arm64-apple-macosx/debug/Kundkoll --prov-omröst <inspelningsmapp> [antal]
.build/arm64-apple-macosx/debug/Kundkoll --prov-kodagent <mapp> "<fråga>"
.build/arm64-apple-macosx/debug/Kundkoll --prov-insikter [modell …]
.build/arm64-apple-macosx/debug/Kundkoll --prov-datum   # relativa uttryck → riktiga datum
.build/arm64-apple-macosx/debug/Kundkoll --prov-transkribering f.wav [motor] [modell]
.build/arm64-apple-macosx/debug/Kundkoll --prov-läget <kund> <projekt>   # lägesbilden skarpt
.build/arm64-apple-macosx/debug/Kundkoll --prov-bilagehämtning <adress> [mapp]
.build/arm64-apple-macosx/debug/Kundkoll --transkribera-om <mapp> [sv|en|auto]
```

Xcode behövs inte — Command Line Tools räcker. Appen signeras med Developer ID
om certifikatet finns, vilket gör att macOS kommer ihåg beviljade behörigheter
mellan ombyggen. Eget certifikat anges med `KUNDKOLL_SIGNERING`; utan
certifikat signeras appen ad hoc och behörigheterna får ges om vid varje bygge.

## Licens

MIT, se `LICENSE`.
