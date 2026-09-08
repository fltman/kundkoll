import SwiftUI
import AppKit

/// Läsningen inför ett möte, samlad på en sida.
struct Briefingvy: View {
    let kund: Kund
    var möte: Kalendern.Möte?
    /// Projektet inspelningen ska hamna i, när briefen öppnats från ett.
    var projekt: Projekt?
    /// Öppnar ett tidigare möte i mötesvyn; briefen stängs först.
    var visaMöte: (Inspelning, URL) -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var session: Inspelningssession
    @Environment(\.dismiss) private var stäng

    @State private var brief: Briefing?
    @State private var redigerad: Uppgift?

    var body: some View {
        VStack(spacing: 0) {
            rubrik
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let brief {
                        if brief.tom {
                            Text("Inget att läsa på än — inga tidigare möten, "
                                 + "inga öppna åtaganden och inga nya mejl.")
                                .foregroundStyle(.secondary)
                        }
                        if let (i, mapp) = brief.senaste { senast(i, mapp) }
                        if !brief.öppnaUppgifter.isEmpty { åtaganden(brief.öppnaUppgifter) }
                        if !brief.mejlSedanSist.isEmpty { mejl(brief.mejlSedanSist) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                if let möte {
                    Button {
                        stäng()
                        Inspelningsfönster.öppna(kund: kund, projekt: projekt, möte: möte)
                    } label: {
                        Label("Spela in mötet", systemImage: "record.circle")
                    }
                    .disabled(session.pågår)
                }
                Spacer()
                Button("Stäng") { stäng() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("brief.stäng")
            }
            .padding(16)
        }
        .frame(width: 560, height: 540)
        .onAppear { brief = Briefing.bygg(för: kund, möte: möte, arkiv: arkiv) }
        .sheet(item: $redigerad) { u in
            Uppgiftsredigering(uppgift: u, kund: kund,
                               projekt: arkiv.projekt(för: kund)) {
                brief = Briefing.bygg(för: kund, möte: möte, arkiv: arkiv)
            }
        }
    }

    private var rubrik: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(möte.map { "Inför \($0.titel)" } ?? "Läget hos \(kund.namn)")
                .font(.headline)
            HStack(spacing: 6) {
                if let möte {
                    Text(DateFormatter.klocka.string(from: möte.start))
                    let andra = möte.deltagare.filter { !$0.ärJag }
                    if !andra.isEmpty {
                        Text("· \(andra.map(\.namn).prefix(4).joined(separator: ", "))")
                            .lineLimit(1)
                    }
                } else {
                    Text(kund.namn)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func senast(_ i: Inspelning, _ mapp: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Senast · \(DateFormatter.dag.string(from: i.inledd))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Öppna") {
                    stäng()
                    visaMöte(i, mapp)
                }
                .buttonStyle(.link)
            }
            if let kärna = i.sammanfattning?.kärna, !kärna.isEmpty {
                Text(kärna)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Mötet är inte sammanfattat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let frågor = brief?.öppnaFrågor, !frågor.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lämnades obesvarat:").font(.caption.weight(.medium))
                    ForEach(Array(frågor.enumerated()), id: \.offset) { _, f in
                        Text("• \(f)").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .kort()
    }

    private func åtaganden(_ uppgifter: [Uppgift]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Öppet på tavlan · \(uppgifter.count)")
                .font(.subheadline.weight(.semibold))
            ForEach(uppgifter.prefix(8)) { u in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(u.vad)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let senast = u.senast {
                        Text(DateFormatter.kortdag.string(from: senast))
                            .font(.caption)
                            .foregroundStyle(u.försenad ? Color.red : Color.secondary)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { redigerad = u }
            }
            if uppgifter.count > 8 {
                Text("… och \(uppgifter.count - 8) till")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mejl(_ rader: [Mailen.Mejl]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sedan sist i mejlen")
                .font(.subheadline.weight(.semibold))
            ForEach(rader) { m in
                HStack(spacing: 8) {
                    Image(systemName: m.skickat ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(m.ämne).font(.callout).lineLimit(1)
                    Spacer()
                    if let d = m.datum {
                        Text(DateFormatter.kortdag.string(from: d))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { m.öppna() }
            }
        }
    }
}
