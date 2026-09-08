# Produktvideo: Bjarbys kundkoll — manus

Byggs av `scripts/bygg-produktvideo.py` till `docs/produktvideo.mp4` (1920×1080,
H.264 + AAC) och affischen `docs/produktvideo-affisch.jpg`. Skriptet läser den här
filen, så det som står här är det som blir video:

- Raden `Röst-id:` anger ElevenLabs-rösten. Ljudet görs med ElevenLabs dialog-API
  genom elevenlabs-skillens `generate_dialogue.py`, ett stycke i taget, så att
  varje bild kan tajmas mot sitt stycke. Skillens egen cache gör att ett stycke
  som inte ändrats inte hämtas om.
- Varje numrerad punkt under «Bildmanus» är en bild. Rubrikraden är antingen
  sökvägen till en skärmbild i docs/bilder, eller Titelkort/Slutkort — då ritas
  texterna inom «…» på rubrikraden på kortet, rad för rad.
- Berättartexten är det som står inom «…» på raderna under rubriken. Radbrytningar
  spelar ingen roll. Rader utan «…» är kommentarer och läses inte upp. Citat inne
  i berättartexten skrivs med ”…”, aldrig med «…».
- Bilden ligger kvar så länge berättarstycket varar plus 0,8 s, med en mjuk
  zoom på 3 % och 0,5 s övertoning till nästa bild.

Berättaren är Anders själv, i jagform: en konsult som visar hur han jobbar, inte
en reklamröst. En genomgång på runt en kvart som hänger ihop från början till
slut: kunden och filerna, kontakter, mejl och kalender, mötet från inspelning
till sammanfattning, tavlan, projektet, chatten och de kopplade mapparna, och
sist vad som lämnar datorn. Ingen bakgrundsmusik, inga undertexter. Titelkort
först och sist på mörk botten (#101012) med appikonen.

Röst-id: B7OAdN7qiPFwZhhjfkxq

Rösten är «pod - Anders Bjarby ok», Anders egen klonade röst i kontot. Sista
stycket säger också att rösten är klonad. Byt röst genom att ändra raden ovan.

## Bildmanus

1. Titelkort (ikon + «Bjarbys kundkoll»)
   «Jag heter Anders Bjarby och är konsult. Jag har många kunder, varje kund har
   många möten, och det som sägs i mötena är det viktigaste jag har. Vad vi kom
   överens om, vad någon lovade, vad som lämnades öppet. Det var också det jag
   hade svårast att hålla reda på. Så jag byggde ett verktyg för det, och det
   är det jag ska visa nu. Det tar en kvart, för det är rätt mycket.»

2. docs/bilder/oversikt.png
   «Så här ser en kund ut. Fjällbo Energi är påhittad, men allt du ser är
   riktiga funktioner. Överst ligger de möten som kommer, hämtade ur kalendern.
   Sedan projekten, kontakterna och de senaste inspelningarna. Flikarna byter
   till tavlan, inspelningarna, anteckningarna och mejlen.»

3. docs/bilder/finder.png
   «Allt det här är vanliga filer. En kund är en mapp under Dokument, ett projekt
   är en mapp i den, ett möte är en mapp i projektet, med ljudet som wav och
   transkriptet som markdown. Ingen databas, inget konto, ingen molntjänst.
   Skapar jag en mapp i Finder dyker kunden upp i appen, och tar jag bort en
   kund i appen hamnar den i papperskorgen.»

4. docs/bilder/obsidian.png
   «Och varje kundmapp är samtidigt ett Obsidian-valv. Transkript, tavla,
   anteckningar, tidslogg och lägesbild skrivs som markdown med länkar mellan
   sig, så jag kan läsa och skriva i Obsidian när jag vill. Anteckningar jag
   skriver där syns i appen, och tvärtom.»

5. docs/bilder/kontakter.png
   «Kontakterna är nyckeln till det mesta. En person kan hämtas ur adressboken i
   macOS eller skrivas upp för hand, med roll, adresser och telefonnummer. Sätter
   jag namn på en röst i ett transkript blir personen kontakt automatiskt. Och
   röster som fått namn utan att finnas som kontakt listas här, så att de kan
   kopplas rätt eller glömmas.»

6. docs/bilder/kontakt.png
   «Har kontakten en e-postadress händer två saker. Alla mejl till och från den
   adressen hämtas in till kunden, och möten i kalendern där personen är
   deltagare räknas som kundens. Så snart Karin finns här med sin adress är
   hennes mejl och möten på plats, utan att jag gör något mer.»

7. docs/bilder/mail.png
   «Mejlen kommer ur Mail-appen. Appen söker på kontakternas adresser och
   kundens domän, och lägger dem i egen flik. Ett klick öppnar mejlet i Mail.
   Ingenting kopieras ur ditt mejlkonto till någon annan, det stannar på datorn.»

8. docs/bilder/mail-bilagor.png
   «Och bilagorna följer med. En offert i Word, ett avtal i pdf, en tabell i en
   skärmbild: innehållet läses av och blir sökbart. Det som lovas i ett mejl
   plockas dessutom ut till tavlan, som vi kommer till.»

9. docs/bilder/brief.png
   «Kalendern sköter sig själv. Ett möte räknas som kundens om någon deltagare
   finns bland kontakterna, har kundens domän eller om kundnamnet står i titeln.
   En kvart innan får jag en notis, och klicket öppnar den här briefen: förra
   mötet i samma serie, vad som lämnades obesvarat, öppna åtaganden och mejlen
   sedan sist. Den byggs ur det som redan finns, ingen modell, ingen väntan.
   Knappen längst ner startar inspelningen med rätt titel och deltagare.»

10. docs/bilder/inspelning.png
    «Så, ett möte. Jag trycker på spela in. Min mikrofon och datorns ljud
    spelas in på var sitt spår, så att jag och motparten hålls isär utan att
    någon behöver gissa vem som talar. Språket väljer jag per möte: svenska,
    engelska, eller låt appen avgöra själv när samtalet blandar språk. Sitter vi
    i samma rum tar jag bara mikrofonen, och rösterna delas upp efteråt.»

11. docs/bilder/live-transkript.png
    «Under mötet skrivs transkriptet medan vi pratar. Det görs av KB-Whisper,
    Kungliga bibliotekets svenska modell, som körs på datorn. Ljudet delas vid
    naturliga pauser, och fönster utan tal skickas aldrig, för då hittar
    Whisper på text ur tystnaden. Inspelningen har ett eget fönster som jag kan
    lägga bredvid Teams, och resten av appen fungerar under tiden.»

12. docs/bilder/live-insikt.png
    «Till höger sitter insikterna. Appen lyssnar efter sådant deltagarna undrar
    över och slår upp det i kundens material. Här frågade Karin vad
    Fabric-licensen kostade enligt offerten, och svaret kom ur bilagan. En
    lokal modell via Ollama avgör vad som är en fråga, så allt som sägs granskas
    på datorn. Bara det som är värt att slå upp går vidare. Och den säger
    ingenting oombedd. En assistent som pratar under möten blir avstängd.»

13. docs/bilder/import.png
    «Möten som redan är inspelade går också att lägga till. En mp4 från Teams,
    en m4a från telefonen, en wav från diktafonen. Släpp filen på kunden, så
    hamnar den i kön och bearbetas i bakgrunden.»

14. docs/bilder/mote.png
    «När mötet är slut går ett arkivpass i bakgrunden. Ljudet transkriberas om
    med en större modell, rösterna delas upp, och en sammanfattning skrivs: vad
    mötet handlade om, vad vi beslutade och vilka frågor som lämnades öppna.
    Ett fyrtio minuter långt möte är fyrahundra rader text. Det här är de tre
    saker jag behöver. En notis säger till när det är klart. Och knappen
    skriver ett uppföljningsmejl som utkast i Mail, med beslut och åtaganden.»

15. docs/bilder/mote-transkript.png
    «Transkriptet finns kvar, med en spelare. Ljudet rullar, båda spåren i takt,
    och raden som hörs markeras. Spelknappen på en rad hoppar dit. Transkriptet
    är Whispers ord, ljudet är facit.»

16. docs/bilder/vem-ar-vem.png
    «Sitter flera personer på andra sidan delas deras röster upp, och den jag
    träffat förut känns igen på röstavtrycket. För resten visas hur väl rösten
    liknar dem jag känner, i procent, med tröskeln utsatt. Ett klick sätter
    namnet, och nästa gång känns rösten igen. Osäkra röster lämnas hellre
    namnlösa än får fel namn.»

17. docs/bilder/mote-attgora.png
    «Åtagandena ur mötet är kort på tavlan, inte en kopia: bockar jag av ett här
    är det klart där också.»

18. docs/bilder/mote-efterbearbeta.png
    «Och blev något fel går hela passet att köra om, med en annan motor eller
    ett annat språk. Arkivpasset har fyra motorer: whisper.cpp, som är bäst på
    svenska, Whisper via Apples MLX, och två i molnet, som säger i klartext att
    ljudet lämnar datorn. Mötet behåller sitt id, så chattar och kort följer med.»

19. docs/bilder/tavla.png
    «Tavlan. Tre spalter, och ingen skriver in korten. Mötets sammanfattning
    bidrar med sina åtaganden, och nya mejl gås igenom när de hämtas. Samma sak
    nämnd i både ett möte och ett mejl blir ett kort, inte två. Varje kort har
    den som ska göra det, ett datum och en länk till där det sades.»

20. docs/bilder/uppgift.png
    «Datumen är riktiga datum. Säger någon ”före fredag” en onsdag blir det
    fredagens datum, ”i slutet av månaden” blir den sista. Det som passerats
    blir rött. Ett kort går att lägga i macOS Påminnelser, envägs: tavlan är
    sanningen och påminnelsen en spegel.»

21. docs/bilder/tavla-person.png
    «Tavlan filtreras på person. Menyn listar dem som har öppna kort, med antal,
    och står filtret på någon får ett nytt kort den personen.»

22. docs/bilder/min-vecka.png
    «Min vecka samlar det öppna hos alla kunder på en gång. Försenat först,
    sedan den här veckan, sedan resten, med samma personfilter.»

23. docs/bilder/projekt.png
    «Ett projekt börjar med läget just nu: en lägesbild skriven ur
    mötessammanfattningar, tavla, mejl och anteckningar, med rubrikerna
    närmast, väntar på och risker. Den skrivs om när underlaget ändrats, och
    sparas som markdown i projektmappen. Bredvid en faktarad som alltid stämmer:
    möten, öppna uppgifter, försenade. Kommande möten kopplas hit, så att
    inspelningen hamnar rätt från början.»

24. docs/bilder/projekt-mappar.png
    «Och ett projekt kan kopplas till mappar utanför kundmappen. Källkod,
    ritningar, offerter. De flyttas inte och indexeras inte. De genomsöks av en
    agent när jag frågar, så att svaret bygger på hur filerna ser ut just nu.»

25. docs/bilder/tid.png
    «Projektet har också en tidslogg. Ett ur att starta och stoppa, eller tid
    att skriva in i efterhand. Går datorn i vila fryser uret, och när den
    vaknar frågar en notis om tiden ska räknas. Sovtid smyger aldrig in.
    Loggen skrivs som markdown med summor per projekt.»

26. docs/bilder/anteckning.png
    «Anteckningar är markdownfiler i kundens eller projektets mapp. Samma filer
    som Obsidian öppnar. En anteckning kan ta skärmdumpar med macOS egen
    områdesväljare, och bilder går att klistra in eller dra hit.»

27. docs/bilder/chatt.png
    «Så till chatten. Varje kund och projekt har en, och den svarar ur kundens
    eget material: transkript, sammanfattningar, anteckningar, mejl med
    bilagornas innehåll, kontakter. Här frågar jag vad vi lovade Karin senast,
    och svaret pekar på mötet och på mejlet det bygger på. Finns svaret inte i
    materialet säger den det, i stället för att hitta på. Ett svar kan sparas
    som anteckning direkt.»

28. docs/bilder/chatt-mapp.png
    «I projektet Dataplattform ligger en kodmapp kopplad. Frågar jag hur
    veckorapporten räknas fram kommer först ett snabbt svar ur kunskapsbanken,
    och en halv minut senare ett till, ur mappen, från en agent som läst koden
    som den ser ut i dag. Agenten är Claude Code, och det den läser går till
    Anthropic. Det står i klartext, och mappen kopplar jag bara om jag vill.»

29. docs/bilder/sok.png
    «Sökningen går över allt material hos alla kunder samtidigt, grupperat per
    kund. Orden kapas automatiskt, så ”leverans” hittar ”leveranstiden”, och
    chatten söker dessutom på betydelse, med inbäddningar som görs lokalt. En
    svensk fråga hittar ett engelskt avtal.»

30. docs/bilder/palett.png
    «Och paletten: några bokstäver och retur, så är jag hos en kund, ett projekt,
    ett möte eller en uppgift.»

31. docs/bilder/installningar-modell.png
    «Så, vad som lämnar datorn. Ljudet, transkriberingen och röstanalysen
    lämnar den aldrig. Språkmodellen för chatten väljer jag själv: OpenRouter,
    Anthropic, OpenAI, Azure, eller en lokal modell via Ollama, LM Studio eller
    MLX. Med en lokal modell lämnar ingenting datorn. Samma modell används för
    sammanfattningen, uppgiftsletningen i mejl, lägesbilden och insikterna,
    och de automatiska anropen går att stänga av.»

32. docs/bilder/installningar-transkribering.png
    «Här pekas whisper.cpp och Pythonmiljön ut, och arkivmotorn väljs.»

33. docs/bilder/installningar-roster.png
    «Under Röster och insikter väljs modellen som lyssnar under mötena, och
    om röster ska kännas igen mellan kunder eller bara hos den kund där de
    hördes.»

34. docs/bilder/installningar.png
    «Och Diagnos säger vad som finns på datorn: whisper, modellerna, Python,
    pyannote, Ollama, Claude Code, och vilka behörigheter som är givna. Saknas
    något står det hur det ordnas.»

35. docs/bilder/om.png
    «Bjarbys kundkoll är gratis och öppen källkod. Varje val i den är uppmätt
    på riktiga möten: vilken modell som hör svenska bäst, hur röster känns igen,
    hur Whispers påhitt hålls borta. Mätningarna ligger i källkoden.»

36. Slutkort (ikon, «Bjarbys kundkoll», «Gratis och öppen källkod», «anders.bjarby.com»)
    «Du hittar den på anders punkt bjarby punkt com, och vill du stödja arbetet
    finns Patreon. Rösten du har hört är min egen, klonad med ElevenLabs.
    Tack för att du tittade.»
