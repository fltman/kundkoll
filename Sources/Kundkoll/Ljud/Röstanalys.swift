import Foundation

/// Räknar ut vem som säger vad på motpartsspåret.
///
/// Spårseparationen ger redan "jag mot motparten". Det här steget delar upp
/// motparten när flera personer sitter i samma möte, och sätter namn på dem
/// genom att jämföra mot röstprofiler sparade hos kunden.
///
/// Uppdelningen görs av **pyannote**, som är tränad för just det och hittar
/// antalet talare själv. Egen klustring av röstavtryck provades först och höll
/// inte: på ett riktigt tvåpersonerssamtal gav den 58 röster med en tröskel och
/// slog ihop båda personerna med en annan. Den vägen finns kvar som reserv om
/// pyannote inte går att köra.
///
/// **Röstavtrycken** (ECAPA-TDNN) behövs fortfarande, men till en annan sak än
/// uppdelningen: att känna igen samma person mellan olika samtal.
///
/// Båda körs i en Pythonprocess (`scripts/rostanalys.py`) — det finns ingen
/// motsvarighet inbyggd i macOS.
actor Röstanalys {

    struct Sökvägar: Codable, Hashable {
        /// Pythonmiljö med torch och speechbrain. Delas med transcriber-projektet.
        var python: URL
        var skript: URL

        static var standard: Sökvägar {
            let hem = FileManager.default.homeDirectoryForCurrentUser
            // I appaketet ligger skriptet under Resources. Körd som
            // kommandorad — proven, --transkribera-om — finns inget paket,
            // och då gäller källträdet. Utan den reserven delades rösterna
            // tyst inte alls i headless-körningar.
            let ipaketet = URL(fileURLWithPath: Bundle.main.bundlePath)
                .appending(path: "Contents/Resources/rostanalys.py")
            let ikällan = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "scripts/rostanalys.py")
            return Sökvägar(
                python: hem.appending(path: "Projekt/transcriber/venv/bin/python"),
                skript: FileManager.default.fileExists(atPath: ipaketet.path)
                    ? ipaketet : ikällan)
        }

        var brister: [String] {
            var f: [String] = []
            let fm = FileManager.default
            if !fm.isExecutableFile(atPath: python.path) {
                f.append("hittar ingen Pythonmiljö med speechbrain i \(python.path)")
            }
            if !fm.fileExists(atPath: skript.path) {
                f.append("rostanalys.py saknas i appen")
            }
            return f
        }

        /// pyannote-modellen ligger i huggingface-cachen. Saknas den faller
        /// uppdelningen tillbaka på klustring, som är märkbart sämre — men
        /// röstavtrycken fungerar ändå, så det är en varning och inte ett fel.
        var harDiarisering: Bool {
            FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: ".cache/huggingface/hub/models--pyannote--speaker-diarization-3.1")
                    .path)
        }
    }

    private let sökvägar: Sökvägar
    init(sökvägar: Sökvägar = .standard) { self.sökvägar = sökvägar }

    // MARK: - Turer

    /// En sammanhängande talbit att mäta röst på.
    struct Tur: Hashable {
        var start: Double
        var slut: Double
        var text: String
        var längd: Double { slut - start }
    }

    /// Slår ihop yttranden till turer. En paus bryter turen, eftersom en
    /// talarväxling nästan alltid sker vid en paus. Taket finns för att en
    /// lång tur annars kan hinna blanda in nästa person.
    static func turer(av yttranden: [Yttrande],
                      pausbrytning: Double = 0.7,
                      tak: Double = 12) -> [Tur] {
        var ut: [Tur] = []
        for y in yttranden.sorted(by: { $0.start < $1.start }) {
            if var sista = ut.last,
               y.start - sista.slut <= pausbrytning,
               y.slut - sista.start <= tak {
                sista.slut = y.slut
                sista.text += " " + y.text
                ut[ut.count - 1] = sista
            } else {
                ut.append(Tur(start: y.start, slut: y.slut, text: y.text))
            }
        }
        return ut.filter { $0.längd >= Tröskel.minstaTurLängd }
    }

    // MARK: - Avtryck

    /// Vad Pythonsidan kan svara.
    private struct Svar: Decodable {
        struct A: Decodable { let start: Double; let slut: Double; let vektor: [Float] }
        struct S: Decodable { let start: Double; let slut: Double; let talare: String }
        let avtryck: [A]?
        let segment: [S]?
        let fel: String?
    }

    /// Kör Pythonsidan med en förfrågan och tolkar svaret.
    private func kör<F: Encodable>(_ förfrågan: F) async throws -> Svar {
        if let brist = sökvägar.brister.first { throw Fel.saknas(brist) }
        let indata = try JSONEncoder().encode(förfrågan)

        let p = Process()
        p.executableURL = sökvägar.python
        p.arguments = [sökvägar.skript.path]
        // Felutskriften följer med: en trasig venv eller en saknad modell
        // förklarade sig tidigare i /dev/null.
        let utfall = try await Underprocess.kör(p, indata: indata, tidsgräns: 30 * 60)

        guard let svar = try? JSONDecoder().decode(Svar.self, from: utfall.ut) else {
            let orsak = utfall.felsvans()
            throw orsak.isEmpty ? Fel.otolkbartSvar : Fel.frånPython(orsak)
        }
        if let fel = svar.fel { throw Fel.frånPython(fel) }
        return svar
    }

    /// Hämtar ett röstavtryck per tur.
    func avtryck(fil: URL, turer: [Tur]) async throws -> [(Tur, Avtryck)] {
        guard !turer.isEmpty else { return [] }

        struct Förfrågan: Encodable {
            struct T: Encodable { let start: Double; let slut: Double }
            let läge = "avtryck"
            let wav: String
            let turer: [T]
        }
        let svar: Svar = try await kör(
            Förfrågan(wav: fil.path, turer: turer.map { .init(start: $0.start, slut: $0.slut) }))

        // Para ihop svaret med turerna igen; skriptet hoppar över för korta bitar.
        var ihop: [(Tur, Avtryck)] = []
        for a in svar.avtryck ?? [] {
            guard let tur = turer.first(where: { abs($0.start - a.start) < 0.01 }) else { continue }
            ihop.append((tur, Avtryck(vektor: a.vektor, sekunder: tur.längd)))
        }
        return ihop
    }

    // MARK: - Diarisering

    /// Ett stycke ljud som pyannote tillskrivit en talare.
    struct Talarsegment: Hashable {
        var start: Double
        var slut: Double
        var talare: String
    }

    /// Delar upp ljudet i talare.
    /// - Parameter antal: sätts när antalet är känt, till exempel ur kalendern.
    func diarisera(fil: URL, antal: Int? = nil) async throws -> [Talarsegment] {
        struct Förfrågan: Encodable {
            let läge = "diarisera"
            let wav: String
            let antal: Int?
        }
        let svar: Svar = try await kör(Förfrågan(wav: fil.path, antal: antal))
        guard let segment = svar.segment else { throw Fel.otolkbartSvar }
        return segment.map { Talarsegment(start: $0.start, slut: $0.slut, talare: $0.talare) }
    }

    /// Lägger varje tur hos den talare den överlappar mest.
    ///
    /// pyannotes segment och whispers turer följer inte varandra: whisper
    /// delar vid pauser, pyannote vid talarbyten. Överlappet avgör.
    static func gruppera(turer: [Tur], avtryck: [Tur: Avtryck],
                         enligt segment: [Talarsegment]) -> [Röstgrupp] {
        guard !segment.isEmpty else { return [] }

        var perTalare: [String: Röstgrupp] = [:]
        for tur in turer {
            var bäst = 0.0
            var bästTalare: String?
            for s in segment {
                let överlapp = min(tur.slut, s.slut) - max(tur.start, s.start)
                guard överlapp > 0 else { continue }
                // Summera per talare: en lång tur kan spänna över flera segment
                // från samma person.
                let samlat = segment
                    .filter { $0.talare == s.talare }
                    .reduce(0.0) { $0 + max(0, min(tur.slut, $1.slut) - max(tur.start, $1.start)) }
                if samlat > bäst { bäst = samlat; bästTalare = s.talare }
            }
            guard let talare = bästTalare else { continue }
            perTalare[talare, default: Röstgrupp(turer: [], avtryck: [])].turer.append(tur)
            if let a = avtryck[tur] {
                perTalare[talare]!.avtryck.append(a)
            }
        }

        return perTalare.values
            .map { g in
                var ut = g
                ut.turer.sort { $0.start < $1.start }
                return ut
            }
            .sorted { $0.längd > $1.längd }
    }

    // MARK: - Klustring

    /// En röst i ett samtal: en eller flera turer som hör ihop.
    struct Röstgrupp {
        var turer: [Tur]
        var avtryck: [Avtryck]
        /// Sätts när gruppen matchar en sparad profil.
        var namn: String?
        var säkerhet: Double = 0

        var längd: Double { turer.reduce(0) { $0 + $1.längd } }
        /// Det längsta avtrycket, alltså det mest tillförlitliga.
        var bästa: Avtryck? { avtryck.max { $0.sekunder < $1.sekunder } }
        var exempel: String { turer.max { $0.längd < $1.längd }?.text ?? "" }
    }

    /// Delar turerna i röster.
    ///
    /// Klustring rakt över alla turer fungerar inte i ett riktigt samtal.
    /// Uppmätt på ett 39 minuter långt tvåpersonerssamtal gav det 58 röster:
    /// medianturen är 3,3 sekunder, och ett avtryck från så kort ljud är för
    /// brusigt för att nå tröskeln mot någon annan — varje kort inpass blev en
    /// egen röst.
    ///
    /// Därför byggs först kärnor av de långa turerna, där avtrycken går att
    /// lita på. Sedan tilldelas varje kort tur den kärna den liknar mest.
    /// Jämförelsen sker mot kärnans medelavtryck, som bygger på mycket ljud,
    /// så bara den ena sidan av jämförelsen är brusig.
    /// - Parameter väntade: hur många som talar, om det är känt. Kalendern vet
    ///   ofta det: startas inspelningen från ett möte finns deltagarlistan.
    ///   Är antalet känt väljs det läge som ligger närmast, i stället för att
    ///   gissa fram det ur likheterna.
    static func gruppera(_ par: [(Tur, Avtryck)], väntade: Int? = nil) -> [Röstgrupp] {
        guard !par.isEmpty else { return [] }

        let (kärnturer, korta) = delaEfterLängd(par)

        // För få långa turer att bygga på — klustra allt som det är.
        guard kärnturer.count >= 2 else {
            return efterbehandla(klustra(par, väntade: väntade))
        }

        var grupper = efterbehandla(klustra(kärnturer, väntade: väntade))
        for kort in korta { tilldela(kort, till: &grupper) }

        // Ett angivet antal är ett besked, inte en gissning: den som var med i
        // samtalet vet hur många som talade. En kort tur som inte liknade
        // någon fick bli egen ovan, och läggs nu hos den den ändå liknar mest.
        if let väntade, grupper.count > väntade {
            grupper = tvingaNed(grupper, till: väntade)
        }

        for i in grupper.indices {
            grupper[i].turer.sort { $0.start < $1.start }
        }
        return grupper.sorted { $0.längd > $1.längd }
    }

    /// Slår ihop de minsta grupperna med sina närmaste tills antalet stämmer.
    private static func tvingaNed(_ ingående: [Röstgrupp], till antal: Int) -> [Röstgrupp] {
        var grupper = ingående.sorted { $0.längd > $1.längd }
        while grupper.count > antal, grupper.count > 1 {
            // Den minsta gruppen är den osäkraste och flyttas först.
            let minsta = grupper.removeLast()
            var bästa = -Double.infinity
            var index = 0
            let c = centroid(minsta)
            for (i, g) in grupper.enumerated() {
                let a = centroid(g)
                guard a.count == c.count, !a.isEmpty else { continue }
                var l: Float = 0
                for k in 0..<a.count { l += a[k] * c[k] }
                if Double(l) > bästa { bästa = Double(l); index = i }
            }
            grupper[index].turer += minsta.turer
            grupper[index].avtryck += minsta.avtryck
            grupper.sort { $0.längd > $1.längd }
        }
        return grupper
    }

    /// Vilka turer är långa nog att bilda kärna?
    ///
    /// Gränsen är inte fast: i ett samtal med korta repliker finns kanske
    /// inga turer alls över åtta sekunder, och då vore en fast gräns
    /// detsamma som att inte gruppera. I stället tas de längsta turerna
    /// tills de täcker en dryg tredjedel av taltiden.
    static func delaEfterLängd(_ par: [(Tur, Avtryck)])
        -> (kärnor: [(Tur, Avtryck)], korta: [(Tur, Avtryck)]) {
        let total = par.reduce(0.0) { $0 + $1.0.längd }
        let sorterade = par.sorted { $0.0.längd > $1.0.längd }
        var kärnor: [(Tur, Avtryck)] = []
        var korta: [(Tur, Avtryck)] = []
        var samlat = 0.0
        for p in sorterade {
            let längeNog = p.0.längd >= Tröskel.minstaKärnlängd
            let räckerRedan = samlat >= total * Tröskel.kärnandel
            if längeNog && !räckerRedan {
                kärnor.append(p)
                samlat += p.0.längd
            } else {
                korta.append(p)
            }
        }
        return (kärnor, korta)
    }

    /// Lägger en kort tur i den röst den liknar mest.
    ///
    /// Alla turer på spåret kommer från någon som faktiskt talar, så den ska
    /// hamna någonstans. Bara om den inte liknar någon av de kända rösterna
    /// alls blir den en egen — då är det troligen en person till.
    private static func tilldela(_ kort: (Tur, Avtryck), till grupper: inout [Röstgrupp]) {
        var bästa = -1.0
        var bästaIndex = -1
        for (i, g) in grupper.enumerated() {
            let c = centroid(g)
            guard c.count == kort.1.vektor.count, !c.isEmpty else { continue }
            var l: Float = 0
            for k in 0..<c.count { l += c[k] * kort.1.vektor[k] }
            if Double(l) > bästa { bästa = Double(l); bästaIndex = i }
        }
        if bästaIndex >= 0, bästa >= Tröskel.tilldela {
            grupper[bästaIndex].turer.append(kort.0)
            grupper[bästaIndex].avtryck.append(kort.1)
        } else {
            grupper.append(Röstgrupp(turer: [kort.0], avtryck: [kort.1]))
        }
    }

    /// Slår ihop turer som låter likadant, nerifrån och upp — och stannar där
    /// likheten faller mest.
    ///
    /// En fast tröskel fungerar inte. Hur lika två avtryck av samma person är
    /// beror på mikrofon, rum och hur personen låter den dagen: uppmätt ger
    /// samma tröskel 19 röster i ett tvåpersonerssamtal och slår ihop fem
    /// talare till två i ett annat material.
    ///
    /// I stället klustras hela vägen ner till en grupp medan varje
    /// sammanslagnings likhet sparas. Likheten faller monotont, och det
    /// största fallet är övergången från att slå ihop samma person till att
    /// slå ihop olika. Där klipps det. Måttet blir relativt inspelningen i
    /// stället för en konstant som passar ett material och inte ett annat.
    private static func klustra(_ par: [(Tur, Avtryck)], väntade: Int? = nil) -> [Röstgrupp] {
        var grupper = par.map { Röstgrupp(turer: [$0.0], avtryck: [$0.1]) }
        guard grupper.count > 1 else { return grupper }

        // Klustra hela vägen och spara varje läge.
        var lägen: [(antal: Int, likhet: Double, grupper: [Röstgrupp])] = []
        while grupper.count > 1 {
            var bästI = 0, bästJ = 0, bästLikhet = -Double.infinity
            for i in 0..<grupper.count {
                for j in (i + 1)..<grupper.count {
                    let l = medellikhet(grupper[i], grupper[j])
                    if l > bästLikhet { bästLikhet = l; bästI = i; bästJ = j }
                }
            }
            lägen.append((grupper.count, bästLikhet, grupper))
            grupper[bästI].turer += grupper[bästJ].turer
            grupper[bästI].avtryck += grupper[bästJ].avtryck
            grupper.remove(at: bästJ)
        }
        lägen.append((1, -Double.infinity, grupper))

        let likheter = lägen.map(\.likhet)
        let vald = väntade.flatMap { n in
            lägen.firstIndex { $0.antal <= n }
        } ?? klippställe(likheter)
        if ProcessInfo.processInfo.environment["KUNDKOLL_VISA_KEDJA"] != nil {
            print("sammanslagningskedja (antal grupper: likhet, fall):")
            for (i, l) in lägen.enumerated() where i < likheter.count - 1 {
                let fall = likheter[i] - likheter[i + 1]
                let märke = i == vald ? "  <- vald" : ""
                print(String(format: "  %3d: %.3f  fall %+.3f%@", l.antal, l.likhet, fall, märke))
            }
        }
        return lägen[vald].grupper
    }

    /// Var i sammanslagningskedjan faller likheten mest?
    ///
    /// `likheter[i]` är likheten vid sammanslagningen som tar antalet grupper
    /// från `n - i` till `n - i - 1`. Returnerar index på det läge som ska
    /// behållas.
    static func klippställe(_ likheter: [Double]) -> Int {
        // Ett samtal med en enda talare finns, men är ovanligt nog att inte
        // vara värt att gissa på: minst två grupper övervägs alltid.
        guard likheter.count >= 2 else { return 0 }

        var störstaFall = -Double.infinity
        var klipp = 0
        // Hoppa över de sista stegen: att gå från två grupper till en faller
        // alltid mycket, och skulle annars alltid vinna.
        let sista = max(1, likheter.count - 1)
        for i in 0..<sista {
            let nästa = likheter[i + 1]
            guard nästa.isFinite else { continue }
            let fall = likheter[i] - nästa
            // Vid lika stort fall vinner det som ger färre grupper: hellre
            // slå ihop en gång för mycket än lämna en person delad i två.
            if fall >= störstaFall {
                störstaFall = fall
                klipp = i + 1
            }
        }
        return klipp
    }

    /// Andra rundan: nu har grupperna mycket mer ljud än de enskilda turerna
    /// hade, och ett medelavtryck över hela gruppen är betydligt mindre
    /// brusigt än enstaka mätningar.
    private static func efterbehandla(_ grupper: [Röstgrupp]) -> [Röstgrupp] {
        var ut = slåIhopPåCentroid(grupper)
        for i in ut.indices { ut[i].turer.sort { $0.start < $1.start } }
        return ut.sorted { $0.längd > $1.längd }
    }

    /// Gruppens medelavtryck, normerat. Bygger på allt gruppens ljud och är
    /// därför mycket mindre brusigt än en enskild mätning.
    static func centroid(_ g: Röstgrupp) -> [Float] {
        guard let första = g.avtryck.first else { return [] }
        var summa = [Float](repeating: 0, count: första.vektor.count)
        for a in g.avtryck {
            for i in 0..<min(summa.count, a.vektor.count) { summa[i] += a.vektor[i] }
        }
        var norm: Float = 0
        for v in summa { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 0 else { return summa }
        return summa.map { $0 / norm }
    }

    /// Slår ihop grupper vars medelavtryck är tillräckligt lika.
    private static func slåIhopPåCentroid(_ ingående: [Röstgrupp]) -> [Röstgrupp] {
        var grupper = ingående
        while grupper.count > 1 {
            var bästI = 0, bästJ = 0, bästMarginal = -Double.infinity, slåIhop = false
            for i in 0..<grupper.count {
                for j in (i + 1)..<grupper.count {
                    let a = centroid(grupper[i]), b = centroid(grupper[j])
                    guard a.count == b.count, !a.isEmpty else { continue }
                    var l: Float = 0
                    for k in 0..<a.count { l += a[k] * b[k] }
                    // Tröskeln följer den mindre gruppens totala taltid: det är
                    // den som avgör hur säker jämförelsen kan bli.
                    let minst = min(grupper[i].längd, grupper[j].längd)
                    let marginal = Double(l) - Tröskel.sammaGrupp(sekunder: minst)
                    if marginal > bästMarginal {
                        bästMarginal = marginal; bästI = i; bästJ = j; slåIhop = marginal >= 0
                    }
                }
            }
            guard slåIhop else { break }
            grupper[bästI].turer += grupper[bästJ].turer
            grupper[bästI].avtryck += grupper[bästJ].avtryck
            grupper.remove(at: bästJ)
        }
        return grupper
    }

    private static func medellikhet(_ a: Röstgrupp, _ b: Röstgrupp) -> Double {
        var summa = 0.0, antal = 0
        for x in a.avtryck { for y in b.avtryck { summa += x.likhet(y); antal += 1 } }
        return antal == 0 ? 0 : summa / Double(antal)
    }

    /// Sätter namn på de grupper som säkert nog matchar en känd röst hos kunden.
    /// Osäkra lämnas namnlösa — ett fel namn på ett kundsamtal kostar mer än
    /// en fråga till användaren.
    static func namnge(_ grupper: [Röstgrupp], mot profiler: [Röstprofil]) -> [Röstgrupp] {
        guard !profiler.isEmpty else { return grupper }
        var ut = grupper
        var tagna = Set<String>()

        // Starkaste matchningen först, så att den bästa gruppen får namnet
        // när två grupper pekar på samma person.
        var förslag: [(grupp: Int, profil: Int, likhet: Double)] = []
        for (g, grupp) in grupper.enumerated() {
            guard let bästa = grupp.bästa else { continue }
            for (p, profil) in profiler.enumerated() {
                förslag.append((g, p, profil.likhet(bästa)))
            }
        }
        for f in förslag.sorted(by: { $0.likhet > $1.likhet }) {
            guard ut[f.grupp].namn == nil,
                  !tagna.contains(profiler[f.profil].namn),
                  let bästa = ut[f.grupp].bästa,
                  f.likhet >= Tröskel.namnge(sekunder: bästa.sekunder)
            else { continue }
            ut[f.grupp].namn = profiler[f.profil].namn
            ut[f.grupp].säkerhet = f.likhet
            tagna.insert(profiler[f.profil].namn)
        }
        return ut
    }

    enum Fel: LocalizedError {
        case saknas(String), otolkbartSvar, frånPython(String)
        var errorDescription: String? {
            switch self {
            case .saknas(let v): "Röstanalysen kan inte köras: \(v)."
            case .otolkbartSvar: "Röstanalysen svarade med något som inte gick att tolka."
            case .frånPython(let f): "Röstanalysen misslyckades: \(f)"
            }
        }
    }
}

// MARK: - Hela vägen

extension Röstanalys {

    struct Uppdelning {
        var yttranden: [Yttrande]
        var namn: [Int: String]
        /// Vilken väg som användes, för att kunna säga det i gränssnittet.
        var metod: String
        /// Det som gick snett på vägen men inte stoppade uppdelningen: att
        /// avtrycken inte gick att läsa, eller att pyannote föll och
        /// klustringen fick ta över. Tidigare försvann det i tysthet, och
        /// en trasig Pythonmiljö gav namnlösa röster i varje möte utan att
        /// någon sa varför.
        var varning: String?
    }

    /// Delar upp motpartsspåret i röster och sätter namn på dem som känns igen.
    ///
    /// pyannote först, egen klustring som reserv. Samlat här därför att både
    /// inspelning, import och omgruppering behöver exakt samma sak.
    func delaUpp(fil: URL,
                 yttranden alla: [Yttrande],
                 antal: Int?,
                 profiler: [Röstprofil],
                 vidLäge: (@Sendable (String) -> Void)? = nil) async -> Uppdelning {
        let motpart = alla.filter { $0.röst == .motpart }
        let mina = alla.filter { $0.röst == .jag }
        guard !motpart.isEmpty,
              FileManager.default.fileExists(atPath: fil.path) else {
            return Uppdelning(yttranden: alla, namn: [:], metod: "ingen")
        }

        let turer = Self.turer(av: motpart)
        guard !turer.isEmpty else { return Uppdelning(yttranden: alla, namn: [:], metod: "ingen") }

        // Avtrycken behövs oavsett väg: de är det som känner igen personen
        // i nästa samtal.
        vidLäge?("Läser röstavtryck")
        var varningar: [String] = []
        let par: [(Tur, Avtryck)]
        do {
            par = try await avtryck(fil: fil, turer: turer)
        } catch {
            par = []
            varningar.append("Röstavtrycken gick inte att läsa, så ingen känns igen: "
                             + error.localizedDescription)
        }
        var avtryckPerTur: [Tur: Avtryck] = [:]
        for (t, a) in par { avtryckPerTur[t] = a }

        var grupper: [Röstgrupp]
        var metod: String
        do {
            vidLäge?("Delar upp rösterna")
            let segment = try await diarisera(fil: fil, antal: antal)
            grupper = Self.gruppera(turer: turer, avtryck: avtryckPerTur, enligt: segment)
            metod = "pyannote"
            if grupper.isEmpty { throw Fel.otolkbartSvar }
        } catch {
            // pyannote saknas eller föll — klustringen duger som reserv, men
            // den är uppmätt sämre och det ska synas.
            grupper = Self.gruppera(par, väntade: antal)
            metod = "klustring"
            varningar.append(par.isEmpty
                ? "Rösterna kunde inte delas upp: \(error.localizedDescription)"
                : "pyannote kunde inte köras (\(error.localizedDescription)), "
                  + "så rösterna delades med reservmetoden, som är sämre.")
        }

        grupper = Self.namnge(grupper, mot: profiler)

        var märkta = motpart
        var namn: [Int: String] = [:]
        for (g, grupp) in grupper.enumerated() {
            if let n = grupp.namn { namn[g] = n }
            for tur in grupp.turer {
                for (i, y) in märkta.enumerated()
                where y.start >= tur.start - 0.01 && y.slut <= tur.slut + 0.01 {
                    märkta[i].röstgrupp = g
                }
            }
        }
        return Uppdelning(yttranden: (mina + märkta).sorted { $0.start < $1.start },
                          namn: namn, metod: metod,
                          varning: varningar.isEmpty ? nil : varningar.joined(separator: " "))
    }

    /// Lär in avtryck för de röster som har namn, så att personerna känns
    /// igen nästa gång — och efter en omkörning av samma möte.
    ///
    /// Bara grupper med tillräckligt mycket tal: en kort replik ger ett
    /// avtryck som mest är brus. Ger namnen som inte gick att lära in.
    func lärIn(_ inspelning: Inspelning, mapp: URL, kund: Kund,
               arkiv: Arkivet) async -> [String] {
        let fil = mapp.appending(path: "motpart.wav")
        guard FileManager.default.fileExists(atPath: fil.path) else {
            return Array(Set(inspelning.röstnamn.values))
        }
        var misslyckade: [String] = []
        for (grupp, personnamn) in inspelning.röstnamn {
            let rader = inspelning.yttranden.filter { $0.röstgrupp == grupp }
            let turer = Self.turer(av: rader)
            guard let par = try? await avtryck(fil: fil, turer: turer),
                  let bästa = par.map(\.1).max(by: { $0.sekunder < $1.sekunder }),
                  bästa.sekunder >= Tröskel.minstaProfilLängd else {
                misslyckade.append(personnamn)
                continue
            }
            let lyckades = await MainActor.run {
                (try? arkiv.lärDigRöst(namn: personnamn, avtryck: bästa, hos: kund)) != nil
            }
            if !lyckades { misslyckade.append(personnamn) }
        }
        return misslyckade
    }
}
