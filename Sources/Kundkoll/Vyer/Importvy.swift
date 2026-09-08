import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Tar in en färdig ljud- eller videofil som en inspelning.
struct Importvy: View {
    let kund: Kund
    let projekt: [Projekt]
    /// Fil som redan valts, till exempel genom att släppas på fönstret.
    var förvald: URL?
    /// Projektet som är öppet när importen startas — förvalt i väljaren.
    var förvaltProjekt: Projekt?
    var vidKlar: () -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @Environment(\.dismiss) private var stäng

    init(kund: Kund, projekt: [Projekt], förvald: URL? = nil,
         förvaltProjekt: Projekt? = nil, vidKlar: @escaping () -> Void) {
        self.kund = kund
        self.projekt = projekt
        self.förvald = förvald
        self.förvaltProjekt = förvaltProjekt
        self.vidKlar = vidKlar
        _valtProjekt = State(initialValue: förvaltProjekt)
    }

    @State private var fil: URL?
    @State private var titel = ""
    @State private var valtProjekt: Projekt?
    /// "sv", "en" eller nil — motorn avgör själv.
    @State private var språk: String? = "sv"


    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lägg till en inspelning").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()

            väljare
        }
        .frame(width: 560, height: 420)
        .onAppear {
            if let förvald { välj(förvald) }
        }
    }

    private var väljare: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                väljFil()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: fil == nil ? "waveform.badge.plus" : "waveform")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fil?.lastPathComponent ?? "Välj ljud- eller videofil")
                            .lineLimit(1)
                        Text(fil == nil
                             ? "Mötesinspelning från Teams eller Zoom, telefonsamtal, diktafon"
                             : "Klicka för att byta")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Form {
                TextField("Vad gäller inspelningen?", text: $titel)
                Picker("Hör till", selection: $valtProjekt) {
                    Text(kund.namn).tag(Projekt?.none)
                    ForEach(projekt) { p in Text(p.namn).tag(Projekt?.some(p)) }
                }
                Picker("Språk", selection: $språk) {
                    ForEach(Mötesspråk.val, id: \.kod) { s in
                        Text(s.namn).tag(String?.some(s.kod))
                    }
                    Text("Avgör själv").tag(String?.none)
                }
                .help("KB-Whisper är svensktrimmad och översätter andra språk till "
                      + "svenska — för dem tar transkriberingen vägen via MLX "
                      + "eller den valda molnmotorn.")
            }
            .formStyle(.grouped)

            Label("Hela ljudet ligger i ett spår, så rösterna delas upp av röstanalysen i stället för av kanalerna. En av dem kan vara du.",
                  systemImage: "person.wave.2")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            HStack {
                Button("Avbryt") { stäng() }
                    .accessibilityIdentifier("import.avbryt")
                Spacer()
                Button(Importkö.delad.pågår ? "Lägg i kön" : "Lägg till", action: kör)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fil == nil)
            }
        }
        .padding(24)
    }

    // MARK: - Handling

    private func väljFil() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .quickTimeMovie]
        panel.message = "Välj en mötesinspelning"
        if panel.runModal() == .OK, let vald = panel.url { välj(vald) }
    }

    private func välj(_ url: URL) {
        fil = url
        if titel.isEmpty { titel = url.deletingPathExtension().lastPathComponent }
    }

    /// Lägger jobbet i kön och stänger bladet. Arbetet syns i raden längst
    /// ned i fönstret — appen ska inte stå still i minuter bakom ett blad.
    private func kör() {
        guard let fil else { return }
        let placering: Placering = valtProjekt.map { .projekt($0) } ?? .kund(kund)
        let namn = titel.trimmingCharacters(in: .whitespaces)
        Importkö.delad.köa(
            källa: fil, placering: placering,
            titel: namn.isEmpty ? fil.deletingPathExtension().lastPathComponent : namn,
            kund: kund, språk: språk)
        vidKlar()
        stäng()
    }
}
