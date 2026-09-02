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
    @Published private(set) var förfluten: Double = 0
    @Published private(set) var nivåJag: Float = 0
    @Published private(set) var nivåMotpart: Float = 0
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
    @Published private(set) var röstnamn: [Int: String] = [:]
    /// Varför efterbearbetningen föll senast. Tidigare försvann det i
    /// tysthet, och mötet stod som «live» för alltid.
    @Published private(set) var efterbearbetningsfel: String?
    /// Sätts när livetranskriberingen slutat svara mitt i ett möte — annars
    /// ser en död whisper-server ut precis som tystnad.
    @Published private(set) var livevarning: String?

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
    private var mikrofonNamn: String?
    private var kallade: [String] = []
    /// Mötets språk: "sv" eller "en". Livefönstren och arkivpasset följer det.
    private var språk = "sv"
    private var start = Date()
    private var klocka: Timer?
    /// En transkribering i taget per spår, annars hamnar raderna i oordning.
    private var köer: [Röst: Task<Void, Never>] = [:]

    var pågår: Bool { if case .spelarIn = läge { true } else { false } }

    // MARK: - Start

    func starta(placering: Placering, titel: String,
                mikrofon: Ljudinfångning.Mikrofon?, kallade: [String] = [],
                språk: String = "sv") async {
        // Efter ett fel, eller ett färdigt möte som lämnats kvar, ska nästa
        // «Spela in» fungera — tidigare krävdes en omstart av appen.
        switch läge {
        case .vilande, .fel, .klar: break
        default: return
        }
        livevarning = nil
        self.placering = placering
        self.titel = titel.isEmpty ? "Samtal" : titel
        self.mikrofonNamn = mikrofon?.namn
        self.kallade = kallade
        self.språk = språk
        yttranden = []
        förfluten = 0

        do {
            läge = .förbereder("Kontrollerar behörigheter …")
            guard await Ljudinfångning.begärMikrofon() else {
                throw Enkeltfel("Kundkoll behöver tillgång till mikrofonen. Ge den i Systeminställningar → Integritet och säkerhet → Mikrofon.")
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

            infångning.vidRam = { [weak self] ram in self?.tog(ram) }
            infångning.vidFel = { [weak self] fel in self?.avbröt(fel) }
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
                    s.förfluten = Date().timeIntervalSince(s.start)
                }
            }
        } catch {
            await städa()
            läge = .fel(error.localizedDescription)
        }
    }

    // MARK: - Under inspelning

    private func tog(_ ram: Ljudram) {
        guard pågår, let b = buffring[ram.röst] else { return }
        let (mono, fönster) = b.mata(ram)
        if !mono.isEmpty { skrivare[ram.röst]?.skriv(mono) }

        switch ram.röst {
        case .jag: nivåJag = b.senasteNivå
        case .motpart: nivåMotpart = b.senasteNivå
        }

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
                text = try await self.whisper.transkribera(prov: f.prov, språk: self.språk)
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

    private func avbröt(_ fel: Error) {
        Task { await stoppa(); läge = .fel(fel.localizedDescription) }
    }

    // MARK: - Stopp

    @discardableResult
    func stoppa() async -> URL? {
        guard pågår || läge == .avslutar else { return nil }
        läge = .avslutar
        liveinsikter.sluta()
        klocka?.invalidate(); klocka = nil
        let slut = Date().timeIntervalSince(start)

        await infångning.stoppa()

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
        let inspelning = Inspelning(
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
    private func efterbearbeta(_ inspelning: Inspelning, mapp: URL) {
        let kund = Arkivet.shared.kunder.first { $0.namn == inspelning.kund }
        let profiler = kund.map { Arkivet.shared.röstprofiler(för: $0) } ?? []
        efterbearbetar = true
        efterbearbetningsfel = nil
        efterbearbetningsandel = 0
        senasteArkivrad = ""
        bearbetadMapp = mapp
        Task { [weak self] in
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

    private func städa() async {
        klocka?.invalidate(); klocka = nil
        await infångning.stoppa()
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

    func skriv(_ prov: [Float]) {
        var d = Data(capacity: prov.count * 2)
        for p in prov {
            let v = Int16(max(-1, min(1, p)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        handtag.write(d)
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
        handtag.write(Data(bytes: &le, count: 4))
        handtag.seekToEndOfFile()
    }
}

struct Enkeltfel: LocalizedError {
    let text: String
    init(_ t: String) { text = t }
    var errorDescription: String? { text }
}
