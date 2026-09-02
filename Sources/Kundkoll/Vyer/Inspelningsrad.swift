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
                    Text(formateraLängd(session.förfluten))
                        .font(.callout.monospacedDigit())
                    Text(session.titel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let varning = session.livevarning {
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
                    nivåer
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

    private var nivåer: some View {
        HStack(spacing: 8) {
            mätare(session.nivåJag, .blue)
            mätare(session.nivåMotpart, .purple)
        }
    }

    private func mätare(_ nivå: Float, _ färg: Color) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 34, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(färg).frame(width: 34 * CGFloat(min(1, nivå)), height: 4)
            }
    }
}
