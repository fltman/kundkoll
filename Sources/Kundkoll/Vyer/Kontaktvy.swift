import SwiftUI

/// Kundens kontaktlista. Personer kan hämtas ur macOS Kontakter eller skrivas
/// upp för hand — alla man talar med finns inte i adressboken.
struct Kontaktvy: View {
    let kund: Kund
    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var adressbok: Adressboken
    @Environment(\.dismiss) private var stäng

    @State private var kontakter: [Kontakt] = []
    @State private var lösaRöster: [Röstprofil] = []
    @State private var sökning = ""
    @State private var träffar: [Kontakt] = []
    @State private var nyttNamn = ""
    @State private var redigerar: Kontakt?
    @State private var attTaBort: Kontakt?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Kontakter hos \(kund.namn)").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()

            HSplitView {
                mina
                adressboken
            }

            Divider()
            HStack {
                Spacer()
                Button("Klar") { stäng() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kontakter.klar")
            }
            .padding(16)
        }
        .frame(width: 760, height: 520)
        .confirmationDialog(
            "Ta bort kontakten från kunden?",
            isPresented: Binding(get: { attTaBort != nil }, set: { if !$0 { attTaBort = nil } }),
            presenting: attTaBort
        ) { k in
            Button("Ta bort", role: .destructive) {
                try? arkiv.taBort(k, hos: kund)
                attTaBort = nil
                läsOm()
            }
            Button("Avbryt", role: .cancel) { attTaBort = nil }
        } message: { k in
            Text("\(k.namn) tas bort från \(kund.namn). Noten flyttas till papperskorgen; "
                 + "posten i macOS Kontakter rörs inte.")
        }
        .sheet(item: $redigerar) { k in
            Kontaktredigering(kund: kund, kontakt: k) { _ in läsOm() }
        }
        .onAppear {
            läsOm()
            if adressbok.harTillgång && kontakter.isEmpty {
                träffar = adressbok.hosOrganisation(kund.namn)
            }
        }
    }

    private var mina: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hos kunden")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)

            List {
                ForEach(kontakter) { k in
                    HStack {
                        Kontaktsigill(kontakt: k, kund: kund, sida: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.namn)
                            if let e = k.förstaEpost {
                                Text(e).font(.caption).foregroundStyle(.secondary)
                            } else if let r = k.roll {
                                Text(r).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if k.systemID != nil {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(.tertiary)
                                .help("Finns i macOS Kontakter")
                        }
                        Button {
                            attTaBort = k
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Ta bort från kunden")
                    }
                    .contentShape(.rect)
                    .onTapGesture { redigerar = k }
                }
            }
            .overlay {
                if kontakter.isEmpty {
                    Text("Inga än").foregroundStyle(.secondary)
                }
            }

            if !lösaRöster.isEmpty { rösterUtanKontakt }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Lägg till för hand", text: $nyttNamn)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(läggTillFörHand)
                    Button("Lägg till", action: läggTillFörHand)
                        .disabled(nyttNamn.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Klicka på en kontakt för att fylla i uppgifter eller lägga upp den i Kontakter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(minWidth: 300)
    }

    private var adressboken: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("macOS Kontakter")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)

            if !adressbok.harTillgång {
                VStack(spacing: 12) {
                    Text("\(Appnamn.visat) har inte tillgång till dina kontakter.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Ge tillgång") {
                        Task {
                            await adressbok.begärTillgång()
                            if adressbok.harTillgång {
                                träffar = adressbok.hosOrganisation(kund.namn)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                TextField("Sök", text: $sökning)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .onChange(of: sökning) {
                        träffar = sökning.isEmpty
                            ? adressbok.hosOrganisation(kund.namn)
                            : adressbok.sök(sökning)
                    }

                List {
                    ForEach(träffar) { k in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.namn)
                                if let e = k.förstaEpost {
                                    Text(e).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                kontakter = (try? arkiv.läggTill(k, hos: kund)) ?? kontakter
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(kontakter.contains { $0.systemID == k.systemID })
                        }
                    }
                }
                .overlay {
                    if träffar.isEmpty {
                        Text(sökning.isEmpty
                             ? "Ingen i adressboken hör till \(kund.namn)."
                             : "Inga träffar")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
        }
        .frame(minWidth: 300)
    }

    /// Röster som fått namn i «Vem är vem» men inte finns som kontakt — efter
    /// ett namnbyte på kontakten, eller ett namn skrivet på ett annat sätt.
    /// De kan kopplas till en kontakt, så att avtrycken följer med dit, eller
    /// glömmas.
    private var rösterUtanKontakt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Röster utan kontakt")
                .font(.subheadline.weight(.medium))
                .padding(.top, 6)
            ForEach(lösaRöster) { p in
                HStack(spacing: 8) {
                    Image(systemName: "person.wave.2").foregroundStyle(.secondary)
                    Text(p.namn)
                    Text("· \(p.samtal) \(p.samtal == 1 ? "samtal" : "samtal")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Är …") {
                        ForEach(kontakter) { k in
                            Button(k.namn) {
                                try? arkiv.byt(personnamn: p.namn, till: k.namn, hos: kund)
                                läsOm()
                            }
                        }
                    }
                    .fixedSize()
                    .help("Koppla rösten till en kontakt. Avtrycken och mötena följer med.")
                    Button {
                        try? arkiv.taBortRöst(namn: p.namn, hos: kund)
                        läsOm()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Glöm rösten. Mötena behåller namnet.")
                }
            }
            Text("Namn satta i «Vem är vem» som inte finns bland kontakterna.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
    }

    private func läsOm() {
        kontakter = arkiv.kontakter(för: kund)
        lösaRöster = arkiv.egnaRöstprofiler(för: kund).filter { p in
            !kontakter.contains { $0.namn.caseInsensitiveCompare(p.namn) == .orderedSame }
        }
    }

    private func läggTillFörHand() {
        let namn = nyttNamn.trimmingCharacters(in: .whitespaces)
        guard !namn.isEmpty else { return }
        let ny = Kontakt(namn: namn)
        kontakter = (try? arkiv.läggTill(ny, hos: kund)) ?? kontakter
        nyttNamn = ""
        // Öppna direkt: den som just skrivit ett namn vill oftast fylla i mer.
        redigerar = kontakter.first { $0.namn == namn }
    }
}
