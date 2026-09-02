# Kunskapsbank och chatt

Varje kund och varje projekt har en chatt som svarar ur kundens eget material:
transkript, anteckningar, mejlämnen och kontakter. Ingenting annat.

## Varför sökning och inte vektorer

`NLEmbedding.sentenceEmbedding(for: "sv")` returnerar **nil** — Apple har inga
svenska vektorer. Molnembeddingar skulle innebära att allt kundmaterial skickas
ut för att indexeras, vilket är precis vad hybridvalet undviker.

Kvar står SQLite FTS5 med BM25, som räcker långt när sökorden behandlas rätt.

## Kalibrering: svenskan böjer och sätter samman

FTS5 matchar ord exakt. Det duger inte för svenska. Uppmätt på ett litet
material med rimliga frågor:

| Fråga | rak sökning | trunkerad |
|---|---|---|
| leveranstid | 0 | 1 |
| leveranstiden | 1 | 1 |
| batteri | 0 | 2 |
| battericell | 0 | 1 |
| certifiering | 0 | 1 |
| ritning | 0 | 1 |
| lagerbyggnad | 0 | 1 |
| pallställ | 1 | 1 |
| volymrabatt | 0 | 1 |
| **totalt** | **2 av 9** | **9 av 9** |

Därför kapas varje sökord med två tecken (minst fyra kvar) och söks som prefix,
med `OR` mellan orden. Stoppord sållas bort så att de inte späder ut BM25.

Tokenizern körs med `remove_diacritics 0`: å ä ö är egna bokstäver i svenskan,
inte a och o med prickar — "mata" och "mäta" är olika ord. Skiftläge normaliseras
ändå, så "ängsö" hittar "ÄNGSÖ".

## Vad som indexeras

| Typ | Varifrån |
|---|---|
| transkript | inspelningar, i stycken om ~900 tecken med talare och tid |
| anteckning | kundens och projektens anteckningar |
| mejl | ämnesrader ur Mail |
| bilaga | innehållet i mejlbilagor — PDF via PDFKit, bilder via Vision, docx/pptx/xlsx ur deras XML |
| chatt | tidigare frågor och svar, som ett stycke per par |
| kontakt | namn, roll, adresser |

Bilagornas innehåll är ofta det som betyder något: en offert i en PDF eller en
tabell i en skärmbild står inte i ämnesraden. Uppmätt på riktiga mejlbilagor gav
en skärmbild 69 rader text på 0,2 sekunder. Kalenderfiler, signaturfiler och
inbäddade `image001`-bilder sorteras bort — de kommer i mängd utan att tillföra.

## Kopplade mappar indexeras inte — de genomsöks

En kopplad kodmapp hör inte hemma i indexet. Uppmätt på det här projektets egen
mapp: 54 filer blir **481 stycken**, mot 70 för allt material om en riktig kund
tillsammans. Kodträffar skulle dränka varje sökning. Kod ändras dessutom
dagligen, så ett index är gammalt nästan direkt — och en kodfråga besvaras
sällan av 900 tecken ur en fil, den kräver att man följer spår mellan filer.

I stället får en agent söka i mappen när frågan ställs. Claude Code kan just
det och finns redan installerad; den körs i mappen med enbart läsande verktyg
(`Read`, `Grep`, `Glob`).

Det tar tid — uppmätt 23 och 34 sekunder på riktiga frågor — så svaret kommer
**asynkront**. Frågan besvaras först ur kunskapsbanken på ett par sekunder, och
mappsvaret läggs till som ett eget meddelande när det är klart, märkt med
vilken mapp det kommer ur. Att hålla tillbaka det snabba svaret för att vänta
in det långsamma vore fel väg.

Svaren håller den kvalitet uppgiften kräver: på frågan hur whispers påhitt
hanteras svarade agenten med de tre lagren, rätt filer och radnummer, och vilka
mätvärden som ligger bakom.

## Index

En SQLite-fil per kund i `<kund>/.kundkoll/index.db`. Indexet är **härlett** —
går det sönder byggs det om från filerna, som är sanningen.

Bara det som ändrats sedan sist indexeras om, jämfört på filens ändringstid.

Transkript delas i stycken om ~900 tecken med talare och tidsstämpel kvar i
texten, så att ett svar kan säga vem som sa vad och när. Anteckningar delas vid
styckegränser.

## Modellen

Transkribering och röstanalys körs alltid lokalt. Chattens modell används
också för sammanfattningen efter mötet, uppgiftsletningen i mejl, lägesbilden
och insikterna under samtal — med en molnmodell vald går det materialet dit i
bakgrunden. Det står under ⌘, och går att stänga av, se README.

Fem leverantörer stöds:

| | Format | Nyckel | Standardmodell |
|---|---|---|---|
| OpenRouter | OpenAI | `OPENROUTER_API_KEY` | `anthropic/claude-sonnet-5` |
| Anthropic | Anthropic Messages | `ANTHROPIC_API_KEY` | `claude-sonnet-5` |
| OpenAI | OpenAI | `OPENAI_API_KEY` | `gpt-5` |
| Azure OpenAI | OpenAI | `AZURE_OPENAI_API_KEY` | ur adressen |
| Lokal | OpenAI | ingen | `llama3.1:8b` |

Nycklar bor i macOS nyckelring, inte i kundmappen — den ligger i Dokument och
kan hamna i iCloud eller en säkerhetskopia. En miljövariabel går före
nyckelringen, men bara när appen startats från en terminal; en app startad från
Finder ser inte skalets variabler.

Två dialekter: Anthropic har systemtexten som eget fält och svarar med
`content[]`-block, övriga lägger den som ett `system`-meddelande och svarar med
`choices[].message.content`. Azure tar modellen ur adressen, inte ur kroppen.

Fallgrop: Anthropic-modeller via OpenRouter kan lägga hela svarsutrymmet på att
tänka och returnera tomt innehåll. Därför skickas `reasoning: {enabled: false}`
just för OpenRouter.

En lokal modell är vägen att gå när materialet inte får lämna datorn alls.
Ollama och LM Studio talar båda OpenAI-formatet.

## Att inte hitta på

Systemtexten säger att modellen bara får bygga på underlaget och ska säga ifrån
när svaret inte finns där. Varje påstående ska hänvisa till underlagets nummer,
och appen visar bara de källor svaret faktiskt hänvisade till.

Provat skarpt (`--prov-chatt openrouter`) med en fråga underlaget inte svarar på:

```
Fråga: Vem är kundens verkställande direktör och vilket är deras
       organisationsnummer?
Svar:  Jag hittar inget svar på det i underlaget. Uppgifter om kundens VD
       eller organisationsnummer finns inte i det material jag har
       tillgång till [1][2].
```

Provet fäller om modellen svarar med ett påhittat organisationsnummer.

## Köra provet

```bash
Kundkoll --prov-chatt                    # den valda leverantören
Kundkoll --prov-chatt anthropic          # en annan
Kundkoll --prov-chatt lokal llama3.1:8b  # mot en modell på datorn
```

## Betydelsesökning — mätningen bakom hybriden

Uppmätt 2026-09-01 på det riktiga kundindexet (106 stycken: transkript,
bilagor, mejl, kontakter), tolv facitfrågor där rätt källa var känd. bge-m3
via Ollama, helt lokalt.

| metod                      | rätt källa i topp 5 |
|----------------------------|---------------------|
| trunkerad BM25 (befintlig) | 9 av 12             |
| enbart inbäddningar        | 9 av 12             |
| **hybrid (RRF)**           | **11 av 12**        |

De missar olika saker. BM25 kan aldrig ta svenska frågor mot engelska
dokument — «vilket bolag sköter tullhanteringen» mot ett Statement of Work
på engelska. Inbäddningarna ensamma tappar i stället rena nyckelord
(«faktura belopp»). Sammanvägningen är RRF, 1/(60+rang) summerat över båda
listorna: den jämför ordningar, aldrig BM25-tal mot cosinus.

Därför: **hybrid när Ollama och bge-m3 finns, ren BM25 annars.** Vektorerna
ligger i samma index.db (tabellen `vektorer`, Float32-blobbar), byggs i
bakgrunden efter indexeringen och glöms tillsammans med sin källa. Inget
lämnar datorn.

## ⚠️ Bilagor glömdes aldrig vid omindexering

Indexeringscykeln nycklas per källa, men bilagorna lades in under sina egna
källvägar medan glömningen bara träffade mail.json. Varje mailhämtning la
därför på ett varv till: uppmätt låg en faktura **28 gånger** i indexet —
959 rader varav 132 unika — och kopiorna fyllde topplistan och skev
BM25-statistiken. Numera glöms varje bilagas källa innan den läggs in igen,
och provsviten Omindexering indexerar om tre gånger och kräver samma antal.

## Källor glöms via en sidotabell

`källa` står UNINDEXED i FTS-tabellen, så `DELETE … WHERE källa = ?` var en
genomsökning av hela indexet för varje ändrad fil. Nu håller tabellen
`dokumentkällor` rowid → källa med index, och ett äldre index fylls på en
gång när det öppnas. Källor vars fil inte finns längre — ett möte som döpts
om eller flyttats — glöms vid nästa indexering. Indexeringen och den globala
sökningen är inte längre bundna till huvudaktören: de körs i bakgrunden, och
arkivets läsningar är `nonisolated` med en cache av avkodade möte.json på
ändringstid och storlek. Inbäddningarna hålls i minnet mellan frågorna så
länge antalet i tabellen är detsamma.
