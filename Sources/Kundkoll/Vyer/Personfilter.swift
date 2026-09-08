import SwiftUI

/// Vem en uppgift hör till, i en form som går att jämföra — och menyn som
/// väljer bland dem. Delas av tavlan och Min vecka.
enum Personer {

    /// Filtervärdet för kort som saknar person.
    static let utanPerson = "∅"

    /// Personerna bakom ett «vem».
    ///
    /// Modellen skriver «Röst 1 (Andreas)», «Anders» och «Anders Bjarby» om
    /// samma personer, och ibland «Kristin och Anders» om två. Parentesen
    /// vinner över etiketten, flera namn delas upp, och kontaktlistan
    /// avgör resten: ett förnamn som bara passar en kontakt är den
    /// kontakten. Två kontakter med samma förnamn lämnas isär hellre än att
    /// slås ihop fel.
    static func personer(i vem: String?, kontakter: [Kontakt]) -> [(nyckel: String, namn: String)] {
        guard var text = vem?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return [] }
        if let a = text.firstIndex(of: "("),
           let b = text[a...].firstIndex(of: ")"), b > text.index(after: a) {
            let inuti = text[text.index(after: a)..<b].trimmingCharacters(in: .whitespaces)
            if !inuti.isEmpty { text = inuti }
        }
        var ut: [(nyckel: String, namn: String)] = []
        for del in dela(text).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !del.isEmpty && !ingenPerson.contains(del.lowercased()) {
            let p = person(del, kontakter: kontakter)
            if !ut.contains(where: { $0.nyckel == p.nyckel }) { ut.append(p) }
        }
        return ut
    }

    /// Om uppgiften ska visas med filtret satt till `person`.
    static func matchar(_ u: Uppgift, kontakter: [Kontakt], person: String) -> Bool {
        switch person {
        case "": return true
        case utanPerson: return personer(i: u.vem, kontakter: kontakter).isEmpty
        default: return personer(i: u.vem, kontakter: kontakter).contains { $0.nyckel == person }
        }
    }

    struct Sammanställning {
        var personer: [(nyckel: String, namn: String, antal: Int)] = []
        var utanPerson = 0
        /// Om ett sparat val fortfarande pekar på någon som har kort.
        func gäller(_ person: String) -> Bool {
            person == "" || (person == Personer.utanPerson ? utanPerson > 0
                             : personer.contains { $0.nyckel == person })
        }
    }

    /// Personerna bakom de öppna uppgifterna, med antal, i bokstavsordning.
    /// Kontakterna ges per uppgift, eftersom Min vecka spänner över kunder.
    static func sammanställ(_ rader: [(uppgift: Uppgift, kontakter: [Kontakt])]) -> Sammanställning {
        var antal: [String: Int] = [:]
        var namn: [String: String] = [:]
        var utan = 0
        for rad in rader where rad.uppgift.läge != .klart {
            let p = personer(i: rad.uppgift.vem, kontakter: rad.kontakter)
            if p.isEmpty { utan += 1 }
            for person in p {
                antal[person.nyckel, default: 0] += 1
                namn[person.nyckel] = person.namn
            }
        }
        let lista = antal.keys
            .sorted { (namn[$0] ?? $0).localizedStandardCompare(namn[$1] ?? $1) == .orderedAscending }
            .map { (nyckel: $0, namn: namn[$0] ?? $0, antal: antal[$0] ?? 0) }
        return Sammanställning(personer: lista, utanPerson: utan)
    }

    private static let skiljare = [" och ", " & ", ", ", "/", " and ", " + "]
    /// Ord modellen ibland sätter i stället för ett namn.
    private static let ingenPerson: Set<String> = ["null", "okänd", "okänt", "ingen", "alla", "vi", "-", "—"]

    private static func dela(_ text: String) -> [String] {
        var delar = [text]
        for s in skiljare { delar = delar.flatMap { $0.components(separatedBy: s) } }
        return delar
    }

    private static func person(_ rå: String, kontakter: [Kontakt]) -> (nyckel: String, namn: String) {
        let låg = rå.lowercased()
        if let k = kontakter.first(where: { $0.namn.lowercased() == låg }) {
            return (k.namn.lowercased(), k.namn)
        }
        let påFörnamn = kontakter.filter {
            $0.namn.lowercased().split(separator: " ").first.map(String.init) == låg
        }
        if påFörnamn.count == 1 { return (påFörnamn[0].namn.lowercased(), påFörnamn[0].namn) }
        return (låg, rå)
    }
}

/// Menyn: alla, var och en som har öppna kort med antal, och de utan person.
/// Namnen kommer ur korten själva, så listan är aldrig tom på någon som
/// inte har något att göra.
struct Personfilter: View {
    let sammanställning: Personer.Sammanställning
    @Binding var person: String

    var body: some View {
        Picker("Person", selection: $person) {
            Text("Alla").tag("")
            if !sammanställning.personer.isEmpty { Divider() }
            ForEach(sammanställning.personer, id: \.nyckel) { p in
                Text("\(p.namn) · \(p.antal)").tag(p.nyckel)
            }
            if sammanställning.utanPerson > 0 {
                Divider()
                Text("Utan person · \(sammanställning.utanPerson)").tag(Personer.utanPerson)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Visa bara kort som hör till en person")
    }
}
