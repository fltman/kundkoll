import Foundation
import AVFoundation
import SwiftUI

/// Håller ihop en pågående inspelning: ljudet in, spåren till disk,
/// fönstren till whisper och raderna ut till gränssnittet.
@MainActor
final class Inspelningssession: ObservableObject {

    /// En och samma session i hela appen: inspelningsfönstret och raden i
    /// huvudfönstret visar samma tillstånd.
    static let delad = Inspelningssession()

    enum Läge: Equatable {
        case vilande
        case förbereder(String)
        case spelarIn
        case avslutar
        case klar(URL)
        case fel(String)
    }

    @Published private(set) var läge: Läge = .vilande
    @Published private(set) var yttranden: [Yttrande] = []
    /// Klocka och nivåmätare bor i ett eget objekt. Publicerade direkt på
    /// sessionen ritade de om hela huvudfönstret — sidopanel, mötesrader,
    /// transkript — för varje ljudbit, tiotals gånger i sekunden.
    let mätning = Mätning()
    var förfluten: Double { mätning.förfluten }
    /// Sätts när efterbearbetningen med den stora modellen är igång.
    @Published private(set) var efterbearbetar = false
    /// Sätts medan motpartsspåret delas upp i röster.
    @Published private(set) var analyserarRöster = false
    /// Sätts medan mötet sammanfattas.
    @Published private(set) var sammanfattar = false
    /// Hur långt efterbearbetningen kommit, 0–1.
    @Published private(set) var efterbearbetningsandel: Double = 0
    /// Det senast transkriberade, så att man ser att det rör sig.
    @Published private(set) var senasteArkivrad = ""
    /// Mappen vars inspelning just nu efterbearbetas, så att raden i listan
    /// kan visa var arbetet står.
    @Published private(set) var bearbetadMapp: URL?

    /// Om just den mappen efterbearbetas. Som sökväg: mappen ur en listning
    /// slutar på «/», den byggda gör det inte, och `==` blev aldrig sant —
    /// spärren mot «Flytta till» under arkivpasset slog aldrig till.
    func bearbetar(_ mapp: URL) -> Bool {
        guard let b = bearbetadMapp else { return false }
        return Arkivet.kanonisk(b.path) == Arkivet.kanonisk(mapp.path)
    }
    @Published private(set) var röstnamn: [Int: String] = [:]
    /// Varför efterbearbetningen föll senast. Tidigare försvann det i
    /// tysthet, och mötet stod som «live» för alltid.
    @Published private(set) var efterbearbetningsfel: String?
    /// Sätts när livetranskriberingen slutat svara mitt i ett möte — annars
    /// ser en död whisper-server ut precis som tystnad.
    @Published private(set) var livevarning: String?
    /// Sätts när datorljudet är dött: rena nollor från motpartsspåret
    /// medan mikrofonen hör mig tala. Se `Ljudvakt`.
    @Published private(set) var ljudvarning: String?
    private var ljudvakt = Ljudvakt()
    /// Mötet hålls i rummet: alla talar i min mikrofon. Då är ett tyst
    /// datorljud väntat, och efteråt delas alla röster upp, min med.
    @Published private(set) var rumsmöte = false

    /// Under tre sekunder tal från datorn mot minst trettio i mikrofonen.
    nonisolated static func låterSomRummet(datortal: Double, mikrofontal: Double) -> Bool {
        datortal < 3 && mikrofontal >= 30
    }

    /// Ändrar sig mitt i mötet — från varningen om tyst datorljud.
    func ärIRummet() {
        rumsmöte = true
        if ljudvarning == Ljudvakt.varning { ljudvarning = nil }
    }
    private var mikrofonvakt = Mikrofonvakt()

    /// Lyssnar efter frågeställningar medan samtalet pågår.
    let liveinsikter = Liveinsikter()

    private let infångning = Ljudinfångning()
    private let whisper = Whisper.delad
    private var buffring: [Röst: Ljudbuffring] = [.jag: Ljudbuffring(), .motpart: Ljudbuffring()]
    private var skrivare: [Röst: Spårskrivare] = [:]

    private var mapp: URL?
    /// Vad inspelningen heter, synligt för raden i huvudfönstret.
    @Published private(set) var titel = ""
    /// Var inspelningen hamnar. Läsbar utifrån så att fönstret kan öppnas
    /// igen om det stängts medan inspelningen fortsatte.
    private(set) var placering: Placering?
    private(set) var mikrofonNamn: String?
    private var kallade: [String] = []
    /// Mötets språk: "sv", "en" eller nil för att låta motorn avgöra —
    /// ett möte på svenska och norska har inget ett språk. Livefönstren
    /// och arkivpasset följer det.
    private var språk: String? = "sv"
    private var start = Date()
    private var klocka: Timer?
    /// Håller skärmen vaken medan inspelningen pågår.
    ///
    /// ScreenCaptureKit fångar ljudet genom en skärmström, och när skärmen
    /// somnar stänger systemet strömmen — inspelningen tar då slut mitt i
    /// mötet. Uppmätt den 24 november 2026: fyra möten i rummet, på batteri
    /// med skärmvila efter 2 minuter, slutade alla 10 s efter «Will Dim»,
    /// med SCStreamError -3808. Teamsmöten märkte det aldrig, för där håller
    /// Teams skärmen vaken; ett möte i rummet har ingen som gör det.
    private var vakenhet: NSObjectProtocol?
    /// En transkribering i taget per spår, annars hamnar raderna i oordning.
    private var köer: [Röst: Task<Void, Never>] = [:]

    var pågår: Bool { if case .spelarIn = läge { true } else { false } }

    // MARK: - Start

    func starta(placering: Placering, titel: String,
                mikrofon: Ljudinfångning.Mikrofon?, kallade: [String] = [],
                språk: String? = "sv", rumsmöte: Bool = false) async {
        // Efter ett fel, eller ett färdigt möte som lämnats kvar, ska nästa
        // «Spela in» fungera — tidigare krävdes en omstart av appen.
        switch läge {
        case .vilande, .fel, .klar: break
        default: return
        }
        livevarning = nil
        ljudvarning = nil
        ljudvakt = Ljudvakt()
        mikrofonvakt = Mikrofonvakt()
        self.placering = placering
        self.titel = titel.isEmpty ? "Samtal" : titel
        self.mikrofonNamn = mikrofon?.namn
        self.kallade = kallade
        self.språk = språk
        self.rumsmöte = rumsmöte
        yttranden = []
        mätning.nollställ()
        avbrottsorsak = nil

        do {
            läge = .förbereder("Kontrollerar behörigheter …")
            guard await Ljudinfångning.begärMikrofon() else {
                throw Enkeltfel("\(Appnamn.visat) behöver tillgång till mikrofonen. Ge den i Systeminställningar → Integritet och säkerhet → Mikrofon.")
            }
            guard await Ljudinfångning.harSkärmbehörighet() else {
                throw Enkeltfel("Datorljudet kräver behörigheten Skärminspelning. Ge den i Systeminställningar → Integritet och säkerhet → Skärminspelning och starta om appen.")
            }

            Notiser.begär()
            läge = .förbereder("Laddar KB-Whisper …")
            try await whisper.startaServer()

            läge = .förbereder("Skapar mapp …")
            start = Date()
            let m = try Arkivet.shared.nyInspelningsmapp(placering: placering, titel: self.titel, datum: start)
            mapp = m
            skrivare = [
                .jag: try Spårskrivare(fil: m.appending(path: "jag.wav")),
                .motpart: try Spårskrivare(fil: m.appending(path: "motpart.wav")),
            ]

            // Buffringen lever hela appstarten och räknar tiderna ur sina
            // matade prov. Utan en nollställning här ärver mötet föregående
            // mötes längd som sin nolltid.
            for (_, b) in buffring { b.nollställ() }
            infångning.vidRam = { [weak self] ram in self?.tog(ram) }
            infångning.vidFel = { [weak self] fel in self?.avbröt(fel) }
            hållVaken()
            try await infångning.starta(mikrofonID: mikrofon?.id)

            läge = .spelarIn
            if case .kund(let k) = placering {
                liveinsikter.börja(kund: k, projekt: nil)
            } else if case .projekt(let p) = placering,
                      let k = Arkivet.shared.kunder.first(where: { $0.namn == p.kundnamn }) {
                liveinsikter.börja(kund: k, projekt: p)
            }
            klocka = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let s = self, s.pågår else { return }
                    s.mätning.förfluten = Date().timeIntervalSince(s.start)
                }
            }
        } catch {
            await städa()
            // En start som föll lämnade en mapp med två tomma wav-filer,
            // och den syntes sedan som «påbörjad inspelning, 0 MB».
            if let m = mapp {
                try? FileManager.default.trashItem(at: m, resultingItemURL: nil)
                mapp = nil
            }
            läge = .fel(error.localizedDescription)
        }
    }

    // MARK: - Under inspelning

    private func tog(_ ram: Ljudram) {
        guard pågår, let b = buffring[ram.röst] else { return }
        let (mono, fönster) = b.mata(ram)
        if !mono.isEmpty, let s = skrivare[ram.röst] {
            s.skriv(mono)
            if let fel = s.fel { avbröt(fel); return }
        }

        switch ram.röst {
        case .jag: mätning.visa(jag: b.senasteNivå)
        case .motpart: mätning.visa(motpart: b.senasteNivå)
        }
        let nollor = Ljudvakt.ärNollor(mono)
        let varnar = ljudvakt.tog(röst: ram.röst, tid: ram.tid,
                                  nollor: nollor, tal: b.senasteBlockVarTal)
        if ram.röst == .jag, !mono.isEmpty { mikrofonvakt.tog(tid: ram.tid, nollor: nollor) }
        let text = mikrofonvakt.varnar ? Mikrofonvakt.varning(mikrofonNamn)
                 : varnar && !rumsmöte ? Ljudvakt.varning : nil
        if text != ljudvarning { ljudvarning = text }

        guard let f = fönster else { return }
        köa(f, röst: ram.röst)
    }

    private func köa(_ f: Ljudbuffring.Fönster, röst: Röst) {
        let tidigare = köer[röst]
        köer[röst] = Task { [weak self] in
            await tidigare?.value
            guard let self else { return }
            let text: String
            do {
                // «auto» får whisper-server att avgöra språket per fönster.
                text = try await self.whisper.transkribera(prov: f.prov, språk: self.språk ?? "auto")
            } catch {
                // Servern kan ha dött mitt i mötet. Utan det här försvann
                // varje fönster i tysthet och livepanelen bara tystnade.
                // Säg det, och försök väcka den — startaServer märker att
                // processen är borta och startar om.
                self.livevarning = "Livetranskriberingen svarar inte: \(error.localizedDescription)"
                try? await self.whisper.startaServer()
                return
            }
            if self.livevarning != nil { self.livevarning = nil }
            guard !text.isEmpty else { return }
            let y = Yttrande(röst: röst, text: text, start: f.start, slut: f.slut)
            self.yttranden.append(y)
            self.yttranden.sort { $0.start < $1.start }
            self.liveinsikter.tog(y)
        }
    }

    /// Strömmen stängdes av systemet: locket fälldes, skärmen låstes, en
    /// ljudenhet försvann. Det som hunnit spelas in sparas som ett vanligt
    /// möte — tidigare skrevs «klar» över med ett fel, fönstret gick tillbaka
    /// till startformuläret och det såg ut som om allt var borta.
    private func avbröt(_ fel: Error) {
        guard pågår else { return }
        let klockslag = Date().formatted(date: .omitted, time: .shortened)
        avbrottsorsak = "Inspelningen avbröts kl. \(klockslag): \(fel.localizedDescription) "
            + "Det som spelades in fram till dess är sparat."
        Notiser.skicka(titel: "Inspelningen avbröts", text: avbrottsorsak ?? "",
                       kund: placering?.kundnamn)
        Task { await stoppa() }
    }

    /// Varför inspelningen tog slut, när det inte var du som stoppade den.
    @Published private(set) var avbrottsorsak: String?
    /// Stoppet som pågår. Ett andra anrop — Stoppa-knappen samtidigt som
    /// strömmen faller — väntar in det i stället för att spara och
    /// efterbearbeta samma möte två gånger.
    private var stoppet: Task<URL?, Never>?

    // MARK: - Stopp

    @discardableResult
    func stoppa() async -> URL? {
        if let pågående = stoppet { return await pågående.value }
        guard pågår else { return nil }
        let t = Task { await self.stoppaEnGång() }
        stoppet = t
        let mapp = await t.value
        stoppet = nil
        return mapp
    }

    private func stoppaEnGång() async -> URL? {
        läge = .avslutar
        liveinsikter.sluta()
        klocka?.invalidate(); klocka = nil
        let slut = Date().timeIntervalSince(start)

        await infångning.stoppa()
        släppVakenhet()

        // Ta hand om det som ligger kvar i buffertarna.
        for (röst, b) in buffring {
            if let f = b.spola() { köa(f, röst: röst) }
        }
        for (_, t) in köer { await t.value }
        köer.removeAll()

        for (_, s) in skrivare { s.stäng() }
        skrivare.removeAll()
        await whisper.stoppaServer()

        guard let mapp, let placering else { läge = .vilande; return nil }
        var inspelning = Inspelning(
            titel: titel,
            inledd: start,
            längd: slut,
            kund: placering.kundnamn,
            projekt: { if case .projekt(let p) = placering { p.namn } else { nil } }(),
            mikrofon: mikrofonNamn,
            liveYttranden: yttranden,
            arkivYttranden: nil,
            kallade: kallade,
            språk: språk
        )
        // Var datorljudet tyst hela mötet medan mikrofonen hörde tal satt alla
        // i rummet, vad som än valdes — så var det med alla fyra mötena den
        // 24 november.
        let datortal = buffring[.motpart]?.talSekunder ?? 0
        let mikrofontal = buffring[.jag]?.talSekunder ?? 0
        inspelning.rumsmöte = rumsmöte || Self.låterSomRummet(datortal: datortal, mikrofontal: mikrofontal)
        do {
            try Arkivet.shared.spara(inspelning, i: mapp)
        } catch {
            // «Sparad» får inte visas när det inte stämmer. Ljudet ligger
            // kvar, och mappen syns under Påbörjade inspelningar.
            läge = .fel("Inspelningen kunde inte sparas: \(error.localizedDescription) "
                        + "Ljudet ligger kvar i «\(mapp.lastPathComponent)» och syns under "
                        + "Påbörjade inspelningar hos kunden.")
            return mapp
        }
        läge = .klar(mapp)

        // Den stora modellen får gå i bakgrunden; live-transkriptet finns redan sparat.
        efterbearbeta(inspelning, mapp: mapp)
        return mapp
    }

    /// Arkivpasset i bakgrunden: den stora modellen på båda spåren, röster
    /// och sammanfattning. Själva arbetet bor i `Efterbearbetning`; här
    /// speglas det till raden i huvudfönstret, och ett fel sägs i klartext
    /// i stället för att lämna mötet som «live» för alltid.
    /// Arkivpasset som går, så att det kan avbrytas när appen avslutas.
    /// Annars levde whisper-cli, MLX och pyannote kvar efter ⌘Q, och nästa
    /// start kunde ta upp samma möte en gång till, parallellt.
    private var efterbearbetningen: Task<Void, Never>?

    func avbrytEfterbearbetning() { efterbearbetningen?.cancel() }

    private func efterbearbeta(_ inspelning: Inspelning, mapp: URL) {
        let kund = Arkivet.shared.kunder.first { $0.namn == inspelning.kund }
        let profiler = kund.map { Arkivet.shared.röstprofiler(för: $0) } ?? []
        efterbearbetar = true
        efterbearbetningsfel = nil
        efterbearbetningsandel = 0
        senasteArkivrad = ""
        bearbetadMapp = mapp
        efterbearbetningen = Task { [weak self] in
            guard let self else { return }
            do {
                let klar = try await Efterbearbetning.kör(
                    inspelning, mapp: mapp, profiler: profiler, språk: inspelning.språk,
                    vidLäge: { l in Task { @MainActor in self.visa(l) } })
                // Bara om ingen ny inspelning hunnit börja: annars skulle det
                // förra mötets rader skriva över det nya livetranskriptet.
                if !self.pågår {
                    self.yttranden = klar.yttranden
                    self.röstnamn = klar.röstnamn
                }
                Notiser.mötetKlart(klar, mapp: mapp)
            } catch {
                self.efterbearbetningsfel = error.localizedDescription
                Notiser.bearbetningFöll(inspelning, fel: error.localizedDescription)
            }
            self.efterbearbetar = false
            self.analyserarRöster = false
            self.sammanfattar = false
            self.bearbetadMapp = nil
        }
    }

    /// Speglar passets läge till det raden och fönstret visar.
    private func visa(_ l: Efterbearbetning.Läge) {
        switch l.fas {
        case .transkriberar:
            analyserarRöster = false
            sammanfattar = false
            if let a = l.andel { efterbearbetningsandel = a }
            if let s = l.senaste, !s.isEmpty { senasteArkivrad = s }
        case .röster:
            analyserarRöster = true
            sammanfattar = false
        case .sammanfattar:
            analyserarRöster = false
            sammanfattar = true
        }
    }

    func återställ() { if case .spelarIn = läge {} else { läge = .vilande; yttranden = [] } }

    /// Nollställer bara om sessionen står i ett slutläge. Anropas när
    /// inspelningsfönstret stängs: ett fel eller ett färdigt möte som
    /// lämnas kvar skulle annars låsa nästa «Spela in».
    func återställOmKlar() {
        switch läge {
        case .klar, .fel: återställ()
        default: break
        }
    }

    private func hållVaken() {
        guard vakenhet == nil else { return }
        // .userInitiated hindrar också att datorn somnar av sig själv.
        vakenhet = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "\(Appnamn.visat) spelar in ett möte")
    }

    private func släppVakenhet() {
        if let v = vakenhet { ProcessInfo.processInfo.endActivity(v) }
        vakenhet = nil
    }

    private func städa() async {
        klocka?.invalidate(); klocka = nil
        await infångning.stoppa()
        släppVakenhet()
        for (_, s) in skrivare { s.stäng() }
        skrivare.removeAll()
        await whisper.stoppaServer()
    }
}

/// Skriver ett spår till en 16 kHz mono-WAV medan inspelningen pågår.
/// Samma format som både whisper och röstanalysen vill ha.
final class Spårskrivare {
    private let handtag: FileHandle
    private let url: URL
    private var antalProv = 0
    /// Prov sedan huvudet senast skrevs om.
    private var sedanHuvud = 0
    /// Huvudet skrivs om var femte sekund ljud. Kraschar appen mitt i ett
    /// möte, eller stängs den med ⌘Q, är filen ändå läsbar fram till dit.
    /// Tidigare stod längden noll tills stäng() hann köra, och en timmes
    /// ljud såg ut som en tom fil för whisper och spelaren.
    private static let huvudintervall = Int(Ljudbuffring.målfrekvens) * 5

    init(fil: URL) throws {
        FileManager.default.createFile(atPath: fil.path, contents: Wav.data(av: []))
        handtag = try FileHandle(forWritingTo: fil)
        url = fil
        handtag.seekToEndOfFile()
    }

    /// Satt när en skrivning föll — full disk, en utdragen extern disk.
    /// `FileHandle.write(_:)` kastade då ett Objective-C-undantag, och appen
    /// dog mitt i mötet med allt som inte hunnit få ett huvud.
    private(set) var fel: Error?

    func skriv(_ prov: [Float]) {
        guard fel == nil else { return }
        var d = Data(capacity: prov.count * 2)
        for p in prov {
            let v = Int16(max(-1, min(1, p)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        do { try handtag.write(contentsOf: d) } catch { fel = error; return }
        antalProv += prov.count
        sedanHuvud += prov.count
        if sedanHuvud >= Self.huvudintervall {
            skrivHuvud()
            sedanHuvud = 0
        }
    }

    /// WAV-huvudet innehåller längder som inte är kända förrän i slutet.
    func stäng() {
        skrivHuvud()
        try? handtag.close()
    }

    private func skrivHuvud() {
        let dataBytes = UInt32(antalProv * 2)
        skrivUInt32(dataBytes + 36, vid: 4)      // RIFF-chunkens längd
        skrivUInt32(dataBytes, vid: 40)          // data-chunkens längd
    }

    private func skrivUInt32(_ v: UInt32, vid offset: UInt64) {
        try? handtag.seek(toOffset: offset)
        var le = v.littleEndian
        try? handtag.write(contentsOf: Data(bytes: &le, count: 4))
        _ = try? handtag.seekToEnd()
    }
}

struct Enkeltfel: LocalizedError {
    let text: String
    init(_ t: String) { text = t }
    var errorDescription: String? { text }
}

/// Märker när datorljudet är dött.
///
/// Motpartsspåret är aldrig exakt noll i ett fungerande möte: mötesappen
/// skickar ett svagt brus även när ingen talar. Uppmätt den 10 september
/// 2026, tre möten med AirPods: rena nollor i över trettio minuter medan
/// mikrofonen hörde mig hela tiden — mötesappens ljud gick en väg
/// ScreenCaptureKit inte fångade — och det märktes först efteråt, när
/// transkriptet bara hade min halva. Dagen innan hjälpte det att stoppa
/// och starta om inspelningen. Vakten säger till medan mötet pågår.
///
/// Varningen kräver både nollor och tal: före samtalet är motparten
/// tyst av naturliga skäl, och den som sitter tyst i ett dött möte får
/// inget att jämföra med. Den släpps så fort ett riktigt prov kommer.
struct Ljudvakt {
    /// Sekunder nollor, medan jag talat under tiden, innan det sägs ifrån.
    static let gräns: Double = 45
    static let varning = "Datorljudet är tyst: inget från mötesappen kommer in fast du talar. "
        + "Kontrollera högtalarvalet i mötesappen, eller stoppa och starta om inspelningen."

    private var nollSedan: Double?
    private var jagTaladeSenast: Double?
    private(set) var varnar = false

    /// Om en ljudbit är digitalt tyst. Bakgrundsbrus från en mötesapp
    /// ligger långt över; Int16-noll i filen motsvarar under 1,5e-5.
    static func ärNollor(_ prov: [Float]) -> Bool {
        prov.allSatisfy { abs($0) < 1e-6 }
    }

    /// Matas med varje bit; ger om varningen ska stå.
    mutating func tog(röst: Röst, tid: Double, nollor: Bool, tal: Bool) -> Bool {
        switch röst {
        case .jag:
            if tal { jagTaladeSenast = tid }
        case .motpart:
            if nollor {
                if nollSedan == nil { nollSedan = tid }
            } else {
                nollSedan = nil
                varnar = false
            }
        }
        if let n = nollSedan, let j = jagTaladeSenast,
           tid - n >= Self.gräns, tid - j <= Self.gräns, j > n {
            varnar = true
        }
        return varnar
    }
}

/// Märker en mikrofon som inte ger något alls.
///
/// En riktig mikrofon har alltid ett golv av brus. Rena nollor betyder fel
/// enhet — uppmätt den 24 november 2026: två försök med den virtuella
/// «Microsoft Teams Audio» i ett möte i rummet gav exakt noll i varje prov
/// på båda spåren, och det märktes först när arkivpasset inte hittade tal.
struct Mikrofonvakt {
    /// Sekunder nollor innan det sägs ifrån.
    static let gräns: Double = 8

    static func varning(_ namn: String?) -> String {
        "Mikrofonen\(namn.map { " «\($0)»" } ?? "") ger inget ljud alls. "
            + "Stoppa och välj en annan mikrofon — till exempel den inbyggda."
    }

    private var nollSedan: Double?
    private(set) var varnar = false

    mutating func tog(tid: Double, nollor: Bool) {
        guard nollor else { nollSedan = nil; varnar = false; return }
        if nollSedan == nil { nollSedan = tid }
        if let n = nollSedan, tid - n >= Self.gräns { varnar = true }
    }
}

/// Klockan och nivåmätarna under en inspelning, för sig.
///
/// Mätarna uppdateras högst femton gånger i sekunden — ljudbitarna kommer
/// var tionde millisekund per spår, och ögat ser ingen skillnad.
@MainActor
final class Mätning: ObservableObject {
    @Published var förfluten: Double = 0
    @Published private(set) var jag: Float = 0
    @Published private(set) var motpart: Float = 0
    private var senastJag = Date.distantPast
    private var senastMotpart = Date.distantPast

    func visa(jag nivå: Float) {
        let nu = Date()
        guard nu.timeIntervalSince(senastJag) >= 1.0 / 15 else { return }
        senastJag = nu
        if nivå != jag { jag = nivå }
    }

    func visa(motpart nivå: Float) {
        let nu = Date()
        guard nu.timeIntervalSince(senastMotpart) >= 1.0 / 15 else { return }
        senastMotpart = nu
        if nivå != motpart { motpart = nivå }
    }

    func nollställ() {
        förfluten = 0; jag = 0; motpart = 0
        senastJag = .distantPast; senastMotpart = .distantPast
    }
}
