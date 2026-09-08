import Foundation

/// Läser och skriver mappstrukturen under ~/Documents/Kunder.
///
/// Ingen databas. Det som ligger på disk är sanningen, så att kunder och
/// projekt kan skapas lika gärna i Finder eller Obsidian som i appen.
@MainActor
final class Arkivet: ObservableObject {
    static let shared = Arkivet()

    let rot: URL
    @Published private(set) var kunder: [Kund] = []
    /// Räknas upp varje gång en inspelning skrivits till disk — när den
    /// stoppas, och sedan igen när arkivtranskriptet, rösterna och
    /// sammanfattningen blir klara i bakgrunden. Vyer som listar inspelningar
    /// läser om när talet ändras; annars syns ett avslutat möte först när
    /// appen startas om.
    @Published private(set) var sparningar = 0

    private let fm = FileManager.default
    /// Avkodade möte.json, nycklade på ändringstid och storlek.
    private let cache = Inspelningscache()
    private var bevakare: Filbevakare?
    private var omläsning: Task<Void, Never>?

    /// ~/Documents/Kunder, eller mappen i miljövariabeln KUNDKOLL_ROT — för
    /// demonstrationer och skärmbilder utan riktiga kunder i sidopanelen.
    static var standardrot: URL {
        if let väg = ProcessInfo.processInfo.environment["KUNDKOLL_ROT"], !väg.isEmpty {
            return URL(fileURLWithPath: väg)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents")
            .appending(path: "Kunder")
    }

    init(rot: URL? = nil) {
        self.rot = rot ?? Self.standardrot
        try? fm.createDirectory(at: self.rot, withIntermediateDirectories: true)
        läsOm()
        // Bara den delade instansen bevakar; proven skapar tillfälliga rötter.
        if rot == nil { startaBevakning() }
    }

    // MARK: - Bevakning

    private func startaBevakning() {
        bevakare = Filbevakare(rot: rot) { [weak self] vägar in
            Task { @MainActor in self?.filerÄndrades(vägar) }
        }
    }

    /// Ändringar utifrån — Finder, Obsidian, en synkad mapp. Egna
    /// skrivningar kommer inte hit.
    private func filerÄndrades(_ vägar: [String]) {
        let intressanta = vägar.filter { v in
            !v.contains("/.kundkoll/") && !v.contains("/.obsidian/")
                && !v.hasSuffix(".wav") && !v.hasSuffix(".db")
                && !v.hasSuffix("-journal") && !v.hasSuffix("-wal") && !v.hasSuffix("-shm")
                && !v.hasSuffix(".DS_Store")
        }
        guard !intressanta.isEmpty else { return }
        // Något direkt under roten: en kund har kommit eller gått.
        let rotväg = rot.standardizedFileURL.path
        if intressanta.contains(where: {
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path == rotväg
        }) {
            läsOm()
        }
        // Många händelser på en gång ska ge en omläsning, inte tjugo.
        omläsning?.cancel()
        omläsning = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.sparningar += 1
        }
    }

    // MARK: - Läsa

    func läsOm() {
        kunder = mappar(i: rot)
            .map { Kund(namn: $0.lastPathComponent, mapp: $0) }
            .sorted { $0.namn.localizedStandardCompare($1.namn) == .orderedAscending }
    }

    // Läsningarna är rena filsystemsläsningar och får köras utanför
    // huvudaktören: indexeringen och sökningen bygger på dem, och de låg
    // tidigare på huvudtråden med hela transkript i JSON.

    nonisolated func projekt(för kund: Kund) -> [Projekt] {
        mappar(i: kund.projektmapp)
            .map { Projekt(namn: $0.lastPathComponent, mapp: $0, kundnamn: kund.namn) }
            .sorted { $0.namn.localizedStandardCompare($1.namn) == .orderedAscending }
    }

    /// Alla inspelningar för en kund, nyast först. Läser möte.json i varje
    /// inspelningsmapp, både under Samtal/ och under varje projekt.
    ///
    /// Avkodningen cachas på ändringstid: en möte.json bär hela transkriptet,
    /// och en kund med hundratals möten lästes annars om i sin helhet vid
    /// varje listning.
    nonisolated func inspelningar(för kund: Kund) -> [(Inspelning, URL)] {
        var rötter = [kund.samtalsmapp]
        rötter += projekt(för: kund).map(\.inspelningsmapp)
        return rötter
            .flatMap { mappar(i: $0) }
            .compactMap { mapp in
                cache.läs(mapp.appending(path: "möte.json")).map { ($0, mapp) }
            }
            .sorted { $0.0.inledd > $1.0.inledd }
    }

    /// Inspelningsmappar vars metadata saknas eller inte går att läsa.
    ///
    /// De uppstår om appen stängs eller importen faller mitt i. Ljudet finns
    /// men ingen metadata, så mappen syns inte i listan — och blir liggande
    /// osynlig i Finder om den inte visas någonstans. En möte.json som inte
    /// går att avkoda hamnar här av samma skäl: annars försvinner hela
    /// inspelningen utan ett ord.
    nonisolated func ofullständiga(för kund: Kund) -> [(mapp: URL, storlek: Int)] {
        var rötter = [kund.samtalsmapp]
        rötter += projekt(för: kund).map(\.inspelningsmapp)
        return rötter
            .flatMap { mappar(i: $0) }
            .filter { !läsbar(i: $0) }
            .filter { mapp in
                // Bara mappar som faktiskt innehåller ljud är värda att visa.
                (try? fm.contentsOfDirectory(atPath: mapp.path))?
                    .contains { $0.hasSuffix(".wav") } ?? false
            }
            .map { ($0, storlek(av: $0)) }
            .sorted { $0.0.lastPathComponent > $1.0.lastPathComponent }
    }

    /// Om mappens möte.json finns och går att läsa.
    nonisolated private func läsbar(i mapp: URL) -> Bool {
        cache.läs(mapp.appending(path: "möte.json")) != nil
    }

    nonisolated private func storlek(av mapp: URL) -> Int {
        guard let filer = try? fm.contentsOfDirectory(
            at: mapp, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return filer.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    nonisolated private func mappar(i url: URL) -> [URL] {
        guard let innehåll = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return innehåll.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    // MARK: - Skapa

    @discardableResult
    func skapaKund(namn: String) throws -> Kund {
        let namn = städa(namn)
        let mapp = rot.appending(path: namn)
        let kund = Kund(namn: namn, mapp: mapp)
        for m in [mapp, kund.projektmapp, kund.samtalsmapp, kund.kontaktmapp,
                  kund.mailmapp, kund.anteckningsmapp] {
            try fm.createDirectory(at: m, withIntermediateDirectories: true)
        }
        try skapaValv(i: mapp, namn: namn)
        try skrivOmSaknas(kund.mapp.appending(path: "\(namn).md"), kundöversikt(namn))
        läsOm()
        return kund
    }

    @discardableResult
    func skapaProjekt(namn: String, hos kund: Kund) throws -> Projekt {
        let namn = städa(namn)
        let mapp = kund.projektmapp.appending(path: namn)
        let p = Projekt(namn: namn, mapp: mapp, kundnamn: kund.namn)
        for m in [mapp, p.inspelningsmapp, p.dokumentmapp, p.anteckningsmapp] {
            try fm.createDirectory(at: m, withIntermediateDirectories: true)
        }
        try skrivOmSaknas(mapp.appending(path: "\(namn).md"), projektöversikt(namn, kund: kund.namn))
        return p
    }

    /// Gör mappen till en Obsidian-vault. Obsidian känner igen en mapp på att
    /// .obsidian finns; resten av inställningarna skapar den själv vid behov.
    private func skapaValv(i mapp: URL, namn: String) throws {
        let konf = mapp.appending(path: ".obsidian")
        guard !fm.fileExists(atPath: konf.path) else { return }
        try fm.createDirectory(at: konf, withIntermediateDirectories: true)
        let app = """
        {
          "alwaysUpdateLinks": true,
          "newLinkFormat": "shortest",
          "useMarkdownLinks": false,
          "attachmentFolderPath": "./"
        }
        """
        try app.write(to: konf.appending(path: "app.json"), atomically: true, encoding: .utf8)
    }

    /// Grupperar om rösterna i en färdig inspelning, med ett angivet antal.
    ///
    /// Behövs för att gissningen ibland blir fel: hur lika två avtryck av
    /// samma person är beror på mikrofon och rum, och den som var med i
    /// samtalet vet hur många som talade.
    func grupperaOm(_ inspelning: Inspelning, i mapp: URL, antal: Int?) async throws -> Inspelning {
        let fil = mapp.appending(path: "motpart.wav")
        guard fm.fileExists(atPath: fil.path) else { throw Enkeltfel("Ljudspåret saknas.") }

        let kund = kunder.first { $0.namn == inspelning.kund }
        let uppdelning = await Röstanalys().delaUpp(
            fil: fil, yttranden: inspelning.yttranden, antal: antal,
            profiler: kund.map { röstprofiler(för: $0) } ?? [])

        var ut = inspelning
        ut.arkivYttranden = uppdelning.yttranden
        ut.röstnamn = uppdelning.namn
        ut.röstmetod = uppdelning.metod
        ut.röstvarning = uppdelning.varning
        ut.röstavtryck = uppdelning.avtryck
        try spara(ut, i: mapp)
        return ut
    }

    /// Flyttar en hel inspelning till papperskorgen.
    ///
    /// Papperskorgen och inte radering: ett samtal går inte att spela in igen,
    /// och den som råkar trycka fel ska kunna ta tillbaka det.
    func kastaInspelning(i mapp: URL) throws {
        try fm.trashItem(at: mapp, resultingItemURL: nil)
    }

    // MARK: - Tid

    nonisolated private func tidsfil(_ kund: Kund) -> URL {
        kund.mapp.appending(path: "tid.json")
    }

    nonisolated func tidsposter(för kund: Kund) -> [Tidspost] {
        guard let data = try? Data(contentsOf: tidsfil(kund)),
              let t = try? JSONDecoder.kundkoll.decode([Tidspost].self, from: data)
        else { return [] }
        return t.sorted { $0.start > $1.start }
    }

    func läggTill(_ post: Tidspost, för kund: Kund) throws {
        try sparaTidsposter(tidsposter(för: kund) + [post], för: kund)
    }

    func taBort(_ post: Tidspost, för kund: Kund) throws {
        try sparaTidsposter(tidsposter(för: kund).filter { $0.id != post.id }, för: kund)
    }

    private func sparaTidsposter(_ poster: [Tidspost], för kund: Kund) throws {
        let data = try JSONEncoder.kundkoll.encode(poster)
        try data.write(to: tidsfil(kund), options: .atomic)
        try? skrivTidsnot(poster, hos: kund)
        sparningar += 1
    }

    /// Tidsloggen som markdown, så att den syns i Obsidian.
    private func skrivTidsnot(_ poster: [Tidspost], hos kund: Kund) throws {
        var text = """
        ---
        typ: tid
        kund: "\(kund.namn)"
        genererad: kundkoll
        ---

        # Tid · \(kund.namn)

        \(Self.genereradRad)

        """
        let perProjekt = Dictionary(grouping: poster) { $0.projekt ?? "" }
        for (projekt, rader) in perProjekt.sorted(by: { $0.key < $1.key }) {
            let summa = rader.reduce(0) { $0 + $1.sekunder }
            text += "\n## \(projekt.isEmpty ? kund.namn : projekt) · \(Tidspost.längdtext(summa))\n\n"
            for r in rader.sorted(by: { $0.start > $1.start }) {
                text += "- \(DateFormatter.iso.string(from: r.start)) · "
                    + "\(Tidspost.längdtext(r.sekunder)) · \(r.vad)\n"
            }
        }
        try text.write(to: kund.mapp.appending(path: "Tid.md"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Möteskopplingar

    /// Vilket projekt ett kalendermöte hör till, per mötes-id.
    ///
    /// Matchningen till kund är automatisk — deltagare bland kontakterna,
    /// kundens mejldomän eller kundnamnet i titeln — men projektet inom
    /// kunden kan ingen regel gissa, så det väljs för hand och sparas här.
    nonisolated private func möteskopplingsfil(_ kund: Kund) -> URL {
        kund.mapp.appending(path: ".kundkoll/möteskopplingar.json")
    }

    nonisolated func möteskopplingar(för kund: Kund) -> [String: String] {
        guard let data = try? Data(contentsOf: möteskopplingsfil(kund)),
              let k = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return k
    }

    /// Kopplar ett möte till kunden, med eller utan projekt. Att nyckeln
    /// finns betyder att mötet hör hit — så även ett möte som ingen regel
    /// känner igen (inga deltagare, inget kundnamn i titeln) kan tas i
    /// anspråk för hand. Tom sträng är kundnivå.
    func kopplaMöte(_ mötesID: String, till projekt: String?, för kund: Kund) throws {
        var alla = möteskopplingar(för: kund)
        alla[mötesID] = projekt ?? ""
        try skrivMöteskopplingar(alla, för: kund)
    }

    func taBortMöteskoppling(_ mötesID: String, för kund: Kund) throws {
        var alla = möteskopplingar(för: kund)
        alla.removeValue(forKey: mötesID)
        try skrivMöteskopplingar(alla, för: kund)
    }

    private func skrivMöteskopplingar(_ alla: [String: String], för kund: Kund) throws {
        try fm.createDirectory(at: kund.mapp.appending(path: ".kundkoll"),
                               withIntermediateDirectories: true)
        let data = try JSONEncoder.kundkoll.encode(alla)
        try data.write(to: möteskopplingsfil(kund), options: .atomic)
    }

    // MARK: - Uppgifter

    nonisolated private func uppgiftsfil(_ kund: Kund) -> URL {
        kund.mapp.appending(path: "uppgifter.json")
    }

    nonisolated func uppgifter(för kund: Kund) -> [Uppgift] {
        guard let data = try? Data(contentsOf: uppgiftsfil(kund)),
              let u = try? JSONDecoder.kundkoll.decode([Uppgift].self, from: data)
        else { return [] }
        return u
    }

    func sparaUppgifter(_ uppgifter: [Uppgift], för kund: Kund) throws {
        let data = try JSONEncoder.kundkoll.encode(uppgifter)
        try data.write(to: uppgiftsfil(kund), options: .atomic)
        try skrivUppgiftsnot(uppgifter, hos: kund)
    }

    /// Lägger till nya uppgifter utan att skapa dubbletter av sådant som redan
    /// står där. Samma åtagande nämns ofta i både ett möte och ett mejl.
    @discardableResult
    func läggTill(_ nya: [Uppgift], för kund: Kund) throws -> [Uppgift] {
        var alla = uppgifter(för: kund)
        var tillagda = 0
        for ny in nya where !alla.contains(where: { $0.liknar(ny) }) {
            alla.append(ny)
            tillagda += 1
        }
        guard tillagda > 0 else { return alla }
        try sparaUppgifter(alla, för: kund)
        return alla
    }

    func uppdatera(_ uppgift: Uppgift, för kund: Kund) throws {
        var alla = uppgifter(för: kund)
        guard let i = alla.firstIndex(where: { $0.id == uppgift.id }) else { return }
        var ändrad = uppgift
        ändrad.ändrad = Date()
        alla[i] = ändrad
        try sparaUppgifter(alla, för: kund)
        // Alla ändringar går genom hit, så spegeln till Påminnelser bor här.
        Påminnelser.delad.spegla(ändrad)
    }

    func taBort(_ uppgift: Uppgift, för kund: Kund) throws {
        try sparaUppgifter(uppgifter(för: kund).filter { $0.id != uppgift.id }, för: kund)
    }

    /// Tavlan som markdown, så att den syns i Obsidian.
    private func skrivUppgiftsnot(_ uppgifter: [Uppgift], hos kund: Kund) throws {
        var text = """
        ---
        typ: uppgifter
        kund: "\(kund.namn)"
        genererad: kundkoll
        ---

        # Att göra — \(kund.namn)

        [[\(kund.namn)]]

        \(Self.genereradRad)

        """
        for läge in Uppgift.Läge.allCases {
            let ivarje = uppgifter.filter { $0.läge == läge }
            guard !ivarje.isEmpty else { continue }
            text += "\n## \(läge.namn)\n\n"
            for u in ivarje.sorted(by: { $0.skapad < $1.skapad }) {
                let vem = u.vem.map { "**\($0)** " } ?? ""
                let när = u.när.map { " *(\($0))*" } ?? ""
                let varifrån = u.källtitel.map { " — \($0)" } ?? ""
                text += "- [\(läge == .klart ? "x" : " ")] \(vem)\(u.vad)\(när)\(varifrån)\n"
            }
        }
        try text.write(to: kund.mapp.appending(path: "Att göra.md"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Kopplade mappar

    nonisolated private func kopplingsfil(_ projekt: Projekt) -> URL {
        projekt.mapp.appending(path: "kopplade-mappar.json")
    }

    nonisolated func kopplade(för projekt: Projekt) -> [Kopplad] {
        guard let data = try? Data(contentsOf: kopplingsfil(projekt)),
              let k = try? JSONDecoder.kundkoll.decode([Kopplad].self, from: data)
        else { return [] }
        return k
    }

    func sparaKopplade(_ mappar: [Kopplad], för projekt: Projekt) throws {
        let data = try JSONEncoder.kundkoll.encode(mappar)
        try data.write(to: kopplingsfil(projekt), options: .atomic)
    }

    @discardableResult
    func koppla(_ mapp: URL, till projekt: Projekt) throws -> [Kopplad] {
        var alla = kopplade(för: projekt)
        let väg = mapp.standardizedFileURL.path
        guard !alla.contains(where: { $0.väg == väg }) else { return alla }
        alla.append(Kopplad(väg: väg))
        try sparaKopplade(alla, för: projekt)
        return alla
    }

    @discardableResult
    func koppla(bort mapp: Kopplad, från projekt: Projekt) throws -> [Kopplad] {
        let kvar = kopplade(för: projekt).filter { $0.väg != mapp.väg }
        try sparaKopplade(kvar, för: projekt)
        return kvar
    }

    // MARK: - Anteckningar

    /// Anteckningar i en mapp, nyast ändrad först.
    nonisolated func anteckningar(i mapp: URL) -> [Anteckning] {
        guard let filer = try? fm.contentsOfDirectory(
            at: mapp, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return filer
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let ändrad = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return Anteckning(titel: url.deletingPathExtension().lastPathComponent,
                                  text: text, ändrad: ändrad ?? .distantPast, fil: url)
            }
            .sorted { $0.ändrad > $1.ändrad }
    }

    /// Skapar en anteckning. Titeln blir filnamnet.
    func nyAnteckning(i mapp: URL, titel: String) throws -> Anteckning {
        try fm.createDirectory(at: mapp, withIntermediateDirectories: true)
        let rent = städa(titel.isEmpty ? "Anteckning" : titel)
        var namn = rent
        var url = mapp.appending(path: "\(namn).md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            namn = "\(rent) \(n)"
            url = mapp.appending(path: "\(namn).md")
            n += 1
        }
        let text = "# \(namn)\n\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return Anteckning(titel: namn, text: text, ändrad: Date(), fil: url)
    }

    func spara(_ anteckning: Anteckning) throws {
        try anteckning.text.write(to: anteckning.fil, atomically: true, encoding: .utf8)
    }

    /// Papperskorgen, inte radering: en anteckning är text man skrivit
    /// själv, och inspelningarna går redan den vägen.
    func taBort(_ anteckning: Anteckning) throws {
        try fm.trashItem(at: anteckning.fil, resultingItemURL: nil)
    }

    /// Byter namn på anteckningen och därmed på filen.
    func döpOm(_ anteckning: Anteckning, till titel: String) throws -> Anteckning {
        let rent = städa(titel)
        guard !rent.isEmpty, rent != anteckning.titel else { return anteckning }
        let ny = anteckning.fil.deletingLastPathComponent().appending(path: "\(rent).md")
        guard !fm.fileExists(atPath: ny.path) else { return anteckning }
        try fm.moveItem(at: anteckning.fil, to: ny)
        var ut = anteckning
        ut.titel = rent
        ut.fil = ny
        return ut
    }

    /// Sparar en bild bredvid anteckningarna och ger namnet att länka med.
    func sparaBild(_ data: Data, ändelse: String, i mapp: URL) throws -> String {
        let bildmapp = mapp.appending(path: Anteckning.bildmapp)
        try fm.createDirectory(at: bildmapp, withIntermediateDirectories: true)
        let namn = "\(DateFormatter.bildnamn.string(from: Date())).\(ändelse)"
        try data.write(to: bildmapp.appending(path: namn), options: .atomic)
        return "\(Anteckning.bildmapp)/\(namn)"
    }

    // MARK: - Kontakter

    nonisolated func kontakter(för kund: Kund) -> [Kontakt] {
        let url = kund.kontaktmapp.appending(path: "kontakter.json")
        guard let data = try? Data(contentsOf: url),
              let k = try? JSONDecoder.kundkoll.decode([Kontakt].self, from: data)
        else { return [] }
        return k.sorted { $0.namn.localizedStandardCompare($1.namn) == .orderedAscending }
    }

    func sparaKontakter(_ kontakter: [Kontakt], för kund: Kund) throws {
        try fm.createDirectory(at: kund.kontaktmapp, withIntermediateDirectories: true)
        let data = try JSONEncoder.kundkoll.encode(kontakter)
        try data.write(to: kund.kontaktmapp.appending(path: "kontakter.json"), options: .atomic)
        for k in kontakter { try skrivKontaktnot(k, hos: kund) }
    }

    @discardableResult
    func läggTill(_ kontakt: Kontakt, hos kund: Kund) throws -> [Kontakt] {
        var alla = kontakter(för: kund)
        // Samma person två gånger blir lätt av att både adressboken och ett
        // kalendermöte föreslår hen.
        if let i = alla.firstIndex(where: {
            ($0.systemID != nil && $0.systemID == kontakt.systemID)
                || $0.namn.caseInsensitiveCompare(kontakt.namn) == .orderedSame
        }) {
            var ihop = alla[i]
            ihop.roll = ihop.roll ?? kontakt.roll
            ihop.systemID = ihop.systemID ?? kontakt.systemID
            for e in kontakt.epost where !ihop.epost.contains(e) { ihop.epost.append(e) }
            for t in kontakt.telefon where !ihop.telefon.contains(t) { ihop.telefon.append(t) }
            alla[i] = ihop
        } else {
            alla.append(kontakt)
        }
        try sparaKontakter(alla, för: kund)
        return alla
    }

    /// Noten och profilbilden följer med till papperskorgen — de blev
    /// tidigare liggande föräldralösa i mappen.
    func taBort(_ kontakt: Kontakt, hos kund: Kund) throws {
        try sparaKontakter(kontakter(för: kund).filter { $0.id != kontakt.id }, för: kund)
        let not = kund.kontaktmapp.appending(path: "\(städa(kontakt.namn)).md")
        if fm.fileExists(atPath: not.path) { try? fm.trashItem(at: not, resultingItemURL: nil) }
        if let bild = kontakt.bild {
            let fil = kontaktbildsmapp(kund).appending(path: bild)
            if fm.fileExists(atPath: fil.path) { try? fm.removeItem(at: fil) }
        }
    }

    /// En not per kontakt, så att Obsidian kan länka till personen från
    /// transkript och anteckningar.
    ///
    /// Uppgifterna ligger i frontmatter och brödtexten är användarens egen.
    /// Då kan uppgifterna uppdateras utan att anteckningar skrivs över.
    private func skrivKontaktnot(_ k: Kontakt, hos kund: Kund) throws {
        let url = kund.kontaktmapp.appending(path: "\(städa(k.namn)).md")

        var huvud = """
        ---
        typ: kontakt
        kund: "\(kund.namn)"
        """
        if let roll = k.roll { huvud += "\nroll: \"\(roll)\"" }
        if !k.epost.isEmpty {
            huvud += "\nepost:\n" + k.epost.map { "  - \($0)" }.joined(separator: "\n")
        }
        if !k.telefon.isEmpty {
            huvud += "\ntelefon:\n" + k.telefon.map { "  - \"\($0)\"" }.joined(separator: "\n")
        }
        huvud += "\n---\n"

        let brödtext: String
        if let gammal = try? String(contentsOf: url, encoding: .utf8) {
            brödtext = Self.utanFrontmatter(gammal)
        } else {
            brödtext = "\n# \(k.namn)\n\n[[\(kund.namn)]]\n"
        }
        try (huvud + brödtext).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Allt efter frontmatter-blocket. Filer utan frontmatter lämnas orörda.
    static func utanFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") else { return text }
        let efterStart = text.index(text.startIndex, offsetBy: 4)
        guard let slut = text.range(of: "\n---\n", range: efterStart..<text.endIndex) else {
            return text
        }
        return String(text[slut.upperBound...])
    }

    /// Ersätter en kontakt med samma id.
    /// Profilbilderna ligger som filer bredvid kontaktnoterna, aldrig som
    /// data i json — de ska synas i Finder och följa med kundmappen.
    func kontaktbildsmapp(_ kund: Kund) -> URL {
        kund.kontaktmapp.appending(path: "bilder")
    }

    func kontaktbild(för kontakt: Kontakt, hos kund: Kund) -> URL? {
        guard let bild = kontakt.bild else { return nil }
        let url = kontaktbildsmapp(kund).appending(path: bild)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Sparar bilddata som kontaktens profilbild och ger filnamnet.
    /// Bilden skalas ned — ett sigill behöver inte tolv megapixlar.
    @discardableResult
    func sparaKontaktbild(_ data: Data, för kontakt: inout Kontakt,
                          hos kund: Kund) throws -> String {
        guard let liten = Bildverktyg.jpegSigill(data, sida: 256) else {
            throw Enkeltfel("Bilden gick inte att läsa.")
        }
        try fm.createDirectory(at: kontaktbildsmapp(kund), withIntermediateDirectories: true)
        let namn = "\(kontakt.id.uuidString).jpg"
        try liten.write(to: kontaktbildsmapp(kund).appending(path: namn), options: .atomic)
        kontakt.bild = namn
        try uppdatera(kontakt, hos: kund)
        return namn
    }

    func taBortKontaktbild(för kontakt: inout Kontakt, hos kund: Kund) throws {
        if let bild = kontakt.bild {
            try? fm.removeItem(at: kontaktbildsmapp(kund).appending(path: bild))
        }
        kontakt.bild = nil
        try uppdatera(kontakt, hos: kund)
    }

    func uppdatera(_ kontakt: Kontakt, hos kund: Kund) throws {
        var alla = kontakter(för: kund)
        guard let i = alla.firstIndex(where: { $0.id == kontakt.id }) else {
            try läggTill(kontakt, hos: kund)
            return
        }
        // Namnbyte lämnar en föräldralös not efter sig.
        let gammaltNamn = alla[i].namn
        if gammaltNamn != kontakt.namn {
            let gammalNot = kund.kontaktmapp.appending(path: "\(städa(gammaltNamn)).md")
            let nyNot = kund.kontaktmapp.appending(path: "\(städa(kontakt.namn)).md")
            if fm.fileExists(atPath: gammalNot.path), !fm.fileExists(atPath: nyNot.path) {
                try? fm.moveItem(at: gammalNot, to: nyNot)
            }
        }
        alla[i] = kontakt
        try sparaKontakter(alla, för: kund)
        // Rösten, mötena och tavlan känner personen på namnet.
        if gammaltNamn != kontakt.namn {
            try? byt(personnamn: gammaltNamn, till: kontakt.namn, hos: kund)
        }
    }

    /// Byter namn på en person överallt hos kunden: röstprofilen, rösterna
    /// i mötena och uppgifternas «vem».
    ///
    /// Ett namnbyte på kontakten lämnade annars en röst kvar under det
    /// gamla namnet — «Kristin» bredvid «Kristin Sand Backen» — och mötena
    /// höll fast vid det gamla. Finns redan en profil med det nya namnet
    /// slås avtrycken ihop.
    func byt(personnamn gammalt: String, till nytt: String, hos kund: Kund) throws {
        let nytt = nytt.trimmingCharacters(in: .whitespaces)
        guard !nytt.isEmpty, gammalt != nytt else { return }

        var profiler = egnaRöstprofiler(för: kund)
        if let g = profiler.firstIndex(where: { $0.namn == gammalt }) {
            let gammal = profiler.remove(at: g)
            if let n = profiler.firstIndex(where: { $0.namn == nytt }) {
                for a in gammal.avtryck { profiler[n].lärDig(a) }
                profiler[n].samtal += gammal.samtal
            } else {
                var ny = gammal
                ny.namn = nytt
                profiler.append(ny)
            }
            try sparaRöstprofiler(profiler, för: kund)
        }

        for (i, mapp) in inspelningar(för: kund) where i.röstnamn.values.contains(gammalt) {
            var u = i
            for (grupp, namn) in u.röstnamn where namn == gammalt { u.röstnamn[grupp] = nytt }
            try? spara(u, i: mapp)
        }

        var ändrat = false
        let uppdaterade = uppgifter(för: kund).map { u -> Uppgift in
            guard u.vem?.caseInsensitiveCompare(gammalt) == .orderedSame else { return u }
            var u = u
            u.vem = nytt
            ändrat = true
            return u
        }
        if ändrat { try sparaUppgifter(uppdaterade, för: kund) }
        sparningar += 1
    }

    /// Glömmer en röst. Mötena behåller namnet; det är avtrycket som tas bort.
    func taBortRöst(namn: String, hos kund: Kund) throws {
        try sparaRöstprofiler(egnaRöstprofiler(för: kund).filter { $0.namn != namn }, för: kund)
        sparningar += 1
    }

    // MARK: - Chatt

    /// Samtalen ligger i en dold mapp, inte i valvet: de är en logg över
    /// frågor, inte material man vill läsa i Obsidian.
    private func samtalsmappen(_ kund: Kund) -> URL {
        kund.mapp.appending(path: ".kundkoll/samtal")
    }

    /// Kundens samtal, nyast först. Ett projekt ser bara sina egna, och ett
    /// möte bara de som ställts om just det mötet.
    func samtal(för kund: Kund, projekt: String?, möte: String? = nil) -> [Samtal] {
        let mapp = samtalsmappen(kund)
        guard let filer = try? fm.contentsOfDirectory(
            at: mapp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            // Inget här än — kanske finns en chatt från tiden före samtalen.
            return flyttaInGammalChatt(kund, projekt: projekt)
        }
        return filer
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Samtal? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.kundkoll.decode(Samtal.self, from: data)
            }
            .filter { $0.möte == möte && ($0.möte != nil || $0.projekt == projekt) }
            .sorted { $0.ändrad > $1.ändrad }
    }

    func spara(_ samtal: Samtal, för kund: Kund) throws {
        let mapp = samtalsmappen(kund)
        try fm.createDirectory(at: mapp, withIntermediateDirectories: true)
        var ut = samtal
        ut.ändrad = Date()
        if ut.titel == "Nytt samtal" || ut.titel.isEmpty {
            ut.titel = Samtal.titel(ur: ut.meddelanden)
        }
        let data = try JSONEncoder.kundkoll.encode(ut)
        try data.write(to: mapp.appending(path: "\(ut.id.uuidString).json"), options: .atomic)
    }

    func taBort(_ samtal: Samtal, för kund: Kund) throws {
        let fil = samtalsmappen(kund).appending(path: "\(samtal.id.uuidString).json")
        try? fm.removeItem(at: fil)
    }

    /// Tar hand om chattarna från tiden då varje kund hade exakt en.
    @discardableResult
    private func flyttaInGammalChatt(_ kund: Kund, projekt: String?) -> [Samtal] {
        let gammal = projekt.map { kund.mapp.appending(path: ".kundkoll/chatt-\(städa($0)).json") }
            ?? kund.mapp.appending(path: ".kundkoll/chatt.json")
        guard let data = try? Data(contentsOf: gammal),
              let meddelanden = try? JSONDecoder.kundkoll.decode([Chatt.Meddelande].self, from: data),
              !meddelanden.isEmpty
        else { return [] }

        let samtal = Samtal(titel: Samtal.titel(ur: meddelanden), projekt: projekt,
                            meddelanden: meddelanden,
                            skapad: meddelanden.first?.tid ?? Date(),
                            ändrad: meddelanden.last?.tid ?? Date())
        try? spara(samtal, för: kund)
        try? fm.removeItem(at: gammal)
        return [samtal]
    }

    // MARK: - Mail

    /// Det som senast hämtades ur Mail, sparat hos kunden.
    ///
    /// Sökningen tar sekunder och Mail behöver vara igång, så resultatet ska
    /// inte gå förlorat bara för att appen startas om.
    struct Mailcache: Codable {
        var hämtad: Date
        var mejl: [Mailen.Mejl]
        /// Bilagor med den text som gick att få ut ur dem.
        var bilagor: [Bilagor.Bilaga] = []

        init(hämtad: Date, mejl: [Mailen.Mejl], bilagor: [Bilagor.Bilaga] = []) {
            self.hämtad = hämtad
            self.mejl = mejl
            self.bilagor = bilagor
        }

        /// En cache sparad innan bilagorna fanns saknar det fältet.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            hämtad = try c.decodeIfPresent(Date.self, forKey: .hämtad) ?? .distantPast
            mejl = try c.decodeIfPresent([Mailen.Mejl].self, forKey: .mejl) ?? []
            bilagor = try c.decodeIfPresent([Bilagor.Bilaga].self, forKey: .bilagor) ?? []
        }

        var ålder: TimeInterval { Date().timeIntervalSince(hämtad) }

        /// Äldre än så här och det är värt att hämta om automatiskt.
        var färsk: Bool { ålder < 15 * 60 }
    }

    nonisolated func mailcache(för kund: Kund) -> Mailcache? {
        let url = kund.mailmapp.appending(path: "mail.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.kundkoll.decode(Mailcache.self, from: data)
    }

    func sparaMail(_ mejl: [Mailen.Mejl], bilagor: [Bilagor.Bilaga] = [],
                   för kund: Kund) throws {
        try skrivMailcache(Mailcache(hämtad: Date(), mejl: mejl, bilagor: bilagor), för: kund)
    }

    private func skrivMailcache(_ cache: Mailcache, för kund: Kund) throws {
        try fm.createDirectory(at: kund.mailmapp, withIntermediateDirectories: true)
        let data = try JSONEncoder.kundkoll.encode(cache)
        try data.write(to: kund.mailmapp.appending(path: "mail.json"), options: .atomic)
        try skrivMailnot(cache, hos: kund)
    }

    /// Korrespondensen som markdown, så att den syns i Obsidian bredvid
    /// transkript och anteckningar.
    private func skrivMailnot(_ cache: Mailcache, hos kund: Kund) throws {
        var text = """
        ---
        typ: mail
        kund: "\(kund.namn)"
        hämtad: \(DateFormatter.iso.string(from: cache.hämtad))
        genererad: kundkoll
        ---

        # Mail — \(kund.namn)

        [[\(kund.namn)]]

        \(Self.genereradRad)

        """
        if !cache.bilagor.isEmpty {
            text += "\n## Bilagor\n\n"
            for b in cache.bilagor.sorted(by: { $0.ämne < $1.ämne }) {
                let läst = b.text == nil ? "" : " · text inläst"
                text += "- [[Bilagor/\(b.namn)]] — \(b.ämne)\(läst)\n"
            }
        }

        var senasteDag = ""
        for m in cache.mejl {
            let dag = m.datum.map { DateFormatter.dag.string(from: $0) } ?? "Okänt datum"
            if dag != senasteDag {
                text += "\n## \(dag)\n\n"
                senasteDag = dag
            }
            let vem = m.skickat ? "→ " : "← "
            let klocka = m.datum.map { DateFormatter.timme.string(from: $0) } ?? ""
            text += "- \(vem)**\(m.ämne)** · \(m.skickat ? "jag" : m.avsändarnamn) \(klocka)\n"
        }
        try text.write(to: kund.mailmapp.appending(path: "Mail.md"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Röstprofiler

    /// Kända röster hos en kund. Ligger hos kunden och inte globalt: samma
    /// person kan förekomma hos flera kunder, och profilerna ska inte läcka
    /// mellan kundärenden.
    func röstprofiler(för kund: Kund) -> [Röstprofil] {
        var alla = egnaRöstprofiler(för: kund)
        // Med delning påslagen räknas även andra kunders profiler, men kundens
        // egna går först: samma namn där vinner.
        if Inställningar.delaRöstprofiler {
            let egna = Set(alla.map(\.namn))
            for annan in kunder where annan.namn != kund.namn {
                alla += egnaRöstprofiler(för: annan).filter { !egna.contains($0.namn) }
            }
        }
        return alla.sorted { $0.namn.localizedStandardCompare($1.namn) == .orderedAscending }
    }

    /// Kundens egna röster, utan de delade från andra kunder.
    func egnaRöstprofiler(för kund: Kund) -> [Röstprofil] {
        let url = kund.kontaktmapp.appending(path: "röstprofiler.json")
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder.kundkoll.decode([Röstprofil].self, from: data)
        else { return [] }
        return p
    }

    func sparaRöstprofiler(_ profiler: [Röstprofil], för kund: Kund) throws {
        try fm.createDirectory(at: kund.kontaktmapp, withIntermediateDirectories: true)
        let data = try JSONEncoder.kundkoll.encode(profiler)
        try data.write(to: kund.kontaktmapp.appending(path: "röstprofiler.json"), options: .atomic)
    }

    /// Lägger ett nytt avtryck till rätt person, eller skapar personen.
    func lärDigRöst(namn: String, avtryck: Avtryck, hos kund: Kund) throws {
        // Lärs alltid in hos den egna kunden, även när delning är påslagen.
        var profiler = egnaRöstprofiler(för: kund)
        if let i = profiler.firstIndex(where: { $0.namn == namn }) {
            profiler[i].lärDig(avtryck)
            profiler[i].samtal += 1
        } else {
            profiler.append(Röstprofil(namn: namn, avtryck: [avtryck],
                                       uppdaterad: Date(), samtal: 1))
        }
        try sparaRöstprofiler(profiler, för: kund)
    }

    // MARK: - Skriva inspelning

    /// Skapar mappen för en ny inspelning och returnerar den.
    func nyInspelningsmapp(placering: Placering, titel: String, datum: Date) throws -> URL {
        let stämpel = DateFormatter.mappnamn.string(from: datum)
        var namn = "\(stämpel) \(städa(titel))"
        var mapp = placering.inspelningsrot.appending(path: namn)
        var n = 2
        while fm.fileExists(atPath: mapp.path) {
            namn = "\(stämpel) \(städa(titel)) \(n)"
            mapp = placering.inspelningsrot.appending(path: namn)
            n += 1
        }
        try fm.createDirectory(at: mapp, withIntermediateDirectories: true)
        return mapp
    }

    /// Sparar metadata och det markdown Obsidian ska visa.
    func spara(_ inspelning: Inspelning, i mapp: URL) throws {
        let data = try JSONEncoder.kundkoll.encode(inspelning)
        let json = mapp.appending(path: "möte.json")
        try data.write(to: json, options: .atomic)
        cache.sätt(json, till: inspelning)
        try markdown(för: inspelning, mapp: mapp)
            .write(to: mapp.appending(path: "Transkript.md"), atomically: true, encoding: .utf8)
        sparningar += 1
    }

    /// Raden som säger att filen är skriven av appen. Att göra.md,
    /// Transkript.md, Mail.md och Tid.md byggs om vid varje sparning, och en
    /// ändring gjord i Obsidian försvann tidigare utan förvarning.
    static let genereradRad =
        "*Skriven av \(Appnamn.visat) och byggs om vid varje sparning — ändra i appen, inte här.*"

    private func markdown(för i: Inspelning, mapp: URL) -> String {
        var ut = """
        ---
        typ: transkript
        kund: "\(i.kund)"
        \(i.projekt.map { "projekt: \"\($0)\"" } ?? "projekt:")
        datum: \(DateFormatter.iso.string(from: i.inledd))
        längd: \(formateraLängd(i.längd))
        kvalitet: \(i.efterbearbetad ? "arkiv (KB-Whisper)" : "live (Apple)")
        genererad: kundkoll
        ---

        # \(i.titel)

        [[\(i.kund)]]\(i.projekt.map { " · [[\($0)]]" } ?? "")

        \(Self.genereradRad)

        """
        if !i.efterbearbetad {
            ut += "\n> Live-transkript. Efterbearbetning med KB-Whisper ger interpunktion och bättre egennamn.\n"
        }
        let deltagare = Set(i.röstnamn.values).sorted()
        if !deltagare.isEmpty {
            ut += "\nDeltagare: " + deltagare.map { "[[\($0)]]" }.joined(separator: ", ") + "\n"
        }
        if let s = i.sammanfattning, !s.tom {
            if !s.kärna.isEmpty { ut += "\n\(s.kärna)\n" }
            if !s.beslut.isEmpty {
                ut += "\n## Beslut\n\n" + s.beslut.map { "- \($0)\n" }.joined()
            }
            if !s.åtaganden.isEmpty {
                ut += "\n## Att göra\n\n"
                for å in s.åtaganden {
                    let vem = å.vem.map { "**\($0)** " } ?? ""
                    let när = å.när.map { " *(\($0))*" } ?? ""
                    ut += "- [\(å.klart ? "x" : " ")] \(vem)\(å.vad)\(när)\n"
                }
            }
            if !s.öppet.isEmpty {
                ut += "\n## Öppna frågor\n\n" + s.öppet.map { "- \($0)\n" }.joined()
            }
        }

        ut += "\n## Transkript\n\n"
        for y in i.yttranden {
            ut += "**\(y.etikett(i.röstnamn))** `\(y.tidsstämpel)`\n\(y.text)\n\n"
        }
        return ut
    }

    // MARK: - Småsaker

    /// Sökvägar jämförs i en enhetlig form. /var, /tmp och /etc är länkar in
    /// i /private, och det som listas ur en mapp kommer i den ena skepnaden
    /// medan det som byggts ur kundmappen kommer i den andra. Länkarna
    /// tas bort för hand: `resolvingSymlinksInPath` lämnar en väg som inte
    /// finns orörd, och efter en flytt finns den gamla vägen inte längre.
    nonisolated static func kanonisk(_ väg: String) -> String {
        let v = URL(fileURLWithPath: väg).standardizedFileURL.path
        for p in ["/private/var/", "/private/tmp/", "/private/etc/"] where v.hasPrefix(p) {
            return String(v.dropFirst("/private".count))
        }
        return v
    }

    /// Om `väg` ligger i eller är `mapp`, oavsett skepnad.
    nonisolated static func ligger(_ väg: String, i mapp: URL) -> Bool {
        let v = kanonisk(väg), m = kanonisk(mapp.path)
        return v == m || v.hasPrefix(m + "/")
    }

    /// Tar bort tecken som inte hör hemma i ett filnamn men behåller å ä ö.
    nonisolated func städa(_ s: String) -> String {
        let otillåtna = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: otillåtna).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func skrivOmSaknas(_ url: URL, _ innehåll: String) throws {
        guard !fm.fileExists(atPath: url.path) else { return }
        try innehåll.write(to: url, atomically: true, encoding: .utf8)
    }

    private func kundöversikt(_ namn: String) -> String {
        """
        ---
        typ: kund
        ---

        # \(namn)

        ## Projekt

        ## Kontakter

        ## Anteckningar

        """
    }

    private func projektöversikt(_ namn: String, kund: String) -> String {
        """
        ---
        typ: projekt
        kund: "\(kund)"
        ---

        # \(namn)

        [[\(kund)]]

        ## Anteckningar

        """
    }
}

func formateraLängd(_ sekunder: Double) -> String {
    let s = Int(sekunder.rounded())
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%02d:%02d", s / 60, s % 60)
}

extension DateFormatter {
    static let mappnamn: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    static let bildnamn: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()
    static let kortdag: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "sv_SE")
        return f
    }()
    static let dag: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        f.locale = Locale(identifier: "sv_SE")
        return f
    }()
    static let timme: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let klocka: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        f.locale = Locale(identifier: "sv_SE")
        return f
    }()
}

/// ISO 8601 med sekundbråk.
///
/// Utan bråkdelarna får två saker sparade inom samma sekund identiska
/// tidsstämplar, och då blir sorteringen på tid godtycklig — två samtal i rad
/// kunde hamna i vilken ordning som helst.
private let isoMedBråk: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoUtanBråk = ISO8601DateFormatter()

extension JSONEncoder {
    static let kundkoll: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { datum, kodare in
            var c = kodare.singleValueContainer()
            try c.encode(isoMedBråk.string(from: datum))
        }
        return e
    }()
}

extension JSONDecoder {
    static let kundkoll: JSONDecoder = {
        let d = JSONDecoder()
        // Läser båda formen: filer sparade innan bråkdelarna infördes har
        // fortfarande bara sekunder.
        d.dateDecodingStrategy = .custom { avkodare in
            let text = try avkodare.singleValueContainer().decode(String.self)
            if let datum = isoMedBråk.date(from: text) { return datum }
            if let datum = isoUtanBråk.date(from: text) { return datum }
            throw DecodingError.dataCorrupted(.init(
                codingPath: avkodare.codingPath,
                debugDescription: "Kunde inte tolka datumet \(text)"))
        }
        return d
    }()
}

// MARK: - Cache för möte.json

/// Avkodade möte.json, nycklade på sökväg med ändringstid och storlek.
///
/// En möte.json bär hela transkriptet, ofta hundratals kilobyte. Utan cache
/// avkodades varje fil vid varje listning — och ⌘K listade alla kunders
/// möten på en gång, på huvudtråden. Nyckeln är filens ändringstid och
/// storlek, så en fil som skrivits om läses om, och en oläslig fil kommer
/// ihåg att den är det.
final class Inspelningscache: @unchecked Sendable {
    private let lås = NSLock()
    private var poster: [String: (ändrad: Date, storlek: Int, inspelning: Inspelning?)] = [:]

    /// Inspelningen i filen, eller nil om den saknas eller inte går att läsa.
    func läs(_ json: URL) -> Inspelning? {
        guard let värden = try? json.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let ändrad = värden.contentModificationDate else { return nil }
        let storlek = värden.fileSize ?? 0
        lås.lock()
        if let p = poster[json.path], p.ändrad == ändrad, p.storlek == storlek {
            lås.unlock()
            return p.inspelning
        }
        lås.unlock()
        let i = (try? Data(contentsOf: json))
            .flatMap { try? JSONDecoder.kundkoll.decode(Inspelning.self, from: $0) }
        lås.lock()
        poster[json.path] = (ändrad, storlek, i)
        lås.unlock()
        return i
    }

    /// Fyller på direkt efter en egen skrivning, så att nästa listning
    /// slipper avkoda det som just skrevs.
    func sätt(_ json: URL, till inspelning: Inspelning) {
        guard let värden = try? json.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let ändrad = värden.contentModificationDate else { return }
        lås.lock()
        poster[json.path] = (ändrad, värden.fileSize ?? 0, inspelning)
        lås.unlock()
    }

    func glöm(_ json: URL) {
        lås.lock()
        poster[json.path] = nil
        lås.unlock()
    }

    func glömAllt() {
        lås.lock()
        poster.removeAll()
        lås.unlock()
    }
}

// MARK: - Byta namn, ta bort, flytta

/// Kunder, projekt och inspelningar nycklas på sina namn på flera ställen:
/// inspelningens `kund` och `projekt`, uppgifternas källsökvägar, noterna,
/// mejlstämpeln, uret och Obsidians valvlista. Ett namnbyte i Finder gjorde
/// tidigare allt det föräldralöst i tysthet. Här görs bytet i appen, och
/// allt som hänger på namnet skrivs om.
extension Arkivet {

    /// Byter namn på en kund.
    @discardableResult
    func döpOm(kund: Kund, till nyttNamn: String) throws -> Kund {
        let namn = städa(nyttNamn)
        guard !namn.isEmpty, namn != kund.namn else { return kund }
        let nyMapp = rot.appending(path: namn)
        guard !fm.fileExists(atPath: nyMapp.path) else {
            throw Enkeltfel("Det finns redan en kund som heter \(namn).")
        }
        try fm.moveItem(at: kund.mapp, to: nyMapp)
        let ny = Kund(namn: namn, mapp: nyMapp)
        cache.glömAllt()

        // Ingångsnoten heter som kunden.
        flyttaNot(i: nyMapp, från: kund.namn, till: namn)

        // Inspelningarna bär kundens namn, och deras markdown likaså.
        for (i, mapp) in inspelningar(för: ny) {
            var u = i
            u.kund = namn
            try? spara(u, i: mapp)
        }
        // Uppgifternas källor är sökvägar in i kundmappen.
        try sparaUppgifter(uppgifter(för: ny).map { u in
            var u = u
            u.källa = flyttadVäg(u.källa, från: kund.mapp, till: nyMapp)
            return u
        }, för: ny)
        // Kontaktnoter, mejlnot och tidslogg bär kundens namn i sin text.
        try? sparaKontakter(kontakter(för: ny), för: ny)
        if var mail = mailcache(för: ny) {
            mail.bilagor = mail.bilagor.map { b in
                var b = b
                b.fil = flyttadVäg(b.fil, från: kund.mapp, till: nyMapp) ?? b.fil
                return b
            }
            try? skrivMailcache(mail, för: ny)
        }
        try? sparaTidsposter(tidsposter(för: ny), för: ny)
        // Indexet bär gamla sökvägar och byggs om vid nästa tillfälle.
        glömIndex(hos: ny)

        Uppgiftssamling.flyttaStämpel(från: kund.namn, till: namn)
        Tidur.delad.byt(kund: kund.namn, till: namn)
        Obsidian.byt(valv: kund.mapp, till: nyMapp)
        läsOm()
        sparningar += 1
        return ny
    }

    /// Flyttar kunden med allt innehåll till papperskorgen.
    func taBort(kund: Kund) throws {
        try fm.trashItem(at: kund.mapp, resultingItemURL: nil)
        cache.glömAllt()
        Uppgiftssamling.glömStämpel(för: kund.namn)
        Obsidian.avregistrera(valv: kund.mapp)
        läsOm()
        sparningar += 1
    }

    /// Byter namn på ett projekt.
    @discardableResult
    func döpOm(projekt: Projekt, hos kund: Kund, till nyttNamn: String) throws -> Projekt {
        let namn = städa(nyttNamn)
        guard !namn.isEmpty, namn != projekt.namn else { return projekt }
        let nyMapp = kund.projektmapp.appending(path: namn)
        guard !fm.fileExists(atPath: nyMapp.path) else {
            throw Enkeltfel("Det finns redan ett projekt som heter \(namn).")
        }
        try fm.moveItem(at: projekt.mapp, to: nyMapp)
        let nytt = Projekt(namn: namn, mapp: nyMapp, kundnamn: kund.namn)
        cache.glömAllt()

        flyttaNot(i: nyMapp, från: projekt.namn, till: namn)

        for (i, mapp) in inspelningar(för: kund)
        where Self.ligger(mapp.path, i: nyMapp) {
            var u = i
            u.projekt = namn
            try? spara(u, i: mapp)
        }
        try sparaUppgifter(uppgifter(för: kund).map { u in
            var u = u
            if u.projekt == projekt.namn { u.projekt = namn }
            u.källa = flyttadVäg(u.källa, från: projekt.mapp, till: nyMapp)
            return u
        }, för: kund)
        try? sparaTidsposter(tidsposter(för: kund).map { t in
            var t = t
            if t.projekt == projekt.namn { t.projekt = namn }
            return t
        }, för: kund)
        var kopplingar = möteskopplingar(för: kund)
        for (id, p) in kopplingar where p == projekt.namn { kopplingar[id] = namn }
        try? skrivMöteskopplingar(kopplingar, för: kund)
        for s in allaSamtal(hos: kund) where s.projekt == projekt.namn {
            var s = s
            s.projekt = namn
            try? skriv(samtal: s, för: kund)
        }
        // Lägesbilden nycklas på projektets namn.
        let gammalBild = kund.mapp.appending(path: ".kundkoll/läget-\(projekt.namn.replacingOccurrences(of: "/", with: "-")).json")
        let nyBild = kund.mapp.appending(path: ".kundkoll/läget-\(namn.replacingOccurrences(of: "/", with: "-")).json")
        if fm.fileExists(atPath: gammalBild.path) { try? fm.moveItem(at: gammalBild, to: nyBild) }
        glömIndex(hos: kund)

        Tidur.delad.byt(projekt: projekt.namn, till: namn, hos: kund.namn)
        sparningar += 1
        return nytt
    }

    /// Flyttar projektet med inspelningar och anteckningar till
    /// papperskorgen. Uppgifterna hör till kunden och blir kvar, utan
    /// projekt.
    func taBort(projekt: Projekt, hos kund: Kund) throws {
        try fm.trashItem(at: projekt.mapp, resultingItemURL: nil)
        cache.glömAllt()
        try? sparaUppgifter(uppgifter(för: kund).map { u in
            var u = u
            if u.projekt == projekt.namn { u.projekt = nil }
            return u
        }, för: kund)
        try? sparaTidsposter(tidsposter(för: kund).map { t in
            var t = t
            if t.projekt == projekt.namn { t.projekt = nil }
            return t
        }, för: kund)
        var kopplingar = möteskopplingar(för: kund)
        for (id, p) in kopplingar where p == projekt.namn { kopplingar[id] = "" }
        try? skrivMöteskopplingar(kopplingar, för: kund)
        let bild = kund.mapp.appending(path: ".kundkoll/läget-\(projekt.namn.replacingOccurrences(of: "/", with: "-")).json")
        try? fm.removeItem(at: bild)
        glömIndex(hos: kund)
        sparningar += 1
    }

    /// Byter titel på en inspelning. Mappen döps om med titeln, och
    /// uppgifterna som kom ur mötet följer med.
    @discardableResult
    func döpOm(_ inspelning: Inspelning, i mapp: URL, till nyTitel: String,
               hos kund: Kund) throws -> (Inspelning, URL) {
        let titel = nyTitel.trimmingCharacters(in: .whitespaces)
        guard !titel.isEmpty, titel != inspelning.titel else { return (inspelning, mapp) }
        let stämpel = DateFormatter.mappnamn.string(from: inspelning.inledd)
        let rot = mapp.deletingLastPathComponent()
        var nyMapp = rot.appending(path: "\(stämpel) \(städa(titel))")
        var n = 2
        while fm.fileExists(atPath: nyMapp.path) && nyMapp != mapp {
            nyMapp = rot.appending(path: "\(stämpel) \(städa(titel)) \(n)")
            n += 1
        }
        if nyMapp != mapp { try fm.moveItem(at: mapp, to: nyMapp) }
        cache.glöm(mapp.appending(path: "möte.json"))
        var ny = inspelning
        ny.titel = titel
        try spara(ny, i: nyMapp)

        var ändrat = false
        let uppdaterade = uppgifter(för: kund).map { u -> Uppgift in
            guard Uppgiftssamling.hör(u, till: mapp, titel: inspelning.titel) else { return u }
            var u = u
            u.källa = nyMapp.path
            u.källtitel = titel
            ändrat = true
            return u
        }
        if ändrat { try sparaUppgifter(uppdaterade, för: kund) }
        glömIndex(hos: kund)
        return (ny, nyMapp)
    }

    /// Flyttar en inspelning till kundnivån eller ett projekt, hos samma
    /// eller en annan kund. Uppgifterna som kom ur mötet och mötets chattar
    /// följer med.
    @discardableResult
    func flytta(_ inspelning: Inspelning, från mapp: URL, till placering: Placering,
                hos kund: Kund) throws -> (Inspelning, URL) {
        let målrot = placering.inspelningsrot
        try fm.createDirectory(at: målrot, withIntermediateDirectories: true)
        var nyMapp = målrot.appending(path: mapp.lastPathComponent)
        guard nyMapp != mapp else { return (inspelning, mapp) }
        var n = 2
        while fm.fileExists(atPath: nyMapp.path) {
            nyMapp = målrot.appending(path: "\(mapp.lastPathComponent) \(n)")
            n += 1
        }
        try fm.moveItem(at: mapp, to: nyMapp)
        cache.glöm(mapp.appending(path: "möte.json"))

        var ny = inspelning
        ny.kund = placering.kundnamn
        ny.projekt = { if case .projekt(let p) = placering { p.namn } else { nil } }()
        try spara(ny, i: nyMapp)

        guard let målkund = kunder.first(where: { $0.namn == placering.kundnamn }) else {
            return (ny, nyMapp)
        }
        // Uppgifterna som kom ur mötet.
        let alla = uppgifter(för: kund)
        var flyttade: [Uppgift] = []
        var kvar: [Uppgift] = []
        for u in alla {
            if Uppgiftssamling.hör(u, till: mapp, titel: inspelning.titel) {
                var u = u
                u.källa = nyMapp.path
                u.projekt = ny.projekt
                flyttade.append(u)
            } else {
                kvar.append(u)
            }
        }
        if !flyttade.isEmpty {
            if målkund == kund {
                try sparaUppgifter(kvar + flyttade, för: kund)
            } else {
                try sparaUppgifter(kvar, för: kund)
                try sparaUppgifter(uppgifter(för: målkund) + flyttade, för: målkund)
            }
        }
        // Mötets chattar hör till mötet, inte till kunden.
        if målkund != kund {
            for s in allaSamtal(hos: kund) where s.möte == inspelning.id.uuidString {
                try? skriv(samtal: s, för: målkund)
                try? taBort(s, för: kund)
            }
            glömIndex(hos: målkund)
        }
        glömIndex(hos: kund)
        return (ny, nyMapp)
    }

    // MARK: Småsaker

    /// Ingångsnoten «Kund.md» eller «Projekt.md» följer med namnet.
    private func flyttaNot(i mapp: URL, från gammalt: String, till nytt: String) {
        let gammal = mapp.appending(path: "\(gammalt).md")
        let ny = mapp.appending(path: "\(nytt).md")
        guard fm.fileExists(atPath: gammal.path), !fm.fileExists(atPath: ny.path) else { return }
        try? fm.moveItem(at: gammal, to: ny)
    }

    /// Byter ut sökvägens början när en mapp flyttat.
    private func flyttadVäg(_ väg: String?, från gammal: URL, till ny: URL) -> String? {
        guard let väg else { return nil }
        let v = Self.kanonisk(väg), g = Self.kanonisk(gammal.path)
        guard v == g || v.hasPrefix(g + "/") else { return väg }
        return Self.kanonisk(ny.path) + v.dropFirst(g.count)
    }

    /// Indexet är härlett och bär sökvägar; efter en flytt byggs det om.
    private func glömIndex(hos kund: Kund) {
        let mapp = kund.mapp.appending(path: ".kundkoll")
        for namn in ["index.db", "index.db-journal", "index.db-wal", "index.db-shm"] {
            try? fm.removeItem(at: mapp.appending(path: namn))
        }
    }

    /// Alla samtal hos kunden, oavsett projekt och möte.
    private func allaSamtal(hos kund: Kund) -> [Samtal] {
        let mapp = kund.mapp.appending(path: ".kundkoll/samtal")
        guard let filer = try? fm.contentsOfDirectory(
            at: mapp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return filer.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.kundkoll.decode(Samtal.self, from: $0) }
        }
    }

    /// Skriver ett samtal utan att röra dess tid — en flytt är ingen ändring.
    private func skriv(samtal: Samtal, för kund: Kund) throws {
        let mapp = kund.mapp.appending(path: ".kundkoll/samtal")
        try fm.createDirectory(at: mapp, withIntermediateDirectories: true)
        let data = try JSONEncoder.kundkoll.encode(samtal)
        try data.write(to: mapp.appending(path: "\(samtal.id.uuidString).json"), options: .atomic)
    }
}
