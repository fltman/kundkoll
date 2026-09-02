import SwiftUI

/// Redigerar en uppgift.
///
/// Det mesta på tavlan är utplockat av en modell ur möten och mejl, och en
/// modell formulerar sig inte alltid som man själv skulle ha gjort. Därför
/// ska allt gå att skriva om — vad det är, vem som ska göra det och när.
struct Uppgiftsredigering: View {
    @State var uppgift: Uppgift
    let kund: Kund
    /// Projekt att välja mellan. Tom lista döljer valet.
    var projekt: [Projekt] = []
    var vidSparat: () -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @Environment(\.dismiss) private var stäng
    @State private var läggerIPåminnelser = false
    @State private var bekräftaBorttagning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uppgift").font(.headline)
                Spacer()
                Label(ursprungstext, systemImage: uppgift.ursprung.ikon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fält("Vad") {
                        TextEditor(text: $uppgift.vad)
                            .font(.body)
                            .frame(minHeight: 64)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary))
                    }
                    HStack(alignment: .top, spacing: 12) {
                        fält("Vem") {
                            TextField("", text: text($uppgift.vem))
                                .textFieldStyle(.roundedBorder)
                        }
                        fält("När") {
                            TextField("", text: text($uppgift.när))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    fält("Senast") {
                        HStack(spacing: 10) {
                            Toggle("", isOn: harDatum).labelsHidden()
                            if uppgift.senast != nil {
                                DatePicker("", selection: datumval, displayedComponents: .date)
                                    .labelsHidden()
                            } else {
                                Text(uppgift.när.map { "«\($0)» — inget räknat datum" }
                                     ?? "Inget datum")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    fält("Läge") {
                        Picker("", selection: $uppgift.läge) {
                            ForEach(Uppgift.Läge.allCases) { Text($0.namn).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if !projekt.isEmpty {
                        fält("Projekt") {
                            Picker("", selection: projektval) {
                                Text("Ingen").tag("")
                                ForEach(projekt) { Text($0.namn).tag($0.namn) }
                            }
                            .labelsHidden()
                        }
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Button("Ta bort …", role: .destructive) { bekräftaBorttagning = true }
                    .confirmationDialog("Ta bort uppgiften?", isPresented: $bekräftaBorttagning) {
                        Button("Ta bort", role: .destructive) {
                            try? arkiv.taBort(uppgift, för: kund)
                            vidSparat()
                            stäng()
                        }
                        Button("Avbryt", role: .cancel) {}
                    } message: {
                        Text("«\(uppgift.vad)» tas bort från tavlan. Det går inte att ångra.")
                    }
                if uppgift.påminnelse == nil {
                    Button(läggerIPåminnelser ? "Lägger in …" : "Lägg i Påminnelser") {
                        läggIPåminnelser()
                    }
                    .disabled(läggerIPåminnelser)
                } else {
                    Label("i Påminnelser", systemImage: "checklist.checked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Avbryt") { stäng() }
                Button("Spara") { spara() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(uppgift.vad.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
    }

    private var ursprungstext: String {
        switch uppgift.ursprung {
        case .möte: uppgift.källtitel ?? "ur ett möte"
        case .mejl: uppgift.källtitel ?? "ur ett mejl"
        case .anteckning: uppgift.källtitel ?? "ur en anteckning"
        case .egen: "tillagd för hand"
        }
    }

    /// Tomma fält sparas som ingenting, inte som en tom sträng.
    private func text(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" },
                set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// Datumväljaren visas bara när det finns ett datum att välja.
    private var harDatum: Binding<Bool> {
        Binding(get: { uppgift.senast != nil },
                set: { på in
                    uppgift.senast = på
                        ? (uppgift.senast ?? Calendar.current.startOfDay(for: Date()))
                        : nil
                })
    }

    private var datumval: Binding<Date> {
        Binding(get: { uppgift.senast ?? Date() }, set: { uppgift.senast = $0 })
    }

    /// Lägger uppgiften i Påminnelser och sparar id:t, så att en avbockning
    /// på tavlan bockar av även där.
    private func läggIPåminnelser() {
        läggerIPåminnelser = true
        Task {
            if let id = await Påminnelser.delad.läggIn(uppgift, kund: kund.namn) {
                uppgift.påminnelse = id
                try? arkiv.uppdatera(uppgift, för: kund)
                vidSparat()
            }
            läggerIPåminnelser = false
        }
    }

    private var projektval: Binding<String> {
        Binding(get: { uppgift.projekt ?? "" },
                set: { uppgift.projekt = $0.isEmpty ? nil : $0 })
    }

    private func spara() {
        uppgift.vad = uppgift.vad.trimmingCharacters(in: .whitespacesAndNewlines)
        try? arkiv.uppdatera(uppgift, för: kund)
        vidSparat()
        stäng()
    }

    private func fält<I: View>(_ etikett: String, @ViewBuilder _ innehåll: () -> I) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(etikett).font(.caption).foregroundStyle(.secondary)
            innehåll()
        }
    }
}
