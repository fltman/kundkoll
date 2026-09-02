import SwiftUI
import AppKit

/// Sökrutan och dess träffar.
struct Sökvy: View {
    @EnvironmentObject private var arkiv: Arkivet
    @Environment(\.dismiss) private var stäng
    var vidVal: (Kund) -> Void

    @State private var fråga = ""
    @State private var resultat: [(Kund, [Globalsökning.Träff])] = []
    @State private var söker = false
    @FocusState private var fokus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Sök i allt material hos alla kunder", text: $fråga)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fokus)
                    .onSubmit(sök)
                    .onChange(of: fråga) { sökStrax() }
                if söker { ProgressView().controlSize(.small) }
                Button("Stäng") { stäng() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if resultat.isEmpty {
                tomtLäge
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(resultat, id: \.0.id) { kund, träffar in
                            grupp(kund, träffar)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 720, height: 560)
        .onAppear { fokus = true }
    }

    private var tomtLäge: some View {
        VStack(spacing: 8) {
            if fråga.isEmpty {
                Text("Sök i transkript, anteckningar, mejl och sammanfattningar")
                    .foregroundStyle(.secondary)
                Text("Orden kapas automatiskt, så «leverans» hittar «leveranstiden».")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if !söker {
                Text("Inga träffar på «\(fråga)»").foregroundStyle(.secondary)
                Text("Materialet indexeras när du öppnar chatten hos en kund.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grupp(_ kund: Kund, _ träffar: [Globalsökning.Träff]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                vidVal(kund)
                stäng()
            } label: {
                HStack(spacing: 6) {
                    Text(kund.namn).font(.headline)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            ForEach(träffar) { t in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: ikon(t.inre.typ)).font(.caption)
                        Text(t.inre.hänvisning).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    Text(utdrag(t.inre.text))
                        .font(.callout)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .kort(hörn: Stil.radhörn)
            }
        }
    }

    private func ikon(_ typ: String) -> String {
        switch typ {
        case "transkript": "waveform"
        case "sammanfattning": "list.bullet.rectangle"
        case "anteckning": "note.text"
        case "mejl": "envelope"
        case "bilaga": "paperclip"
        case "chatt": "bubble.left.and.text.bubble.right"
        case "kontakt": "person"
        default: "doc.text"
        }
    }

    /// Visar början av stycket, utan tidsstämplar som bara stör i en träfflista.
    private func utdrag(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\[\d\d:\d\d\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Söker strax efter att man slutat skriva, i stället för vid varje tangent.
    @State private var jobb: Task<Void, Never>?
    private func sökStrax() {
        jobb?.cancel()
        jobb = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            sök()
        }
    }

    @State private var sökjobb: Task<Void, Never>?

    /// Sökningen öppnar ett index per kund; det görs i bakgrunden så att
    /// skrivandet i rutan inte hackar.
    private func sök() {
        let text = fråga.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { resultat = []; return }
        söker = true
        let kunder = arkiv.kunder
        sökjobb?.cancel()
        sökjobb = Task.detached(priority: .userInitiated) {
            let r = Globalsökning.sök(text, i: kunder)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                resultat = r
                söker = false
            }
        }
    }
}
