import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Uppgifterna hos en kund, i tre spalter.
///
/// Korten kommer från möten och mejl utan att någon skriver in dem: mötets
/// åtaganden plockas ur sammanfattningen, mejlens ur texten när de hämtas.
struct Kanbanvy: View {
    let kund: Kund
    /// Sätts för att bara visa uppgifter som hör till ett projekt.
    var projekt: Projekt?

    @EnvironmentObject private var arkiv: Arkivet
    @State private var uppgifter: [Uppgift] = []
    @State private var kontakter: [Kontakt] = []
    @State private var ny = ""
    /// Spalten kortet just nu hålls över, för att visa var det landar.
    @State private var mål: Uppgift.Läge?
    @State private var redigerad: Uppgift?
    @State private var attTaBort: Uppgift?
    /// Vems kort som visas: tomt är alla, `utanPerson` de som saknar någon.
    /// Sparas per kund, så att valet överlever ett flikbyte.
    @AppStorage private var person: String
    static let utanPerson = "∅"

    init(kund: Kund, projekt: Projekt? = nil) {
        self.kund = kund
        self.projekt = projekt
        _person = AppStorage(wrappedValue: "", "kundkoll.tavla.person.\(kund.namn)")
    }

    /// Projektets kort, om ett projekt är valt.
    private var projektets: [Uppgift] {
        guard let projekt else { return uppgifter }
        return uppgifter.filter { $0.projekt == projekt.namn }
    }

    private var synliga: [Uppgift] {
        switch person {
        case "": return projektets
        case Self.utanPerson: return projektets.filter { Self.personer(i: $0.vem, kontakter: kontakter).isEmpty }
        default: return projektets.filter {
            Self.personer(i: $0.vem, kontakter: kontakter).contains { $0.nyckel == person }
        }
        }
    }

    /// Personerna på tavlan med antal öppna kort, i bokstavsordning.
    private var personer: [(nyckel: String, namn: String, antal: Int)] {
        var antal: [String: Int] = [:]
        var namn: [String: String] = [:]
        for u in projektets where u.läge != .klart {
            for p in Self.personer(i: u.vem, kontakter: kontakter) {
                antal[p.nyckel, default: 0] += 1
                namn[p.nyckel] = p.namn
            }
        }
        return antal.keys
            .sorted { (namn[$0] ?? $0).localizedStandardCompare(namn[$1] ?? $1) == .orderedAscending }
            .map { (nyckel: $0, namn: namn[$0] ?? $0, antal: antal[$0] ?? 0) }
    }

    private var utanPersonAntal: Int {
        projektets.filter { $0.läge != .klart && Self.personer(i: $0.vem, kontakter: kontakter).isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Avsnittsrubrik("Att göra")
                Spacer()
                personfilter
                if Obsidian.finns {
                    Button("Öppna i Obsidian") {
                        Obsidian.öppna(kund.mapp.appending(path: "Att göra.md"),
                                       valvrot: kund.mapp)
                    }
                    .buttonStyle(.link)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(Uppgift.Läge.allCases) { läge in
                    spalt(läge)
                }
            }

            HStack(spacing: 8) {
                TextField("Lägg till något att göra", text: $ny)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(läggTill)
                Button("Lägg till", action: läggTill)
                    .disabled(ny.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: läsOm)
        .sheet(item: $redigerad) { u in
            Uppgiftsredigering(uppgift: u, kund: kund,
                               projekt: projekt == nil ? arkiv.projekt(för: kund) : [],
                               vidSparat: läsOm)
        }
        .confirmationDialog(
            "Ta bort uppgiften?",
            isPresented: Binding(get: { attTaBort != nil }, set: { if !$0 { attTaBort = nil } }),
            presenting: attTaBort
        ) { u in
            Button("Ta bort", role: .destructive) {
                try? arkiv.taBort(u, för: kund)
                attTaBort = nil
                läsOm()
            }
            Button("Avbryt", role: .cancel) { attTaBort = nil }
        } message: { u in
            Text("«\(u.vad)» tas bort från tavlan. Det går inte att ångra.")
        }
    }

    /// Vems kort. Namnen kommer ur korten själva, så listan är aldrig tom
    /// på någon som inte har något att göra.
    private var personfilter: some View {
        Picker("Person", selection: $person) {
            Text("Alla").tag("")
            if !personer.isEmpty { Divider() }
            ForEach(personer, id: \.nyckel) { p in
                Text("\(p.namn) · \(p.antal)").tag(p.nyckel)
            }
            if utanPersonAntal > 0 {
                Divider()
                Text("Utan person · \(utanPersonAntal)").tag(Self.utanPerson)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Visa bara kort som hör till en person")
    }

    private func spalt(_ läge: Uppgift.Läge) -> some View {
        let ivarje = synliga.filter { $0.läge == läge }
            .sorted { $0.skapad > $1.skapad }
        return LazyVStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(läge.namn).font(.subheadline.weight(.semibold))
                Text("\(ivarje.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(ivarje) { u in kort(u) }
            Spacer(minLength: 0)
        }
        // Spalterna är lika höga. En tom spalt som bara var så hög som sin
        // rubrik gav en centimeter att sikta på, och då gick korten inte att
        // flytta.
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(mål == läge ? 0.7 : 0.3), in: .rect(cornerRadius: 10))
        // Släpp ett kort i spalten för att flytta det dit.
        .dropDestination(for: String.self) { id, _ in
            flytta(id.first, till: läge)
        } isTargeted: { över in
            mål = över ? läge : (mål == läge ? nil : mål)
        }
    }

    private func flytta(_ id: String?, till läge: Uppgift.Läge) -> Bool {
        guard let id, let u = uppgifter.first(where: { $0.id.uuidString == id }),
              u.läge != läge else { return false }
        var flyttad = u
        flyttad.läge = läge
        try? arkiv.uppdatera(flyttad, för: kund)
        läsOm()
        return true
    }

    private func kort(_ u: Uppgift) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(u.vad)
                .font(.callout)
                .strikethrough(u.läge == .klart)
                .foregroundStyle(u.läge == .klart ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            if u.vem != nil || u.när != nil || u.senast != nil {
                HStack(spacing: 4) {
                    // Modellen skriver «Röst 1 (Andreas)»; kortet visar Andreas.
                    let namn = Self.personer(i: u.vem, kontakter: kontakter).map(\.namn)
                    if !namn.isEmpty {
                        Text(namn.joined(separator: ", "))
                    } else if let vem = u.vem {
                        Text(vem)
                    }
                    if let rad = närtext(u) {
                        if u.vem != nil { Text("·") }
                        Text(rad).foregroundStyle(u.försenad ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: u.ursprung.ikon).font(.system(size: 9))
                if let titel = u.källtitel {
                    Text(titel).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .kort(hörn: Stil.radhörn)
        .contentShape(.rect(cornerRadius: 8))
        .draggable(u.id.uuidString)
        .onTapGesture { redigerad = u }
        .contextMenu {
            ForEach(Uppgift.Läge.allCases) { läge in
                if läge != u.läge {
                    Button("Flytta till \(läge.namn)") {
                        var flyttad = u
                        flyttad.läge = läge
                        try? arkiv.uppdatera(flyttad, för: kund)
                        läsOm()
                    }
                }
            }
            Divider()
            Button("Ta bort …", role: .destructive) { attTaBort = u }
        }
    }

    private func läggTill() {
        let text = ny.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Står filtret på en person är det hens kort man lägger till —
        // annars skulle det nya kortet försvinna ur vyn direkt.
        let vem = personer.first { $0.nyckel == person }?.namn
        try? arkiv.läggTill([Uppgift(vad: text, vem: vem, projekt: projekt?.namn)], för: kund)
        ny = ""
        läsOm()
    }

    /// Datumet när det finns, annars orden som de föll — "före fredag" säger
    /// mer än ingenting.
    private func närtext(_ u: Uppgift) -> String? {
        u.senast.map { DateFormatter.kortdag.string(from: $0) } ?? u.när
    }

    private func läsOm() {
        uppgifter = arkiv.uppgifter(för: kund)
        kontakter = arkiv.kontakter(för: kund)
        // Ett sparat val på någon som inte längre har kort ska inte lämna en
        // tom tavla.
        if person != "", person != Self.utanPerson, !personer.contains(where: { $0.nyckel == person }) {
            person = ""
        }
        if person == Self.utanPerson, utanPersonAntal == 0 { person = "" }
    }

    // MARK: - Vem är vem på tavlan

    /// Personerna bakom ett «vem», i en form som går att jämföra.
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
        for del in text.components(separatedBy: Self.skiljare).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !del.isEmpty && !Self.ingenPerson.contains(del.lowercased()) {
            let p = person(del, kontakter: kontakter)
            if !ut.contains(where: { $0.nyckel == p.nyckel }) { ut.append(p) }
        }
        return ut
    }

    private static let skiljare: [String] = [" och ", " & ", ", ", "/", " and ", " + "]
    /// Ord modellen ibland sätter i stället för ett namn.
    private static let ingenPerson: Set<String> = ["null", "okänd", "okänt", "ingen", "alla", "vi", "-", "—"]

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

private extension String {
    func components(separatedBy skiljare: [String]) -> [String] {
        var delar = [self]
        for s in skiljare {
            delar = delar.flatMap { $0.components(separatedBy: s) }
        }
        return delar
    }
}
