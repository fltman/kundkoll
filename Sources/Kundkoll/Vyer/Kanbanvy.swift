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
        projektets.filter { Personer.matchar($0, kontakter: kontakter, person: person) }
    }

    private var sammanställning: Personer.Sammanställning {
        Personer.sammanställ(projektets.map { (uppgift: $0, kontakter: kontakter) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Avsnittsrubrik("Att göra")
                Spacer()
                Personfilter(sammanställning: sammanställning, person: $person)
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
                    let namn = Personer.personer(i: u.vem, kontakter: kontakter).map(\.namn)
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
        let vem = sammanställning.personer.first { $0.nyckel == person }?.namn
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
        if !sammanställning.gäller(person) { person = "" }
    }
}
