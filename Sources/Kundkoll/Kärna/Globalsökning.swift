import Foundation

/// Söker i alla kunders material på en gång.
///
/// Kunskapsbanken finns per kund, men man vet inte alltid vilken kund något
/// sades hos — det är ofta därför man söker. Varje kunds index frågas var för
/// sig och träffarna vägs ihop.
enum Globalsökning {

    struct Träff: Identifiable {
        var id: String { "\(kund.id)-\(inre.id)" }
        var kund: Kund
        var inre: Kunskapsbank.Träff
    }

    /// Söker och ger träffarna grupperade per kund, bästa kunden först.
    static func sök(_ fråga: String, i kunder: [Kund], perKund: Int = 5) -> [(Kund, [Träff])] {
        guard !Kunskapsbank.sökuttryck(fråga).isEmpty else { return [] }

        var ut: [(Kund, [Träff])] = []
        for kund in kunder {
            // Kunder utan index hoppas över i stället för att byggas här:
            // sökningen ska vara snabb, och indexet byggs när chatten öppnas.
            let indexfil = kund.mapp.appending(path: ".kundkoll/index.db")
            guard FileManager.default.fileExists(atPath: indexfil.path),
                  let bank = try? Kunskapsbank(kund: kund) else { continue }
            let träffar = bank.sök(fråga, max: perKund)
                .map { Träff(kund: kund, inre: $0) }
            if !träffar.isEmpty { ut.append((kund, träffar)) }
        }
        // BM25 är negativ och lägre är bättre; kunden med bästa enskilda träff
        // hamnar överst.
        return ut.sorted {
            ($0.1.first?.inre.poäng ?? 0) < ($1.1.first?.inre.poäng ?? 0)
        }
    }
}
