import SwiftUI

/// Låter användaren sätta namn på rösterna i ett samtal.
///
/// Röstanalysen håller hellre isär två röster än slår ihop dem, så samma
/// person kan dyka upp som flera rader. Att slå ihop är enkelt här; ett fel
/// namn i ett kundtranskript är det inte.
struct Röstvy: View {
    let kund: Kund
    let mapp: URL
    @State var inspelning: Inspelning
    var vidSparat: (Inspelning) -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @Environment(\.dismiss) private var stäng

    @State private var namn: [Int: String] = [:]
    @State private var profiler: [Röstprofil] = []
    @State private var kontakter: [Kontakt] = []
    @State private var grupperarOm = false
    @State private var omfel: String?

    /// Namn att välja bland: kundens kontakter först, sedan röster som känns
    /// igen men inte finns som kontakt.
    private var förslag: [String] {
        // De som var kallade till just det här mötet först: de är de troligaste.
        var ut = inspelning.kallade
        for k in kontakter where !ut.contains(k.namn) { ut.append(k.namn) }
        for p in profiler where !ut.contains(p.namn) { ut.append(p.namn) }
        return ut
    }

    private var grupper: [(grupp: Int, turer: Int, sekunder: Double, exempel: String)] {
        let motpart = inspelning.yttranden.filter { $0.röst == .motpart && $0.röstgrupp != nil }
        return Dictionary(grouping: motpart, by: { $0.röstgrupp! })
            .map { g, rader in
                (g, rader.count,
                 rader.reduce(0.0) { $0 + ($1.slut - $1.start) },
                 rader.max { $0.text.count < $1.text.count }?.text ?? "")
            }
            .sorted { $0.2 > $1.2 }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vem är vem?").font(.headline)
                        Text("\(grupper.count) röster på motpartsspåret"
                             + (inspelning.röstmetod.map { " · delade med \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let varning = inspelning.röstvarning {
                    Label(varning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Uppdelningen är en gissning ur ljudet. Den som var med i
                // samtalet vet hur många som talade, och det är den snabbaste
                // vägen till rätt indelning.
                HStack(spacing: 8) {
                    Text("Antal röster")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(2...6, id: \.self) { n in
                        Button("\(n)") { grupperaOm(antal: n) }
                            .buttonStyle(.bordered)
                            .disabled(grupperarOm)
                    }
                    Button("Låt appen avgöra") { grupperaOm(antal: nil) }
                        .buttonStyle(.borderless)
                        .disabled(grupperarOm)
                    if grupperarOm { ProgressView().controlSize(.small) }
                }
                if let omfel {
                    Text(omfel).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(grupper, id: \.grupp) { g in
                        rad(g)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Text("Namn du sätter sparas som röstavtryck hos \(kund.namn) och känns igen nästa gång.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Avbryt") { stäng() }
                Button("Spara", action: spara)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 660, height: 520)
        .onAppear {
            namn = inspelning.röstnamn
            profiler = arkiv.röstprofiler(för: kund)
            kontakter = arkiv.kontakter(för: kund)
        }
    }

    private func rad(_ g: (grupp: Int, turer: Int, sekunder: Double, exempel: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Röst \(g.grupp + 1)")
                    .font(.subheadline.weight(.medium))
                Text("\(g.turer) inlägg · \(formateraLängd(g.sekunder))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if inspelning.röstnamn[g.grupp] != nil {
                    Text("igenkänd")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: .capsule)
                }
            }
            Text("«\(g.exempel.prefix(120))»")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Namn", text: Binding(
                    get: { namn[g.grupp] ?? "" },
                    set: { namn[g.grupp] = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                if !förslag.isEmpty {
                    Menu("Välj") {
                        ForEach(förslag, id: \.self) { n in
                            Button(n) { namn[g.grupp] = n }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .kort(hörn: Stil.radhörn)
    }

    /// Kör om uppdelningen med ett angivet antal röster.
    private func grupperaOm(antal: Int?) {
        grupperarOm = true
        omfel = nil
        Task {
            do {
                inspelning = try await arkiv.grupperaOm(inspelning, i: mapp, antal: antal)
                namn = inspelning.röstnamn
                vidSparat(inspelning)
            } catch {
                omfel = error.localizedDescription
            }
            grupperarOm = false
        }
    }

    private func spara() {
        inspelning.röstnamn = namn.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        try? arkiv.spara(inspelning, i: mapp)

        // Lär in avtrycken för de röster som fått namn, så att personen känns
        // igen i nästa samtal. Bladet stängs direkt, så det som inte gick
        // sägs i en notis — tidigare försvann det i tysthet, och personen
        // kändes aldrig igen igen utan att man förstod varför.
        let sparad = inspelning
        Task {
            let misslyckade = await Röstanalys().lärIn(sparad, mapp: mapp, kund: kund, arkiv: arkiv)
            if !misslyckade.isEmpty {
                Notiser.skicka(
                    titel: "Röstavtryck",
                    text: "Kunde inte lära in \(misslyckade.joined(separator: ", ")): för lite "
                        + "tal, eller så gick avtrycken inte att läsa. Namnet gäller ändå för "
                        + "det här mötet.",
                    kund: kund.namn)
            }
        }
        // En person man satt namn på hör till kunden. Att behöva lägga upp
        // hen en gång till som kontakt vore onödigt dubbelarbete.
        for personnamn in Set(inspelning.röstnamn.values)
        where !kontakter.contains(where: { $0.namn == personnamn }) {
            try? arkiv.läggTill(Kontakt(namn: personnamn), hos: kund)
        }

        vidSparat(inspelning)
        stäng()
    }
}
