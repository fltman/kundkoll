import SwiftUI
import AppKit

/// Anteckningarna i en mapp. Används både för en kund och för ett projekt.
struct Anteckningslista: View {
    let mapp: URL
    var rubrik = "Anteckningar"

    @EnvironmentObject private var arkiv: Arkivet
    @State private var anteckningar: [Anteckning] = []
    @State private var öppen: Anteckning?
    @State private var nyRubrik = ""
    @State private var visaNy = false
    @State private var attTaBort: Anteckning?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rubrik).font(.headline)
                Spacer()
                Button("Ny anteckning") { visaNy = true }.buttonStyle(.link)
            }

            if anteckningar.isEmpty {
                Text("Inga anteckningar än.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(anteckningar.enumerated()), id: \.element.id) { i, a in
                        Button { öppen = a } label: { rad(a) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if Obsidian.finns {
                                    Button("Öppna i Obsidian") { Obsidian.öppna(a.fil) }
                                }
                                Button("Visa i Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([a.fil])
                                }
                                Button("Flytta till papperskorgen …", role: .destructive) {
                                    attTaBort = a
                                }
                            }
                        if i < anteckningar.count - 1 { Divider() }
                    }
                }
                .kort(hörn: Stil.radhörn)
            }
        }
        .sheet(item: $öppen) { a in
            Anteckningsvy(anteckning: a, mapp: mapp, vidÄndring: läsOm)
        }
        .sheet(isPresented: $visaNy) { nyttBlad }
        .confirmationDialog(
            "Flytta anteckningen till papperskorgen?",
            isPresented: Binding(get: { attTaBort != nil }, set: { if !$0 { attTaBort = nil } }),
            presenting: attTaBort
        ) { a in
            Button("Flytta till papperskorgen", role: .destructive) {
                try? arkiv.taBort(a)
                attTaBort = nil
                läsOm()
            }
            Button("Avbryt", role: .cancel) { attTaBort = nil }
        } message: { a in
            Text("«\(a.titel)» flyttas till papperskorgen. Du kan ta tillbaka den därifrån.")
        }
        .onAppear(perform: läsOm)
    }

    private func rad(_ a: Anteckning) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.titel)
                HStack(spacing: 6) {
                    Text(DateFormatter.klocka.string(from: a.ändrad))
                    if !a.utdrag.isEmpty { Text("· \(a.utdrag)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !a.bilder.isEmpty {
                Label("\(a.bilder.count)", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(.rect)
    }

    private var nyttBlad: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ny anteckning").font(.headline)
            TextField("Rubrik", text: $nyRubrik)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(skapa)
            HStack {
                Spacer()
                Button("Avbryt") { visaNy = false; nyRubrik = "" }
                Button("Skapa", action: skapa).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func skapa() {
        let titel = nyRubrik.trimmingCharacters(in: .whitespaces)
        visaNy = false
        nyRubrik = ""
        guard let ny = try? arkiv.nyAnteckning(i: mapp, titel: titel) else { return }
        läsOm()
        öppen = ny
    }

    private func läsOm() { anteckningar = arkiv.anteckningar(i: mapp) }
}
