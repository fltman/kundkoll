import Foundation

/// Samlar in uppgifter från det material som kommer in.
///
/// Möten bidrar med sina åtaganden direkt, eftersom sammanfattningen redan
/// plockat ut dem. Mejl och anteckningar går genom en egen runda.
@MainActor
enum Uppgiftssamling {

    /// Mötets åtaganden till tavlan.
    static func frånMöte(_ sammanfattning: Mötessammanfattning,
                         inspelning: Inspelning, mapp: URL?) {
        guard let kund = Arkivet.shared.kunder.first(where: { $0.namn == inspelning.kund })
        else { return }
        let nya = sammanfattning.åtaganden.map {
            Uppgift(vad: $0.vad, vem: $0.vem, när: $0.när, senast: $0.senast,
                    läge: $0.klart ? .klart : .attGöra,
                    ursprung: .möte,
                    källa: mapp?.path,
                    källtitel: inspelning.titel,
                    projekt: inspelning.projekt,
                    skapad: inspelning.inledd)
        }
        try? Arkivet.shared.läggTill(nya, för: kund)
    }

    /// Om en uppgift kom ur ett visst möte. Mappen är det säkra kännetecknet;
    /// titeln finns kvar för uppgifter som lades upp innan mappen sparades.
    static func hör(_ uppgift: Uppgift, till mapp: URL, titel: String) -> Bool {
        guard uppgift.ursprung == .möte else { return false }
        if let källa = uppgift.källa {
            return källa == mapp.path || Arkivet.kanonisk(källa) == Arkivet.kanonisk(mapp.path)
        }
        return uppgift.källtitel == titel
    }

    /// Letar åtaganden i nyhämtade mejl.
    ///
    /// Bara de senaste och bara de som kommit efter förra genomgången: varje
    /// runda kostar ett modellanrop, och gamla mejl har redan gåtts igenom.
    static func frånMejl(_ mejl: [Mailen.Mejl], kund: Kund) async {
        guard Inställningar.automatiskaModellanrop else { return }
        let sedan = senastGenomgången(kund)
        // Äldst först: stämpeln flyttas bara fram över mejl som faktiskt
        // gåtts igenom. Tidigare flyttades den även när alla anrop föll —
        // utan nyckel, med modellen nere — och de mejlen lästes aldrig igen.
        let nya = Array(mejl
            .filter { ($0.datum ?? .distantPast) > sedan }
            .filter { !$0.text.isEmpty }
            .sorted { ($0.datum ?? .distantPast) < ($1.datum ?? .distantPast) }
            .prefix(10))
        guard !nya.isEmpty else { return }

        let letare = Uppgiftsletare()
        var funna: [Uppgift] = []
        var genomgångnaTill: Date?
        for m in nya {
            let text = "Ämne: \(m.ämne)\nFrån: \(m.avsändarnamn)\n\n\(m.text)"
            guard let u = try? await letare.leta(
                i: text,
                sammanhang: m.skickat ? "ett mejl jag skickat" : "ett mejl jag fått",
                kund: kund.namn,
                datum: m.datum ?? Date()) else { break }
            funna += u.map {
                Uppgift(vad: $0.vad, vem: $0.vem, när: $0.när, senast: $0.senast,
                        ursprung: .mejl, källtitel: m.ämne, skapad: m.datum ?? Date())
            }
            genomgångnaTill = m.datum ?? genomgångnaTill
        }
        if !funna.isEmpty { try? Arkivet.shared.läggTill(funna, för: kund) }
        if let till = genomgångnaTill { märkGenomgången(kund, till: till) }
    }

    /// Vilka mejl som ska gås igenom, och i vilken ordning. Utbrutet för att
    /// kunna provas: äldst först, bara de efter stämpeln, bara de med text.
    static func attGåIgenom(_ mejl: [Mailen.Mejl], sedan: Date, max antal: Int = 10) -> [Mailen.Mejl] {
        Array(mejl
            .filter { ($0.datum ?? .distantPast) > sedan }
            .filter { !$0.text.isEmpty }
            .sorted { ($0.datum ?? .distantPast) < ($1.datum ?? .distantPast) }
            .prefix(antal))
    }

    /// Fram till hit har mejlen redan gåtts igenom.
    private static func senastGenomgången(_ kund: Kund) -> Date {
        guard let t = UserDefaults.standard.object(forKey: nyckel(kund.namn)) as? Date else {
            // Första gången: bara den senaste månaden, annars går hela
            // mejlhistoriken genom modellen.
            return Date().addingTimeInterval(-30 * 24 * 3600)
        }
        return t
    }

    private static func märkGenomgången(_ kund: Kund, till tid: Date) {
        UserDefaults.standard.set(tid, forKey: nyckel(kund.namn))
    }

    private static func nyckel(_ kundnamn: String) -> String { "kundkoll.uppgifter.\(kundnamn)" }

    /// Stämpeln nycklas på kundens namn och följer med när namnet byts —
    /// annars gick en månads mejl genom modellen en gång till.
    static func flyttaStämpel(från gammalt: String, till nytt: String) {
        guard let t = UserDefaults.standard.object(forKey: nyckel(gammalt)) else { return }
        UserDefaults.standard.set(t, forKey: nyckel(nytt))
        UserDefaults.standard.removeObject(forKey: nyckel(gammalt))
    }

    static func glömStämpel(för kundnamn: String) {
        UserDefaults.standard.removeObject(forKey: nyckel(kundnamn))
    }
}
