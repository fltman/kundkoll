import SwiftUI

/// Allt jag har att göra, hos alla kunder, sorterat på hur bråttom det är.
///
/// Tavlorna är per kund men arbetsdagen är det inte. Det här är en läsvy
/// över samma uppgifter: försenat överst, sedan veckan, sedan resten.
struct Minveckavy: View {
    @EnvironmentObject private var arkiv: Arkivet

    @State private var rader: [(kund: Kund, uppgift: Uppgift)] = []
    @State private var redigerad: Redigeringsval?

    private struct Redigeringsval: Identifiable {
        let kund: Kund
        let uppgift: Uppgift
        var id: UUID { uppgift.id }
    }

    private enum Grupp: String, CaseIterable {
        case försenat = "Försenat"
        case veckan = "Denna vecka"
        case senare = "Senare"
        case utanDatum = "Utan datum"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Avsnittsrubrik("Min vecka")
                    Spacer()
                    Text(sammanfattning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if rader.isEmpty {
                    Text("Inget öppet åtagande hos någon kund. Skönt.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Grupp.allCases, id: \.self) { grupp in
                    let ivarje = grupperade[grupp] ?? []
                    if !ivarje.isEmpty {
                        avsnitt(grupp, ivarje)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Stil.botten)
        .onAppear(perform: läsOm)
        .sheet(item: $redigerad) { v in
            Uppgiftsredigering(uppgift: v.uppgift, kund: v.kund,
                               projekt: arkiv.projekt(för: v.kund),
                               vidSparat: läsOm)
        }
    }

    private var sammanfattning: String {
        let kunder = Set(rader.map(\.kund.namn)).count
        switch rader.count {
        case 0: return ""
        case 1: return "1 öppet åtagande"
        default: return "\(rader.count) öppna åtaganden hos "
            + (kunder == 1 ? "en kund" : "\(kunder) kunder")
        }
    }

    private func avsnitt(_ grupp: Grupp, _ ivarje: [(kund: Kund, uppgift: Uppgift)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(grupp.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(grupp == .försenat ? Color.red : Color.primary)
                Text("\(ivarje.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(ivarje.enumerated()), id: \.element.uppgift.id) { i, rad in
                    self.rad(rad)
                    if i < ivarje.count - 1 { Divider() }
                }
            }
            .kort(hörn: Stil.radhörn)
        }
    }

    private func rad(_ rad: (kund: Kund, uppgift: Uppgift)) -> some View {
        let u = rad.uppgift
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                bocka(rad)
            } label: {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Gör klar")

            VStack(alignment: .leading, spacing: 2) {
                Text(u.vad).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(rad.kund.namn)
                    if let p = u.projekt { Text("· \(p)") }
                    if let vem = u.vem { Text("· \(vem)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let senast = u.senast {
                Text(DateFormatter.kortdag.string(from: senast))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(u.försenad ? Color.red : Color.secondary)
            } else if let när = u.när {
                Text(när).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { redigerad = Redigeringsval(kund: rad.kund, uppgift: u) }
    }

    // MARK: - Urval

    private var grupperade: [Grupp: [(kund: Kund, uppgift: Uppgift)]] {
        Dictionary(grouping: rader) { grupp($0.uppgift) }
            .mapValues { $0.sorted {
                ($0.uppgift.senast ?? .distantFuture, $0.uppgift.skapad)
                    < ($1.uppgift.senast ?? .distantFuture, $1.uppgift.skapad)
            } }
    }

    /// Var en uppgift hör hemma i veckan. Utbruten för att kunna provas.
    static func grupp(_ u: Uppgift, idag: Date = Date()) -> String {
        guard let senast = u.senast else { return Grupp.utanDatum.rawValue }
        let kalender = Calendar.current
        if senast < kalender.startOfDay(for: idag) { return Grupp.försenat.rawValue }
        if kalender.isDate(senast, equalTo: idag, toGranularity: .weekOfYear) {
            return Grupp.veckan.rawValue
        }
        return Grupp.senare.rawValue
    }

    private func grupp(_ u: Uppgift) -> Grupp {
        Grupp(rawValue: Self.grupp(u)) ?? .utanDatum
    }

    private func bocka(_ rad: (kund: Kund, uppgift: Uppgift)) {
        var klar = rad.uppgift
        klar.läge = .klart
        try? arkiv.uppdatera(klar, för: rad.kund)
        läsOm()
    }

    private func läsOm() {
        rader = arkiv.kunder.flatMap { kund in
            arkiv.uppgifter(för: kund)
                .filter { $0.läge != .klart }
                .map { (kund, $0) }
        }
    }
}
