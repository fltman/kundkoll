import SwiftUI

/// Raden längst ned som säger att något pågår.
///
/// Den finns för att man ska kunna lämna inspelningsfönstret utan att tappa
/// bort att inspelningen är igång — och kunna stoppa den varifrån som helst.
struct Inspelningsrad: View {
    @EnvironmentObject private var session: Inspelningssession

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if session.pågår {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .symbolEffect(.pulse)
                    Inspelningsklocka(mätning: session.mätning, font: .callout)
                    Text(session.titel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let varning = session.ljudvarning ?? session.livevarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(varning)
                    }
                } else if session.efterbearbetar {
                    ProgressView().controlSize(.small)
                    Text(session.analyserarRöster
                         ? "Delar upp rösterna i \(session.titel)"
                         : "Skriver rent \(session.titel)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !session.analyserarRöster, session.efterbearbetningsandel > 0 {
                        Text("\(Int(session.efterbearbetningsandel * 100)) %")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.pågår {
                    Nivåmätare(mätning: session.mätning, bredd: 34, etiketter: false)
                    Button("Visa") { Inspelningsfönster.visa() }
                    Button {
                        Task { await session.stoppa() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stoppa inspelningen")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

}

/// Inspelningens klocka. Egen vy, så att bara den ritas om varje kvartssekund.
struct Inspelningsklocka: View {
    @ObservedObject var mätning: Mätning
    var font: Font

    var body: some View {
        Text(formateraLängd(mätning.förfluten)).font(font.monospacedDigit())
    }
}

/// Nivåmätarna för de två spåren. Egen vy av samma skäl som klockan.
struct Nivåmätare: View {
    @ObservedObject var mätning: Mätning
    var bredd: CGFloat
    var etiketter: Bool

    var body: some View {
        HStack(spacing: etiketter ? 12 : 8) {
            mätare("Jag", mätning.jag, .blue)
            mätare("Motpart", mätning.motpart, .purple)
        }
    }

    private func mätare(_ namn: String, _ nivå: Float, _ färg: Color) -> some View {
        HStack(spacing: 6) {
            if etiketter { Text(namn).font(.caption).foregroundStyle(.secondary) }
            Capsule().fill(.quaternary).frame(width: bredd, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(färg).frame(width: bredd * CGFloat(min(1, nivå)), height: 4)
                }
        }
    }
}
