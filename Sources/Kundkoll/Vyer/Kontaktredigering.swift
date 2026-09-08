import SwiftUI
import AppKit

/// Redigerar en kontakt och kan lägga upp eller uppdatera personen i
/// macOS Kontakter.
///
/// Skrivning till adressboken sker bara på knapptryck. Adressboken är
/// användarens egen och delas med telefon och andra datorer, så appen ändrar
/// inget där i bakgrunden.
struct Kontaktredigering: View {
    let kund: Kund
    @State var kontakt: Kontakt
    var vidSparat: (Kontakt) -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var adressbok: Adressboken
    @Environment(\.dismiss) private var stäng

    @State private var epost: [String] = []
    @State private var telefon: [String] = []
    @State private var meddelande: Meddelande?
    @State private var sparar = false

    private struct Meddelande: Identifiable {
        let id = UUID()
        let text: String
        let fel: Bool
    }

    private var kopplad: Bool { kontakt.systemID != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kontakt.namn.isEmpty ? "Ny kontakt" : kontakt.namn).font(.headline)
                Spacer()
                if kopplad {
                    Label("i Kontakter", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fält("Namn") {
                        TextField("", text: $kontakt.namn).textFieldStyle(.roundedBorder)
                    }
                    fält("Roll") {
                        TextField("", text: Binding(
                            get: { kontakt.roll ?? "" },
                            set: { kontakt.roll = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                    lista("E-post", rader: $epost, exempel: "namn@företaget.se")
                    lista("Telefon", rader: $telefon, exempel: "070-123 45 67")
                }
                .padding(16)
            }

            if let m = meddelande {
                Divider()
                Label(m.text, systemImage: m.fel ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(m.fel ? .orange : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }

            Divider()
            HStack {
                adressboksknapp
                Spacer()
                Button("Avbryt") { stäng() }
                    .accessibilityIdentifier("kontakt.avbryt")
                Button("Spara", action: spara)
                    .keyboardShortcut(.defaultAction)
                    .disabled(kontakt.namn.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
        .onAppear {
            epost = kontakt.epost.isEmpty ? [""] : kontakt.epost
            telefon = kontakt.telefon.isEmpty ? [""] : kontakt.telefon
        }
    }

    @ViewBuilder
    private var adressboksknapp: some View {
        if !adressbok.harTillgång {
            Button("Ge tillgång till Kontakter") {
                Task { await adressbok.begärTillgång() }
            }
        } else if sparar {
            ProgressView().controlSize(.small)
        } else if kopplad {
            Button("Uppdatera i Kontakter") { skrivTillAdressboken(nytt: false) }
        } else {
            Button("Lägg till i Kontakter") { skrivTillAdressboken(nytt: true) }
                .disabled(kontakt.namn.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var bildval: some View {
        Button("Välj bild …", action: väljBild)
        if kopplad {
            Button("Hämta från Kontakter") { hämtaBildFrånKontakter() }
        }
        if kontakt.bild != nil {
            Divider()
            Button("Ta bort bilden", role: .destructive) {
                try? arkiv.taBortKontaktbild(för: &kontakt, hos: kund)
                vidSparat(kontakt)
            }
        }
    }

    private func väljBild() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Välj en profilbild för \(kontakt.namn)"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        try? arkiv.sparaKontaktbild(data, för: &kontakt, hos: kund)
        vidSparat(kontakt)
    }

    private func hämtaBildFrånKontakter() {
        guard let data = adressbok.bilddata(för: kontakt) else {
            meddelande = Meddelande(text: "Posten i Kontakter har ingen bild.", fel: false)
            return
        }
        try? arkiv.sparaKontaktbild(data, för: &kontakt, hos: kund)
        vidSparat(kontakt)
    }

    private func fält<Innehåll: View>(_ rubrik: String,
                                      @ViewBuilder _ innehåll: () -> Innehåll) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rubrik).font(.subheadline.weight(.medium))
            innehåll()
        }
    }

    private func lista(_ rubrik: String, rader: Binding<[String]>, exempel: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rubrik).font(.subheadline.weight(.medium))
            ForEach(rader.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField(exempel, text: Binding(
                        get: { i < rader.wrappedValue.count ? rader.wrappedValue[i] : "" },
                        set: { if i < rader.wrappedValue.count { rader.wrappedValue[i] = $0 } }))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        rader.wrappedValue.remove(at: i)
                        if rader.wrappedValue.isEmpty { rader.wrappedValue = [""] }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(rader.wrappedValue.count == 1 && rader.wrappedValue[0].isEmpty)
                }
            }
            Button("Lägg till") { rader.wrappedValue.append("") }
                .buttonStyle(.link)
                .disabled(rader.wrappedValue.contains(where: \.isEmpty))
        }
    }

    // MARK: - Spara

    private func samlaIhop() {
        kontakt.namn = kontakt.namn.trimmingCharacters(in: .whitespaces)
        kontakt.epost = epost.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        kontakt.telefon = telefon.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func spara() {
        samlaIhop()
        try? arkiv.uppdatera(kontakt, hos: kund)
        vidSparat(kontakt)
        stäng()
    }

    private func skrivTillAdressboken(nytt: Bool) {
        samlaIhop()
        sparar = true
        meddelande = nil
        do {
            if nytt {
                kontakt = try adressbok.läggTillIAdressboken(kontakt, organisation: kund.namn)
                meddelande = Meddelande(text: "\(kontakt.namn) är upplagd i Kontakter.", fel: false)
            } else {
                try adressbok.uppdateraIAdressboken(kontakt, organisation: kund.namn)
                meddelande = Meddelande(text: "Posten i Kontakter är uppdaterad.", fel: false)
            }
            // Spara direkt, annars går kopplingen förlorad om bladet stängs
            // med Avbryt efter att posten redan skapats.
            try? arkiv.uppdatera(kontakt, hos: kund)
            vidSparat(kontakt)
        } catch {
            meddelande = Meddelande(text: error.localizedDescription, fel: true)
        }
        sparar = false
    }
}
