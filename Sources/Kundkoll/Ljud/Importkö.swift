import Foundation

/// Bakgrundsjobb, ett i taget: importer av färdiga filer, och arkivpass som
/// körs om eller tas upp igen efter ett avbrott.
///
/// Att lägga till en 40-minutersinspelning tar minuter, och det låste
/// tidigare hela appen bakom ett modalt blad. Nu stängs bladet direkt:
/// jobbet hamnar i kön, en rad längst ned i fönstret visar var det står,
/// och fler kan läggas på hög under tiden. Kön skrivs till disk, så att det
/// som väntade när appen stängdes ligger kvar när den öppnas igen.
@MainActor
final class Importkö: ObservableObject {
    static let delad = Importkö()

    struct Jobb: Identifiable {
        enum Slag {
            /// En färdig ljud- eller videofil som ska bli en inspelning.
            case importera(URL)
            /// Arkivpasset på en inspelning som redan finns: omkörning på
            /// annat språk, eller ett pass som avbröts.
            case efterbearbeta(Inspelning)
            /// En mapp med ljud men utan läsbar möte.json.
            case slutför
        }
        let id = UUID()
        let slag: Slag
        let placering: Placering
        let titel: String
        let kund: Kund
        let språk: String?
        /// Inspelningsmappen, för allt utom nya importer.
        let mapp: URL?

        var källa: URL? {
            if case .importera(let u) = slag { return u }
            return nil
        }
    }

    @Published private(set) var aktuell: Jobb?
    /// Mappen det pågående jobbet arbetar i. För omkörningar och
    /// slutföranden är den känd redan vid köandet; för en import blir den
    /// känd först när importen skapat den, och fram tills dess syntes
    /// inspelningen inte som upptagen.
    @Published private(set) var aktuellMapp: URL?
    @Published private(set) var väntande: [Jobb] = []
    @Published private(set) var steg = ""
    @Published private(set) var andel: Double?
    /// Senaste felet. Ligger kvar tills det stängs — ett jobb som föll i
    /// bakgrunden får inte försvinna spårlöst.
    @Published private(set) var fel: String?

    private var jobb: Task<Void, Never>?

    var pågår: Bool { aktuell != nil }

    /// Om mappen just nu bearbetas eller väntar på det.
    func gäller(_ mapp: URL) -> Bool {
        aktuellMapp == mapp || väntande.contains { $0.mapp == mapp }
    }

    func köa(källa: URL, placering: Placering, titel: String,
             kund: Kund, språk: String?) {
        lägg(Jobb(slag: .importera(källa), placering: placering,
                  titel: titel, kund: kund, språk: språk, mapp: nil))
    }

    /// Kör arkivpasset igen på en inspelning som finns — på valt språk, eller
    /// för att ta upp ett pass som avbröts.
    func köaOmkörning(_ inspelning: Inspelning, mapp: URL, placering: Placering,
                      kund: Kund, språk: String?) {
        guard !gäller(mapp) else { return }
        lägg(Jobb(slag: .efterbearbeta(inspelning), placering: placering,
                  titel: inspelning.titel, kund: kund, språk: språk, mapp: mapp))
    }

    /// Gör klart en mapp med ljud men utan läsbar möte.json.
    func köaSlutförande(mapp: URL, placering: Placering, kund: Kund, språk: String?) {
        guard !gäller(mapp) else { return }
        lägg(Jobb(slag: .slutför, placering: placering,
                  titel: mapp.lastPathComponent, kund: kund, språk: språk, mapp: mapp))
    }

    private func lägg(_ j: Jobb) {
        väntande.append(j)
        sparaUndan()
        kör()
    }

    func stängFel() { fel = nil }

    /// Avbryter det som pågår. Underprocesserna får en signal, och mappen
    /// lämnas i ett läge som går att köra om.
    func avbryt() { jobb?.cancel() }

    /// Tar bort ett jobb som väntar.
    func taBort(_ j: Jobb) {
        väntande.removeAll { $0.id == j.id }
        sparaUndan()
    }

    private func kör() {
        guard aktuell == nil, !väntande.isEmpty else { return }
        let j = väntande.removeFirst()
        aktuell = j
        aktuellMapp = j.mapp
        steg = "Förbereder"
        andel = nil
        sparaUndan()

        jobb = Task {
            do {
                // Profilerna hämtas här och inte vid köandet: ett jobb som
                // väntat ska känna igen röster som märkts under tiden.
                let profiler = Arkivet.shared.röstprofiler(för: j.kund)
                let vidLäge: @Sendable (Import.Läge) -> Void = { l in
                    Task { @MainActor in
                        self.steg = l.steg
                        self.andel = l.andel
                    }
                }
                switch j.slag {
                case .importera(let källa):
                    _ = try await Import().importera(
                        källa, placering: j.placering, titel: j.titel,
                        kund: j.kund, profiler: profiler, språk: j.språk,
                        vidMapp: { m in Task { @MainActor in self.aktuellMapp = m } },
                        vidLäge: vidLäge)
                case .efterbearbeta(let i):
                    guard let mapp = j.mapp else { break }
                    let klar = try await Efterbearbetning.kör(
                        i, mapp: mapp, profiler: profiler, språk: j.språk,
                        vidLäge: { l in
                            vidLäge(Import.Läge(steg: l.steg, andel: l.andel, senaste: l.senaste))
                        })
                    Notiser.mötetKlart(klar, mapp: mapp)
                case .slutför:
                    guard let mapp = j.mapp else { break }
                    _ = try await Import().slutför(
                        mapp: mapp, placering: j.placering, profiler: profiler,
                        språk: j.språk, vidLäge: vidLäge)
                }
            } catch is CancellationError {
                // Avbrutet av användaren: inget fel att visa.
            } catch {
                fel = "\(j.titel): \(error.localizedDescription)"
            }
            aktuell = nil
            aktuellMapp = nil
            jobb = nil
            sparaUndan()
            kör()
        }
    }

    // MARK: - Kön på disk

    /// Kön som den sparas. Kund och projekt sparas som sökvägar, som är det
    /// enda som identifierar dem.
    private struct Sparad: Codable {
        var slag: String
        var källa: String?
        var mapp: String?
        var kund: String
        var projekt: String?
        var titel: String
        var språk: String?

        init(slag: String, källa: String?, mapp: String?, kund: String,
             projekt: String?, titel: String, språk: String?) {
            self.slag = slag
            self.källa = källa
            self.mapp = mapp
            self.kund = kund
            self.projekt = projekt
            self.titel = titel
            self.språk = språk
        }

        /// Skriven för hand: se `Inspelning`.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            slag = try c.decodeIfPresent(String.self, forKey: .slag) ?? ""
            källa = try c.decodeIfPresent(String.self, forKey: .källa)
            mapp = try c.decodeIfPresent(String.self, forKey: .mapp)
            kund = try c.decodeIfPresent(String.self, forKey: .kund) ?? ""
            projekt = try c.decodeIfPresent(String.self, forKey: .projekt)
            titel = try c.decodeIfPresent(String.self, forKey: .titel) ?? ""
            språk = try c.decodeIfPresent(String.self, forKey: .språk)
        }
    }

    static var köfil: URL {
        let stöd = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support")
        return stöd.appending(path: "Kundkoll").appending(path: "importkö.json")
    }

    /// Skriver kön till disk. Det som pågår räknas som väntande: blir det
    /// avbrutet av ett avslut ska det göras om.
    func sparaUndan() {
        let alla = (aktuell.map { [$0] } ?? []) + väntande
        let sparade = alla.map { j -> Sparad in
            let slag: String
            switch j.slag {
            case .importera: slag = "importera"
            case .efterbearbeta: slag = "efterbearbeta"
            case .slutför: slag = "slutför"
            }
            let projekt: String? = { if case .projekt(let p) = j.placering { p.mapp.path } else { nil } }()
            return Sparad(slag: slag, källa: j.källa?.path, mapp: j.mapp?.path,
                          kund: j.kund.mapp.path, projekt: projekt,
                          titel: j.titel, språk: j.språk)
        }
        let fil = Self.köfil
        guard !sparade.isEmpty else {
            try? FileManager.default.removeItem(at: fil)
            return
        }
        try? FileManager.default.createDirectory(at: fil.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder.kundkoll.encode(sparade) {
            try? data.write(to: fil, options: .atomic)
        }
    }

    /// Tar upp det som låg i kön när appen senast stängdes.
    func återuppta() {
        let fil = Self.köfil
        guard let data = try? Data(contentsOf: fil),
              let sparade = try? JSONDecoder.kundkoll.decode([Sparad].self, from: data)
        else { return }
        try? FileManager.default.removeItem(at: fil)

        let arkiv = Arkivet.shared
        let fm = FileManager.default
        for s in sparade {
            guard let kund = arkiv.kunder.first(where: { $0.mapp.path == s.kund }) else { continue }
            let projekt = s.projekt.flatMap { väg in
                arkiv.projekt(för: kund).first { $0.mapp.path == väg }
            }
            let placering: Placering = projekt.map { .projekt($0) } ?? .kund(kund)
            switch s.slag {
            case "importera":
                guard let k = s.källa, fm.fileExists(atPath: k) else { continue }
                väntande.append(Jobb(slag: .importera(URL(fileURLWithPath: k)),
                                     placering: placering, titel: s.titel,
                                     kund: kund, språk: s.språk, mapp: nil))
            case "efterbearbeta":
                guard let m = s.mapp,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: m)
                        .appending(path: "möte.json")),
                      let i = try? JSONDecoder.kundkoll.decode(Inspelning.self, from: data)
                else { continue }
                väntande.append(Jobb(slag: .efterbearbeta(i), placering: placering,
                                     titel: i.titel, kund: kund, språk: s.språk,
                                     mapp: URL(fileURLWithPath: m)))
            case "slutför":
                guard let m = s.mapp, fm.fileExists(atPath: m) else { continue }
                väntande.append(Jobb(slag: .slutför, placering: placering,
                                     titel: s.titel, kund: kund, språk: s.språk,
                                     mapp: URL(fileURLWithPath: m)))
            default:
                continue
            }
        }
        sparaUndan()
        kör()
    }
}
