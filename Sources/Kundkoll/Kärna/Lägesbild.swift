import Foundation

/// Var projektet står just nu, skrivet av chattens modell ur det som finns:
/// uppgifterna på tavlan, mötenas sammanfattningar, mejlen och anteckningarna.
///
/// Skrivs en gång och cachas — sedan bara när underlaget har ändrats. Den
/// sparas också som `Läget.md` i projektmappen, så att samma bild syns i
/// Obsidian.
struct Lägesbild: Codable {
    var text: String
    var skriven = Date()

    init(text: String, skriven: Date = Date()) {
        self.text = text
        self.skriven = skriven
    }

    /// Skriven för hand: se `Inspelning`.
    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        skriven = try c.decodeIfPresent(Date.self, forKey: .skriven) ?? Date()
    }
}

@MainActor
enum Läget {

    private static func fil(_ kund: Kund, _ projekt: Projekt) -> URL {
        let namn = projekt.namn.replacingOccurrences(of: "/", with: "-")
        return kund.mapp.appending(path: ".kundkoll/läget-\(namn).json")
    }

    static func läs(kund: Kund, projekt: Projekt) -> Lägesbild? {
        guard let data = try? Data(contentsOf: fil(kund, projekt)) else { return nil }
        return try? JSONDecoder.kundkoll.decode(Lägesbild.self, from: data)
    }

    /// När det senaste underlaget kom — har något hänt efter att lägesbilden
    /// skrevs är den gammal.
    static func senasteUnderlag(kund: Kund, projekt: Projekt,
                                arkiv: Arkivet = .shared) -> Date? {
        var tider: [Date] = []
        tider += arkiv.inspelningar(för: kund)
            .filter { $0.0.projekt == projekt.namn }
            .map { $0.0.sammanfattning?.skriven ?? $0.0.inledd }
        tider += arkiv.uppgifter(för: kund)
            .filter { $0.projekt == projekt.namn }
            .map(\.ändrad)
        tider += (arkiv.mailcache(för: kund)?.mejl ?? []).compactMap(\.datum)
        tider += arkiv.anteckningar(i: projekt.anteckningsmapp).map(\.ändrad)
        return tider.max()
    }

    static func gammal(_ bild: Lägesbild, kund: Kund, projekt: Projekt,
                       arkiv: Arkivet = .shared) -> Bool {
        guard let senaste = senasteUnderlag(kund: kund, projekt: projekt, arkiv: arkiv)
        else { return false }
        return bild.skriven < senaste
    }

    /// Skriver en ny lägesbild och sparar den.
    static func skriv(kund: Kund, projekt: Projekt,
                      arkiv: Arkivet = .shared) async throws -> Lägesbild {
        let träffar = underlag(
            projekt: projekt.namn,
            inspelningar: arkiv.inspelningar(för: kund).map(\.0),
            uppgifter: arkiv.uppgifter(för: kund),
            mejl: arkiv.mailcache(för: kund)?.mejl ?? [],
            anteckningar: arkiv.anteckningar(i: projekt.anteckningsmapp))
        guard !träffar.isEmpty else {
            throw Enkeltfel("Det finns inget underlag att bygga en lägesbild på än.")
        }

        let uppdrag = """
        Skriv en lägesbild för projektet \(projekt.namn) hos \(kund.namn), \
        som den ser ut just nu. Börja med ett kort stycke om var projektet \
        står. Fortsätt sedan med rubrikerna **Närmast**, **Väntar på** och \
        **Risker** som punktlistor — men bara de rubriker där underlaget \
        faktiskt säger något. Kort och konkret, på svenska, utan hänvisningar \
        i hakparentes och utan artigheter. Bygg enbart på underlaget.
        """
        let svar = try await Chatt().fråga(uppdrag, om: kund.namn, projekt: projekt.namn,
                                           träffar: träffar, historik: [])
        let bild = Lägesbild(text: svar.text)

        let data = try JSONEncoder.kundkoll.encode(bild)
        try FileManager.default.createDirectory(
            at: kund.mapp.appending(path: ".kundkoll"), withIntermediateDirectories: true)
        try data.write(to: fil(kund, projekt), options: .atomic)

        // Samma bild i Obsidian.
        let md = """
        ---
        typ: läget
        projekt: "\(projekt.namn)"
        kund: "\(kund.namn)"
        skriven: \(DateFormatter.iso.string(from: bild.skriven))
        ---

        # Läget · \(projekt.namn)

        \(bild.text)

        ---
        Skriven av \(Appnamn.visat) ur uppgifter, möten och mejl. Skrivs om när \
        underlaget ändras — redigera inte här.
        """
        try? md.write(to: projekt.mapp.appending(path: "Läget.md"),
                      atomically: true, encoding: .utf8)
        return bild
    }

    /// Underlaget som källor åt modellen. Utbrutet för att kunna provas.
    static func underlag(projekt: String,
                         inspelningar: [Inspelning],
                         uppgifter: [Uppgift],
                         mejl: [Mailen.Mejl],
                         anteckningar: [Anteckning]) -> [Kunskapsbank.Träff] {
        var ut: [Kunskapsbank.Träff] = []
        var id: Int64 = 0
        func lägg(_ typ: String, _ titel: String, _ text: String, _ tid: Date?) {
            id += 1
            ut.append(Kunskapsbank.Träff(id: id, typ: typ, titel: titel,
                                         text: text, källa: "", tid: tid, poäng: 0))
        }

        // De tre senaste mötena i projektet, sammanfattade.
        let möten = inspelningar
            .filter { $0.projekt == projekt }
            .sorted { $0.inledd > $1.inledd }
        for m in möten.prefix(3) {
            guard let s = m.sammanfattning else { continue }
            var text = s.kärna
            if !s.beslut.isEmpty { text += "\nBeslut: " + s.beslut.joined(separator: "; ") }
            if !s.öppet.isEmpty { text += "\nÖppet: " + s.öppet.joined(separator: "; ") }
            lägg("sammanfattning", "Mötet \(m.titel)", text, m.inledd)
        }

        // Tavlan: formellt kopplade uppgifter, och de som nämner projektet
        // vid namn — mejlens uppgifter får sällan projektet satt.
        let egna = uppgifter.filter {
            $0.projekt == projekt || $0.vad.localizedCaseInsensitiveContains(projekt)
        }
        if !egna.isEmpty {
            let rader = egna.map { u -> String in
                var rad = "• \(u.vad)"
                if let vem = u.vem { rad += " (\(vem))" }
                if let senast = u.senast {
                    rad += " — senast \(DateFormatter.kortdag.string(from: senast))"
                    if u.försenad { rad += ", FÖRSENAD" }
                }
                rad += u.läge == .klart ? " [klar]"
                    : u.läge == .pågår ? " [pågår]" : " [att göra]"
                return rad
            }
            lägg("anteckning", "Uppgifterna på tavlan", rader.joined(separator: "\n"), nil)
        }

        // Mejlen är kundens, inte projektets. De som nämner projektet vid
        // namn går först; resten fyller på med det senaste.
        let sorterade = mejl.sorted { ($0.datum ?? .distantPast) > ($1.datum ?? .distantPast) }
        let nämner = sorterade.filter {
            $0.ämne.localizedCaseInsensitiveContains(projekt)
                || $0.text.localizedCaseInsensitiveContains(projekt)
        }
        let övriga = sorterade.filter { m in !nämner.contains(where: { $0.id == m.id }) }
        for m in (nämner.prefix(5) + övriga.prefix(3)) {
            let huvud = "\(m.skickat ? "Skickat" : "Mottaget") \(m.ämne)"
            lägg("mejl", huvud, String(m.text.prefix(400)), m.datum)
        }

        for a in anteckningar.sorted(by: { $0.ändrad > $1.ändrad }).prefix(3) {
            lägg("anteckning", a.titel, String(a.text.prefix(400)), a.ändrad)
        }
        return ut
    }
}
