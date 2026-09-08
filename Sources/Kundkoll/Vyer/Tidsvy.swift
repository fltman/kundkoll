import SwiftUI

/// Projektets tidslogg: ett ur att starta och stoppa, rader att skriva in i
/// efterhand, och summorna som gör loggen värd att föra.
struct Tidsvy: View {
    let kund: Kund
    let projekt: Projekt

    @EnvironmentObject private var arkiv: Arkivet
    @ObservedObject private var tidur = Tidur.delad

    @State private var poster: [Tidspost] = []
    @State private var vad = ""
    @State private var manuellVad = ""
    @State private var manuellLängd = ""
    @State private var manuellDag = Date()
    @State private var attTaBort: Tidspost?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            uravsnitt
            efterhandsavsnitt
            loggavsnitt
        }
        .onAppear(perform: läsOm)
        .onChange(of: tidur.pågående) { läsOm() }
        .confirmationDialog(
            "Ta bort tidsposten?",
            isPresented: Binding(get: { attTaBort != nil }, set: { if !$0 { attTaBort = nil } }),
            presenting: attTaBort
        ) { p in
            Button("Ta bort", role: .destructive) {
                try? arkiv.taBort(p, för: kund)
                attTaBort = nil
                läsOm()
            }
            Button("Avbryt", role: .cancel) { attTaBort = nil }
        } message: { p in
            Text("\(Tidspost.längdtext(p.sekunder)) · \(p.vad) tas bort ur loggen.")
        }
    }

    // MARK: - Uret

    @ViewBuilder
    private var uravsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Avsnittsrubrik("Uret")
                Spacer()
                Text(sammanfattning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let p = tidur.pågående {
                if p.kund == kund.namn && p.projekt == projekt.namn {
                    egetUr(p)
                } else {
                    Text("Uret går redan i \(p.projekt ?? p.kund) — «\(p.vad)». "
                         + "Stoppa det där innan ett nytt startas.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .kort()
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Vad gör du?", text: $vad)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(starta)
                    Button {
                        starta()
                    } label: {
                        Label("Starta", systemImage: "play.fill")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .kort()
            }
        }
    }

    private func egetUr(_ p: Tidur.Pågående) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Tidspost.längdtext(p.gången()))
                        .font(.system(size: 30, weight: .medium, design: .rounded)
                            .monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.vad.isEmpty ? "Arbete" : p.vad).lineLimit(2)
                    if p.pausad {
                        Text("Pausat — datorn har sovit")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Räknar sedan \(DateFormatter.klocka.string(from: p.start))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                if p.pausad {
                    Button("Fortsätt räkna") { tidur.fortsätt() }
                    Button("Logga tiden") { tidur.stoppa(); läsOm() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        tidur.stoppa()
                        läsOm()
                    } label: {
                        Label("Stoppa och logga", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Kasta utan att logga") { tidur.släng() }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kort()
    }

    private func starta() {
        tidur.starta(kund: kund.namn, projekt: projekt.namn,
                     vad: vad.trimmingCharacters(in: .whitespaces))
        vad = ""
    }

    // MARK: - I efterhand

    private var efterhandsavsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Avsnittsrubrik("Lägg till i efterhand")
            HStack(spacing: 8) {
                TextField("Vad gjorde du?", text: $manuellVad)
                    .textFieldStyle(.roundedBorder)
                TextField("1:30", text: $manuellLängd)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .help("Timmar och minuter «1:30», timmar «1,5» eller minuter «90»")
                DatePicker("", selection: $manuellDag, displayedComponents: .date)
                    .labelsHidden()
                Button("Lägg till", action: läggTill)
                    .disabled(Tidspost.tolkaLängd(manuellLängd) == nil
                              || manuellVad.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func läggTill() {
        guard let sekunder = Tidspost.tolkaLängd(manuellLängd) else { return }
        let post = Tidspost(vad: manuellVad.trimmingCharacters(in: .whitespaces),
                            projekt: projekt.namn, start: manuellDag, sekunder: sekunder)
        try? arkiv.läggTill(post, för: kund)
        manuellVad = ""
        manuellLängd = ""
        läsOm()
    }

    // MARK: - Loggen

    @ViewBuilder
    private var loggavsnitt: some View {
        if poster.isEmpty {
            TomtLäge(ikon: "clock", rubrik: "Ingen tid loggad än",
                     text: "Starta uret, eller skriv in i efterhand.")
        } else {
            ForEach(dagar, id: \.dag) { grupp in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Avsnittsrubrik(DateFormatter.dag.string(from: grupp.dag))
                        Spacer()
                        Text(Tidspost.längdtext(grupp.poster.reduce(0) { $0 + $1.sekunder }))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(grupp.poster.enumerated()), id: \.element.id) { i, p in
                            rad(p)
                            if i < grupp.poster.count - 1 { Divider() }
                        }
                    }
                    .kort(hörn: Stil.radhörn)
                }
            }
        }
    }

    private func rad(_ p: Tidspost) -> some View {
        HStack(spacing: 10) {
            Text(Tidspost.längdtext(p.sekunder))
                .font(.callout.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
            Text(p.vad).lineLimit(2)
            Spacer()
            Text(DateFormatter.klocka.string(from: p.start))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(.rect)
        .contextMenu {
            Button("Ta bort …", role: .destructive) { attTaBort = p }
        }
    }

    private var dagar: [(dag: Date, poster: [Tidspost])] {
        Dictionary(grouping: poster) { Calendar.current.startOfDay(for: $0.start) }
            .map { (dag: $0.key, poster: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.dag > $1.dag }
    }

    private var sammanfattning: String {
        let total = poster.reduce(0) { $0 + $1.sekunder }
        let veckan = poster
            .filter { Calendar.current.isDate($0.start, equalTo: Date(),
                                              toGranularity: .weekOfYear) }
            .reduce(0) { $0 + $1.sekunder }
        guard total > 0 else { return "" }
        return "denna vecka \(Tidspost.längdtext(veckan)) · totalt \(Tidspost.längdtext(total))"
    }

    private func läsOm() {
        poster = arkiv.tidsposter(för: kund).filter { $0.projekt == projekt.namn }
    }
}

/// Den smala raden längst ned i huvudfönstret när uret går — så att en glömd
/// klocka aldrig är osynlig.
struct Tidursrad: View {
    @ObservedObject private var tidur = Tidur.delad

    var body: some View {
        if let p = tidur.pågående {
            HStack(spacing: 10) {
                Image(systemName: p.pausad ? "pause.circle.fill" : "clock.fill")
                    .foregroundStyle(p.pausad ? Color.orange : Color.accentColor)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Tidspost.längdtext(p.gången()))
                        .font(.callout.monospacedDigit().weight(.medium))
                }
                Text("\(p.projekt ?? p.kund)\(p.vad.isEmpty ? "" : " — \(p.vad)")")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if p.pausad {
                    Button("Fortsätt") { tidur.fortsätt() }
                    Button("Logga") { tidur.stoppa() }
                } else {
                    Button("Stoppa och logga") { tidur.stoppa() }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Raden längst ned när en import arbetar i bakgrunden.
struct Importrad: View {
    @ObservedObject private var kö = Importkö.delad

    var body: some View {
        if let fel = kö.fel {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(fel).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button("OK") { kö.stängFel() }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        if let jobb = kö.aktuell {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("\(jobb.titel) — \(kö.steg)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if let andel = kö.andel {
                    ProgressView(value: andel).frame(width: 120)
                    Text("\(Int(andel * 100)) %")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !kö.väntande.isEmpty {
                    // Det som väntar ska gå att ångra utan att avbryta det
                    // som pågår — en dubblett som råkat hamna i kön kostar
                    // annars ett helt arkivpass.
                    Menu("+\(kö.väntande.count) i kö") {
                        ForEach(kö.väntande) { v in
                            Button("Ta bort \(v.titel)") { kö.taBort(v) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                    .help("Jobb som väntar. Välj ett för att ta bort det ur kön.")
                }
                Spacer()
                Button("Avbryt") { kö.avbryt() }
                    .help("Avbryter det som pågår. Mappen lämnas så att det går att köra om.")
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
