import Foundation

/// Ett röstavtryck: en normerad ECAPA-vektor och hur lång ljudbit den kom från.
/// Längden följer med för att den avgör hur mycket avtrycket är värt —
/// under fyra sekunder blir en jämförelse mest brus.
struct Avtryck: Codable, Hashable {
    var vektor: [Float]
    var sekunder: Double

    init(vektor: [Float], sekunder: Double) {
        self.vektor = vektor
        self.sekunder = sekunder
    }

    /// Skriven för hand: se `Inspelning`.
    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        vektor = try c.decodeIfPresent([Float].self, forKey: .vektor) ?? []
        sekunder = try c.decodeIfPresent(Double.self, forKey: .sekunder) ?? 0
    }

    /// Cosinuslikhet. Båda vektorerna är normerade, så skalärprodukten räcker.
    func likhet(_ annan: Avtryck) -> Double {
        guard vektor.count == annan.vektor.count else { return 0 }
        var summa: Float = 0
        for i in 0..<vektor.count { summa += vektor[i] * annan.vektor[i] }
        return Double(summa)
    }
}

/// En känd röst hos en kund. Byggs upp över flera samtal: ju fler avtryck,
/// desto säkrare känns personen igen nästa gång.
struct Röstprofil: Codable, Hashable, Identifiable {
    var id = UUID()
    var namn: String
    var avtryck: [Avtryck]
    var uppdaterad: Date
    /// Antal samtal profilen har byggts av.
    var samtal: Int

    init(id: UUID = UUID(), namn: String, avtryck: [Avtryck],
         uppdaterad: Date = Date(), samtal: Int = 1) {
        self.id = id
        self.namn = namn
        self.avtryck = avtryck
        self.uppdaterad = uppdaterad
        self.samtal = samtal
    }

    /// Profilerna byggs upp över månader av samtal. Skriven för hand så att
    /// ett nytt fält inte gör dem oläsbara — se `Inspelning`.
    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        namn = try c.decodeIfPresent(String.self, forKey: .namn) ?? ""
        avtryck = try c.decodeIfPresent([Avtryck].self, forKey: .avtryck) ?? []
        uppdaterad = try c.decodeIfPresent(Date.self, forKey: .uppdaterad) ?? Date()
        samtal = try c.decodeIfPresent(Int.self, forKey: .samtal) ?? 1
    }

    /// Hur väl ett nytt avtryck stämmer med profilen. Bästa träffen räknas —
    /// samma person kan låta olika i olika samtal, och ett dåligt avtryck ska
    /// inte dra ned de bra.
    func likhet(_ nytt: Avtryck) -> Double {
        avtryck.map { $0.likhet(nytt) }.max() ?? 0
    }

    /// Lägger till ett avtryck och gallrar de svagaste, så att profilen inte
    /// växer i all oändlighet.
    mutating func lärDig(_ nytt: Avtryck, tak: Int = 8) {
        // Samma avtryck en gång till — efter en omkörning av samma möte —
        // tillför inget och skulle tränga ut de andra.
        guard !avtryck.contains(where: { $0.likhet(nytt) > 0.999 }) else { return }
        avtryck.append(nytt)
        if avtryck.count > tak {
            avtryck.sort { $0.sekunder > $1.sekunder }
            avtryck = Array(avtryck.prefix(tak))
        }
        uppdaterad = Date()
    }
}

/// Trösklar kalibrerade mot uppmätt data, se docs/RÖSTANALYS.md.
///
/// Hur väl två röster går att skilja åt beror starkt på hur långa ljudbitar
/// de mäts på. En fast tröskel skulle antingen slå ihop olika personer på
/// korta bitar eller dela upp samma person på långa.
enum Tröskel {
    /// Justering av alla trösklar på en gång, för kalibrering.
    nonisolated(unsafe) static var justering: Double =
        ProcessInfo.processInfo.environment["KUNDKOLL_JUSTERING"].flatMap(Double.init) ?? 0

    /// Över det här räknas två avtryck som samma person.
    static func samma(sekunder: Double) -> Double {
        grund(sekunder: sekunder) + justering
    }

    private static func grund(sekunder: Double) -> Double {
        switch sekunder {
        case ..<2: 0.58
        case ..<3: 0.64
        case ..<5: 0.68
        case ..<7: 0.71
        case ..<10: 0.74
        default: 0.80
        }
    }

    /// För att sätta ett namn automatiskt krävs mer än för att bunta ihop två
    /// bitar i samma samtal. Ett fel namn på ett kundsamtal är dyrare än en
    /// fråga, så appen frågar hellre än gissar.
    static func namnge(sekunder: Double) -> Double {
        min(0.88, samma(sekunder: sekunder) + 0.08)
    }

    /// Andra rundan jämför medelavtryck över hela grupper och har därför
    /// mycket mer ljud bakom sig. Men den får inte slå ihop två personer:
    /// två röster som liknar varandra hamnar högt även med mycket underlag.
    /// Påslaget kalibrerat mot mätningen i docs/RÖSTANALYS.md.
    nonisolated(unsafe) static var centroidPåslag: Double =
        ProcessInfo.processInfo.environment["KUNDKOLL_CENTROID"].flatMap(Double.init) ?? 0.06

    static func sammaGrupp(sekunder: Double) -> Double {
        min(0.95, samma(sekunder: sekunder) + centroidPåslag)
    }

    /// En tur måste vara minst så här lång för att få bilda kärna i
    /// grupperingen. Kortare avtryck är för brusiga att bygga på.
    nonisolated(unsafe) static var minstaKärnlängd: Double =
        ProcessInfo.processInfo.environment["KUNDKOLL_KÄRNLÄNGD"].flatMap(Double.init) ?? 6.0

    /// Hur stor del av taltiden kärnorna ska täcka innan resten räknas som
    /// korta. Ett tak, inte ett mål: finns det gott om långa turer behövs
    /// inte alla som kärna.
    nonisolated(unsafe) static var kärnandel: Double =
        ProcessInfo.processInfo.environment["KUNDKOLL_KÄRNANDEL"].flatMap(Double.init) ?? 0.4

    /// Så lik måste en kort tur vara en känd röst för att läggas där.
    /// Under det är det troligen en person till.
    nonisolated(unsafe) static var tilldela: Double =
        ProcessInfo.processInfo.environment["KUNDKOLL_TILLDELA"].flatMap(Double.init) ?? 0.25

    /// Vad en likhet betyder, med hänsyn till hur långt ljudet är. Det är
    /// samma trösklar som namngivningen använder — «igenkänd» sätts
    /// automatiskt, «trolig» föreslås men frågar.
    enum Omdöme: String {
        case igenkänd, trolig, svag
    }

    static func omdöme(likhet: Double, sekunder: Double) -> Omdöme {
        if likhet >= namnge(sekunder: sekunder) { return .igenkänd }
        if likhet >= samma(sekunder: sekunder) { return .trolig }
        return .svag
    }

    /// Kortare än så här är ett avtryck inte värt att spara.
    static let minstaTurLängd: Double = 1.5
    /// Under det här duger avtrycket till att följa med i klustringen, men
    /// inte till att bygga en profil av.
    static let minstaProfilLängd: Double = 4.0
}
