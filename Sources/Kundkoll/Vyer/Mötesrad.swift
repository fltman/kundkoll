import SwiftUI
import AppKit

/// Ett kommande möte på en rad: när, vilka, om det pågår, länken,
/// Förbered och Spela in. Kundens översikt och projektets visar samma rad;
/// det som skiljer är knappen för projektet, som skickas in.
struct Mötesrad<Extra: View>: View {
    let möte: Kalendern.Möte
    let kund: Kund
    /// Projektet inspelningen hamnar i.
    var projekt: Projekt?
    var förbered: (Kalendern.Möte) -> Void
    @ViewBuilder var extra: () -> Extra

    @EnvironmentObject private var session: Inspelningssession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(möte.titel)
                HStack(spacing: 6) {
                    Text(möte.pågår ? "pågår nu" : Kalendern.närText(möte.start))
                    let andra = möte.deltagare.filter { !$0.ärJag }
                    if !andra.isEmpty {
                        Text("· \(andra.map(\.namn).prefix(3).joined(separator: ", "))")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if möte.pågår {
                Märke(text: "pågår", färg: .red)
            }
            extra()
            if let länk = möte.möteslänk {
                Button { NSWorkspace.shared.open(länk) } label: {
                    Image(systemName: "video")
                }
                .buttonStyle(.borderless)
                .help("Öppna mötet")
            }
            Button("Förbered") { förbered(möte) }
                .accessibilityIdentifier("möte.förbered")
                .buttonStyle(.borderless)
                .help("Senaste mötet, öppna åtaganden och nya mejl — läsningen inför mötet")
            Button("Spela in") {
                // Mötet bär titel, deltagare och sitt projekt. Mikrofonen är
                // den som användes sist.
                Inspelningsfönster.öppna(kund: kund, projekt: projekt, möte: möte)
            }
            .buttonStyle(.borderless)
            .disabled(session.pågår)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
