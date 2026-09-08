import SwiftUI
import AppKit

/// Ett projekt hos en kund.
struct Projektinnehåll: View {
    let kund: Kund
    let projekt: Projekt

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var session: Inspelningssession
    @EnvironmentObject private var kalender: Kalendern

    @State private var flik: Flik = .översikt
    @State private var möten: [Kalendern.Möte] = []
    @State private var möteskopplingar: [String: String] = [:]
    @State private var briefing: Kalendern.Möte?
    @State private var visaMötesplockare = false
    @State private var kopplade: [Kopplad] = []
    @State private var inspelningar: [(Inspelning, URL)] = []
    @State private var öppnad: Kundinnehåll.Öppnad?
    @State private var attKasta: Kundinnehåll.Öppnad?
    @State private var visaImport = false
    @State private var släpptFil: URL?
    @State private var lägesbild: Lägesbild?
    @State private var skriverLäget = false
    @State private var lägesfel: String?
    /// Ett skrivförsök per gång vyn visas — annars skulle ett projekt utan
    /// underlag försöka om vid varje omritning.
    @State private var harFörsöktSkriva = false
    /// Om underlaget ändrats sedan lägesbilden skrevs. Räknas när vyn läser
    /// in, inte i varje omritning — svaret kräver att alla möten läses.
    @State private var lägetGammalt = false
    @State private var fakta = ""

    enum Flik: String, CaseIterable, Identifiable {
        case översikt, attGöra, inspelningar, anteckningar, tid
        var id: String { rawValue }
        var namn: String {
            switch self {
            case .översikt: "Översikt"
            case .attGöra: "Att göra"
            case .inspelningar: "Inspelningar"
            case .anteckningar: "Anteckningar"
            case .tid: "Tid"
            }
        }
        var ikon: String {
            switch self {
            case .översikt: "square.grid.2x2"
            case .attGöra: "checklist"
            case .inspelningar: "waveform"
            case .anteckningar: "note.text"
            case .tid: "clock"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $flik) {
                ForEach(Flik.allCases) { f in
                    Label(f.namn, systemImage: f.ikon).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch flik {
                    case .översikt:
                        lägesavsnitt
                        mötesavsnitt
                        mappavsnitt
                    case .attGöra: Kanbanvy(kund: kund, projekt: projekt)
                    case .inspelningar: inspelningsflik
                    case .anteckningar: Anteckningslista(mapp: projekt.anteckningsmapp)
                    case .tid: Tidsvy(kund: kund, projekt: projekt)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Stil.botten)
        .navigationTitle(projekt.namn)
        .navigationSubtitle(kund.namn)
        .sheet(item: $öppnad) { v in
            Transkriptvy(kund: kund, inspelning: v.inspelning, mapp: v.mapp)
                .onDisappear(perform: läsIn)
        }
        .sheet(isPresented: $visaImport) {
            Importvy(kund: kund, projekt: arkiv.projekt(för: kund),
                     förvald: släpptFil, förvaltProjekt: projekt, vidKlar: läsIn)
        }
        .sheet(item: $briefing) { m in
            Briefingvy(kund: kund, möte: m, projekt: projekt) { i, mapp in
                öppnad = .init(inspelning: i, mapp: mapp)
            }
        }
        .sheet(isPresented: $visaMötesplockare) {
            Mötesplockare(kund: kund, projekt: projekt) { hämtaMöten() }
        }
        .task(id: projekt.id) { hämtaMöten() }
        .onChange(of: kalender.ändringar) { hämtaMöten() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in hämtaMöten() }
        .onDrop(of: [.fileURL], isTargeted: nil) { leverantörer in
            guard let l = leverantörer.first else { return false }
            _ = l.loadObject(ofClass: URL.self) { url, _ in
                guard let url, Import.format.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in släpptFil = url; visaImport = true }
            }
            return true
        }
        .confirmationDialog(
            "Flytta inspelningen till papperskorgen?",
            isPresented: Binding(get: { attKasta != nil }, set: { if !$0 { attKasta = nil } }),
            presenting: attKasta
        ) { v in
            Button("Flytta till papperskorgen", role: .destructive) {
                try? arkiv.kastaInspelning(i: v.mapp)
                attKasta = nil
                läsIn()
            }
            Button("Avbryt", role: .cancel) { attKasta = nil }
        } message: { v in
            Text("\(v.inspelning.titel) med ljud och transkript flyttas till papperskorgen.")
        }
        .onAppear {
            läsIn()
            // Lägesbilden ska bara finnas där. Saknas den, eller har underlaget
            // ändrats, skrivs den om — men högst en gång per besök, bara när
            // chattens modell är på plats, och bara om automatiska anrop är
            // tillåtna: annars skrivs den först med knappen.
            if !harFörsöktSkriva, Inställningar.automatiskaModellanrop, Modellval.läs().färdig,
               lägesbild == nil || lägetGammalt {
                harFörsöktSkriva = true
                skrivLäget()
            }
        }
        .onChange(of: arkiv.sparningar) { läsIn() }
    }

    /// Var projektet står just nu, skrivet av modellen ur uppgifter, möten,
    /// mejl och anteckningar. Cachas och skrivs om när underlaget ändrats.
    private var lägesavsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Avsnittsrubrik("Läget just nu")
                if skriverLäget { ProgressView().controlSize(.mini) }
                Spacer()
                Text(fakta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lägesbild {
                VStack(alignment: .leading, spacing: 10) {
                    Markdowntext(text: lägesbild.text)
                    HStack(spacing: 8) {
                        Text("Skriven \(DateFormatter.klocka.string(from: lägesbild.skriven))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if lägetGammalt {
                            Text("· underlaget har ändrats")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Skriv om") { skrivLäget() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(skriverLäget)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .kort()
            } else if skriverLäget {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Läser igenom projektet och skriver lägesbilden …")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .kort()
            } else if let lägesfel {
                Text(lägesfel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .kort()
            } else if !Inställningar.automatiskaModellanrop {
                HStack(spacing: 10) {
                    Text("Lägesbilden skrivs av modellen på begäran.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Skriv lägesbilden") { skrivLäget() }
                        .disabled(!Modellval.läs().färdig)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .kort()
            }
        }
    }

    /// Det räknbara, som alltid stämmer oavsett vad modellen skrev.
    private var faktarad: String {
        let egna = arkiv.uppgifter(för: kund).filter { $0.projekt == projekt.namn }
        let öppna = egna.filter { $0.läge != .klart }
        let försenade = öppna.filter(\.försenad).count
        var delar: [String] = []
        delar.append("\(inspelningar.count) \(inspelningar.count == 1 ? "möte" : "möten")")
        var u = "\(öppna.count) öppna uppgifter"
        if försenade > 0 { u += " · \(försenade) försenade" }
        delar.append(u)
        if let senaste = inspelningar.first?.0.inledd {
            delar.append("senast \(DateFormatter.kortdag.string(from: senaste))")
        }
        return delar.joined(separator: " · ")
    }

    private func skrivLäget() {
        guard !skriverLäget else { return }
        skriverLäget = true
        lägesfel = nil
        Task {
            do {
                lägesbild = try await Läget.skriv(kund: kund, projekt: projekt, arkiv: arkiv)
                lägetGammalt = false
            } catch {
                lägesfel = error.localizedDescription
            }
            skriverLäget = false
        }
    }

    /// Kundens möten som är kopplade till projektet. Kopplingen görs på
    /// mötesraden hos kunden eller med «Lägg till möte» här — ingen regel
    /// kan gissa vilket projekt ett möte gäller.
    private var mötesavsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Avsnittsrubrik("Kommande möten")
                Spacer()
                Button("Lägg till möte") { visaMötesplockare = true }
                    .accessibilityIdentifier("projekt.lägg-till-möte")
                    .buttonStyle(.link)
                    .help("Koppla ett av kundens möten, eller ett ledigt möte i kalendern, till projektet")
            }
            if möten.isEmpty {
                Text(kalender.harTillgång
                     ? "Inga kommande möten är kopplade till \(projekt.namn)."
                     : "Ge tillgång till Kalender för att se inbokade möten.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(möten.enumerated()), id: \.element.id) { i, m in
                        Mötesrad(möte: m, kund: kund, projekt: projekt,
                                 förbered: { briefing = $0 }) {
                            Button {
                                try? arkiv.kopplaMöte(m.id, till: nil, för: kund)
                                hämtaMöten()
                            } label: {
                                Image(systemName: "folder.badge.minus")
                            }
                            .buttonStyle(.borderless)
                            .help("Koppla bort mötet från projektet. Det stannar hos kunden.")
                        }
                        if i < möten.count - 1 { Divider() }
                    }
                }
                .kort(hörn: Stil.radhörn)
            }
        }
    }

    private func hämtaMöten() {
        möteskopplingar = arkiv.möteskopplingar(för: kund)
        guard kalender.harTillgång else { möten = []; return }
        möten = kalender.möten().filter { möteskopplingar[$0.id] == projekt.namn }
    }

    /// Mappar utanför kundmappen som hör till projektet.
    private var mappavsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Avsnittsrubrik("Kopplade mappar")
                Spacer()
                Button("Koppla mapp", action: väljMapp).buttonStyle(.link)
            }
            if kopplade.isEmpty {
                Text("Peka ut en mapp med källkod, ritningar eller offerter. Chatten söker i den när du frågar något — innehållet indexeras inte, så svaret bygger på hur filerna ser ut just nu.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(kopplade.enumerated()), id: \.element.id) { i, k in
                        HStack(spacing: 10) {
                            Image(systemName: k.finns ? "folder" : "questionmark.folder")
                                .foregroundStyle(k.finns ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.visatNamn)
                                Text(k.finns ? k.väg : "Mappen finns inte längre")
                                    .font(.caption)
                                    .foregroundStyle(k.finns ? Color.secondary : Color.orange)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer()
                            if k.finns {
                                Button { NSWorkspace.shared.open(k.url) } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Visa i Finder")
                            }
                            Button {
                                kopplade = (try? arkiv.koppla(bort: k, från: projekt)) ?? kopplade
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Koppla bort mappen. Innehållet rörs inte.")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        if i < kopplade.count - 1 { Divider() }
                    }
                }
                .kort(hörn: Stil.radhörn)
            }
        }
    }

    private var inspelningsflik: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Avsnittsrubrik("Inspelningar")
                Spacer()
                // Samma två vägar som hos kunden: spela in nytt, eller lägg
                // till en färdig fil — den hamnar då i projektet direkt.
                Button("Lägg till") { släpptFil = nil; visaImport = true }
                    .buttonStyle(.link)
                Button("Spela in") {
                    Inspelningsfönster.öppna(kund: kund, projekt: projekt, möte: nil)
                }
                .buttonStyle(.link)
                .disabled(session.pågår)
            }
            if inspelningar.isEmpty {
                Text("Inga inspelningar än. Släpp en ljud- eller videofil här för att lägga till en.")
                    .foregroundStyle(.secondary)
            } else {
                Inspelningslista(
                    kund: kund,
                    rader: inspelningar,
                    öppna: { öppnad = .init(inspelning: $0, mapp: $1) },
                    kasta: { attKasta = .init(inspelning: $0, mapp: $1) })
            }
        }
    }

    private func väljMapp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Välj en mapp som hör till \(projekt.namn)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            kopplade = (try? arkiv.koppla(url, till: projekt)) ?? kopplade
        }
    }

    private func läsIn() {
        kopplade = arkiv.kopplade(för: projekt)
        inspelningar = arkiv.inspelningar(för: kund).filter { $0.0.projekt == projekt.namn }
        lägesbild = Läget.läs(kund: kund, projekt: projekt)
        lägetGammalt = lägesbild.map {
            Läget.gammal($0, kund: kund, projekt: projekt, arkiv: arkiv)
        } ?? false
        fakta = faktarad
    }
}
