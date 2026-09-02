import Foundation

// Filsystemet är sanningen. De här typerna är bara läsbara vyer av det som
// ligger på disk, så att en mapp som skapats för hand i Finder eller Obsidian
// dyker upp i appen utan vidare.

struct Kund: Identifiable, Hashable {
    var id: String { mapp.path }
    var namn: String
    var mapp: URL

    var projektmapp: URL { mapp.appending(path: "Projekt") }
    var samtalsmapp: URL { mapp.appending(path: "Samtal") }
    var kontaktmapp: URL { mapp.appending(path: "Kontakter") }
    var mailmapp: URL { mapp.appending(path: "Mail") }
    var anteckningsmapp: URL { mapp.appending(path: "Anteckningar") }
}

struct Projekt: Identifiable, Hashable {
    var id: String { mapp.path }
    var namn: String
    var mapp: URL
    var kundnamn: String

    var inspelningsmapp: URL { mapp.appending(path: "Inspelningar") }
    var dokumentmapp: URL { mapp.appending(path: "Dokument") }
    var anteckningsmapp: URL { mapp.appending(path: "Anteckningar") }
}

/// Var en inspelning hamnar: hos kunden i stort, eller i ett av kundens projekt.
enum Placering: Hashable {
    case kund(Kund)
    case projekt(Projekt)

    var kundnamn: String {
        switch self {
        case .kund(let k): k.namn
        case .projekt(let p): p.kundnamn
        }
    }

    var etikett: String {
        switch self {
        case .kund(let k): k.namn
        case .projekt(let p): "\(p.kundnamn) › \(p.namn)"
        }
    }

    /// Mappen där inspelningsmappen skapas.
    var inspelningsrot: URL {
        switch self {
        case .kund(let k): k.samtalsmapp
        case .projekt(let p): p.inspelningsmapp
        }
    }
}

/// Vem som talar. Följer av vilket ljudspår raden kom från, inte av diarisering.
enum Röst: String, Codable, Hashable {
    case jag
    case motpart

    var etikett: String {
        switch self {
        case .jag: "Jag"
        case .motpart: "Motpart"
        }
    }
}

/// En rad i transkriptet.
struct Yttrande: Identifiable, Hashable, Codable {
    var id = UUID()
    var röst: Röst
    var text: String
    /// Vilken röstgrupp yttrandet tillhör på motpartsspåret. Namnet slås upp
    /// i inspelningens `röstnamn`, så att en omdöpning slår igenom överallt
    /// på en gång.
    var röstgrupp: Int?
    /// Sekunder från inspelningens start.
    var start: Double
    var slut: Double

    var tidsstämpel: String {
        let t = Int(start)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// Det som visas när ingen namntabell finns till hands.
    var etikett: String { röst.etikett }

    func etikett(_ namn: [Int: String]) -> String {
        guard röst == .motpart, let g = röstgrupp else { return röst.etikett }
        return namn[g] ?? "Röst \(g + 1)"
    }

    /// I en importerad inspelning finns ingen "motpart" — bara röster.
    func etikett(_ namn: [Int: String], enspårig: Bool) -> String {
        guard enspårig else { return etikett(namn) }
        guard let g = röstgrupp else { return "Röst" }
        return namn[g] ?? "Röst \(g + 1)"
    }
}

/// Metadata som sparas som möte.json bredvid ljudet.
///
/// Avkodningen är skriven för hand av samma skäl som för `Mailen.Mejl`: Swift
/// använder inte standardvärden när en nyckel saknas, så ett nytt fält skulle
/// annars göra alla tidigare inspelningar oläsbara.
struct Inspelning: Codable, Identifiable, Hashable {
    var id = UUID()
    var titel: String
    var inledd: Date
    var längd: Double
    var kund: String
    var projekt: String?
    /// Namnet på mikrofonen som användes, för felsökning i efterhand.
    var mikrofon: String?
    var liveYttranden: [Yttrande]
    /// Fylls i när KB-Whisper har gått igenom ljudet.
    var arkivYttranden: [Yttrande]?
    /// Namn på röstgrupperna på motpartsspåret. Tomma platser betyder att
    /// gruppen ännu inte har fått något namn.
    var röstnamn: [Int: String] = [:]
    /// De som var kallade till mötet, när inspelningen startats från kalendern.
    /// Används som förslag när rösterna ska märkas.
    var kallade: [String] = []
    /// Sant för inspelningar som importerats från en färdig fil. Där finns
    /// ingen uppdelning i mitt spår och motpartens — alla röster ligger i ett,
    /// och en av dem kan vara jag.
    var enspårig = false
    /// Namnet på filen den importerades från.
    var källfil: String?
    /// Mötets språk: "sv", "en" eller nil för att låta motorn avgöra.
    var språk: String?
    /// Vad mötet landade i. Skrivs efter efterbearbetningen.
    var sammanfattning: Mötessammanfattning?
    /// Sant medan arkivpasset pågår. Ligger det kvar när appen startas har
    /// passet avbrutits, och då erbjuds en omkörning.
    var bearbetas = false
    /// Varför arkivpasset föll senast, när det gjorde det.
    var arkivfel: String?
    /// Varför sammanfattningen inte kunde skrivas, när den inte kunde det.
    var sammanfattningsfel: String?
    /// Hur rösterna delades upp: «pyannote», «klustring» eller «ingen».
    var röstmetod: String?
    /// Sådant röstanalysen vill säga — att avtrycken inte gick att läsa,
    /// eller att reservmetoden fick användas.
    var röstvarning: String?
    var efterbearbetad: Bool { arkivYttranden != nil }
    /// Passet avbröts — appen stängdes eller föll mitt i.
    var avbruten: Bool { bearbetas }

    /// Bästa tillgängliga transkript: arkivkvalitet om det finns, annars live.
    var yttranden: [Yttrande] { arkivYttranden ?? liveYttranden }

    init(id: UUID = UUID(), titel: String, inledd: Date, längd: Double, kund: String,
         projekt: String?, mikrofon: String?, liveYttranden: [Yttrande],
         arkivYttranden: [Yttrande]?, röstnamn: [Int: String] = [:],
         kallade: [String] = [], enspårig: Bool = false, källfil: String? = nil,
         språk: String? = nil,
         sammanfattning: Mötessammanfattning? = nil,
         bearbetas: Bool = false, arkivfel: String? = nil,
         sammanfattningsfel: String? = nil,
         röstmetod: String? = nil, röstvarning: String? = nil) {
        self.id = id
        self.titel = titel
        self.inledd = inledd
        self.längd = längd
        self.kund = kund
        self.projekt = projekt
        self.mikrofon = mikrofon
        self.liveYttranden = liveYttranden
        self.arkivYttranden = arkivYttranden
        self.röstnamn = röstnamn
        self.kallade = kallade
        self.enspårig = enspårig
        self.källfil = källfil
        self.språk = språk
        self.sammanfattning = sammanfattning
        self.bearbetas = bearbetas
        self.arkivfel = arkivfel
        self.sammanfattningsfel = sammanfattningsfel
        self.röstmetod = röstmetod
        self.röstvarning = röstvarning
    }

    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        titel = try c.decodeIfPresent(String.self, forKey: .titel) ?? "Samtal"
        inledd = try c.decodeIfPresent(Date.self, forKey: .inledd) ?? Date()
        längd = try c.decodeIfPresent(Double.self, forKey: .längd) ?? 0
        kund = try c.decodeIfPresent(String.self, forKey: .kund) ?? ""
        projekt = try c.decodeIfPresent(String.self, forKey: .projekt)
        mikrofon = try c.decodeIfPresent(String.self, forKey: .mikrofon)
        liveYttranden = try c.decodeIfPresent([Yttrande].self, forKey: .liveYttranden) ?? []
        arkivYttranden = try c.decodeIfPresent([Yttrande].self, forKey: .arkivYttranden)
        röstnamn = try c.decodeIfPresent([Int: String].self, forKey: .röstnamn) ?? [:]
        kallade = try c.decodeIfPresent([String].self, forKey: .kallade) ?? []
        enspårig = try c.decodeIfPresent(Bool.self, forKey: .enspårig) ?? false
        källfil = try c.decodeIfPresent(String.self, forKey: .källfil)
        språk = try c.decodeIfPresent(String.self, forKey: .språk)
        sammanfattning = try c.decodeIfPresent(Mötessammanfattning.self, forKey: .sammanfattning)
        bearbetas = try c.decodeIfPresent(Bool.self, forKey: .bearbetas) ?? false
        arkivfel = try c.decodeIfPresent(String.self, forKey: .arkivfel)
        sammanfattningsfel = try c.decodeIfPresent(String.self, forKey: .sammanfattningsfel)
        röstmetod = try c.decodeIfPresent(String.self, forKey: .röstmetod)
        röstvarning = try c.decodeIfPresent(String.self, forKey: .röstvarning)
    }
}
