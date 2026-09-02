import SwiftUI
import AppKit

/// Allt om en kund, uppdelat i flikar.
///
/// Tidigare låg allt i en enda lång rulle. Med möten, projekt, anteckningar,
/// kontakter, inspelningar och mejl på samma sida fick man scrolla förbi det
/// man inte var ute efter för att komma åt det man ville ha.
struct Kundinnehåll: View {
    let kund: Kund
    var väljProjekt: (Projekt) -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var kalender: Kalendern
    @EnvironmentObject private var adressbok: Adressboken
    @EnvironmentObject private var session: Inspelningssession

    @State private var flik: Flik = .översikt
    @State private var projekt: [Projekt] = []
    @State private var kontakter: [Kontakt] = []
    @State private var möten: [Kalendern.Möte] = []
    @State private var inspelningar: [(Inspelning, URL)] = []
    @State private var visaBilagor = false
    @State private var mejl: [Mailen.Mejl] = []
    @State private var bilagor: [Bilagor.Bilaga] = []
    @State private var mejlLäge: Mejlläge = .ejHämtat

    @State private var visaNyttProjekt = false
    @State private var nyttProjektnamn = ""
    @State private var visaKontakter = false
    @State private var visaImport = false
    @State private var släpptFil: URL?
    @State private var öppnad: Öppnad?
    @State private var attKasta: Öppnad?
    @State private var ofullständiga: [(mapp: URL, storlek: Int)] = []
    @State private var briefing: Kalendern.Möte?
    @State private var visaMötesplockare = false
    /// Mötes-id → projektnamn, valt för hand.
    @State private var möteskopplingar: [String: String] = [:]
    @ObservedObject private var kö = Importkö.delad

    enum Flik: String, CaseIterable, Identifiable {
        case översikt, attGöra, inspelningar, anteckningar, mail
        var id: String { rawValue }
        var namn: String {
            switch self {
            case .översikt: "Översikt"
            case .attGöra: "Att göra"
            case .inspelningar: "Inspelningar"
            case .anteckningar: "Anteckningar"
            case .mail: "Mail"
            }
        }
        var ikon: String {
            switch self {
            case .översikt: "square.grid.2x2"
            case .attGöra: "checklist"
            case .inspelningar: "waveform"
            case .anteckningar: "note.text"
            case .mail: "envelope"
            }
        }
    }

    enum Mejlläge: Equatable { case ejHämtat, hämtar(String), klar, fel(String) }

    struct Öppnad: Identifiable {
        let inspelning: Inspelning
        let mapp: URL
        var id: UUID { inspelning.id }
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
                    case .översikt: översikt
                    case .attGöra: Kanbanvy(kund: kund)
                    case .inspelningar: inspelningsflik
                    case .anteckningar: Anteckningslista(mapp: kund.anteckningsmapp)
                    case .mail: mailflik
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Stil.botten)
        .navigationTitle(kund.namn)
        .onDrop(of: [.fileURL], isTargeted: nil) { leverantörer in
            guard let l = leverantörer.first else { return false }
            _ = l.loadObject(ofClass: URL.self) { url, _ in
                guard let url, Import.format.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in släpptFil = url; visaImport = true }
            }
            return true
        }
        .sheet(isPresented: $visaNyttProjekt) { nyttProjektBlad }
        .sheet(isPresented: $visaKontakter) { Kontaktvy(kund: kund).onDisappear(perform: läsOm) }
        .sheet(isPresented: $visaImport) {
            Importvy(kund: kund, projekt: projekt, förvald: släpptFil, vidKlar: läsOm)
        }
        .sheet(item: $öppnad) { v in
            Transkriptvy(kund: kund, inspelning: v.inspelning, mapp: v.mapp)
                .onDisappear(perform: läsOm)
        }
        .sheet(isPresented: $visaMötesplockare) {
            Mötesplockare(kund: kund) {
                Task { await hämtaMöten() }
                läsOm()
            }
        }
        .sheet(item: $briefing) { m in
            Briefingvy(kund: kund, möte: m) { i, mapp in
                öppnad = Öppnad(inspelning: i, mapp: mapp)
            }
        }
        .confirmationDialog(
            "Flytta inspelningen till papperskorgen?",
            isPresented: Binding(get: { attKasta != nil }, set: { if !$0 { attKasta = nil } }),
            presenting: attKasta
        ) { v in
            Button("Flytta till papperskorgen", role: .destructive) {
                try? arkiv.kastaInspelning(i: v.mapp)
                attKasta = nil
                läsOm()
            }
            Button("Avbryt", role: .cancel) { attKasta = nil }
        } message: { v in
            Text("\(v.inspelning.titel) med ljud och transkript flyttas till papperskorgen. Du kan ta tillbaka den därifrån.")
        }
        .onAppear {
            läsOm()
            hämtaKontaktbilder()
            // Indexet hålls aktuellt från start — inte först när ett mejl
            // råkar hämtas eller chatten öppnas. Ändringskontrollen gör att
            // ett aktuellt index kostar nästan ingenting att bekräfta.
            indexeraIBakgrunden()
        }
        // Ett avslutat möte — och senare arkivtranskriptet, rösterna och
        // sammanfattningen — ska dyka upp utan att appen startas om.
        .onChange(of: arkiv.sparningar) { läsOm() }
        .task(id: kund.id) { await hämtaMöten() }
        .task(id: kund.id) { await visaMejl() }
        // Ett nyinbokat eller flyttat möte ska synas direkt.
        .onChange(of: kalender.ändringar) { Task { await hämtaMöten() } }
        // Och när man kommer tillbaka till appen efter att ha varit någon
        // annanstans är det troligt att något hänt.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await hämtaMöten()
                await visaMejl(äldreÄn: 5 * 60)
            }
        }
        // Mail säger inte till när något kommer in, så det får kollas med
        // jämna mellanrum. Sökningen tar sekunder, därför inte oftare.
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            Task { await visaMejl(äldreÄn: 15 * 60) }
        }
    }

    // MARK: - Översikt

    @ViewBuilder
    private var översikt: some View {
        mötesavsnitt
        projektavsnitt
        kontaktavsnitt
        if !inspelningar.isEmpty {
            avsnitt("Senaste inspelningarna") {
                inspelningslista(Array(inspelningar.prefix(3)))
            }
        }
    }

    @ViewBuilder
    private var mötesavsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Avsnittsrubrik(möten.isEmpty ? "Möten" : "Kommande möten")
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Ett möte räknas som kundens om någon deltagare finns "
                          + "bland kundens kontakter, har kundens mejldomän, eller "
                          + "om kundnamnet står i mötets titel. Andra möten läggs "
                          + "till för hand, och projektet väljs på raden.")
                Spacer()
                Button("Lägg till möte") { visaMötesplockare = true }
                    .buttonStyle(.link)
                    .help("Ta ett möte i anspråk som reglerna inte känner igen — "
                          + "till exempel ett utan deltagarlista")
            }
            mötesinnehåll
        }
    }

    @ViewBuilder
    private var mötesinnehåll: some View {
        Group {
            if möten.isEmpty {
                Text(kalender.harTillgång
                     ? "Inga inbokade möten med \(kund.namn) de närmaste veckorna."
                     : "Ge tillgång till Kalender för att se inbokade möten.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            VStack(spacing: 0) {
                ForEach(Array(möten.prefix(5).enumerated()), id: \.offset) { i, m in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.titel)
                            HStack(spacing: 6) {
                                Text(m.pågår ? "pågår nu" : närText(m.start))
                                let andra = m.deltagare.filter { !$0.ärJag }
                                if !andra.isEmpty {
                                    Text("· \(andra.map(\.namn).prefix(3).joined(separator: ", "))")
                                        .lineLimit(1)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if m.pågår {
                            Märke(text: "pågår", färg: .red)
                        }
                        if !projekt.isEmpty {
                            // Vilket projekt mötet hör till kan ingen regel
                            // gissa; det väljs här och följer med inspelningen.
                            Menu {
                                Button("Inget projekt") { koppla(m, till: nil) }
                                ForEach(projekt) { p in
                                    Button(p.namn) { koppla(m, till: p.namn) }
                                }
                                Divider()
                                Button("Hör inte till \(kund.namn)", role: .destructive) {
                                    try? arkiv.taBortMöteskoppling(m.id, för: kund)
                                    läsOm()
                                    Task { await hämtaMöten() }
                                }
                            } label: {
                                Label({ let p = möteskopplingar[m.id]
                                        return (p?.isEmpty == false) ? p! : "Projekt" }(),
                                      systemImage: "folder")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .foregroundStyle(möteskopplingar[m.id] == nil
                                             ? Color.secondary : Color.accentColor)
                            .help("Välj vilket projekt mötet hör till")
                        }
                        if let länk = m.möteslänk {
                            Button { NSWorkspace.shared.open(länk) } label: {
                                Image(systemName: "video")
                            }
                            .buttonStyle(.borderless)
                            .help("Öppna mötet")
                        }
                        Button("Förbered") { briefing = m }
                            .buttonStyle(.borderless)
                            .help("Senaste mötet, öppna åtaganden och nya mejl — läsningen inför mötet")
                        Button("Spela in") {
                            // Mötet bär titel, deltagare och sitt valda
                            // projekt. Mikrofonen är den som användes sist.
                            Inspelningsfönster.öppna(kund: kund,
                                                     projekt: kopplatProjekt(m),
                                                     möte: m)
                        }
                        .buttonStyle(.borderless)
                        .disabled(session.pågår)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if i < min(5, möten.count) - 1 { Divider() }
                }
            }
            .kort(hörn: Stil.radhörn)
            }
        }
    }

    private func koppla(_ m: Kalendern.Möte, till projektnamn: String?) {
        try? arkiv.kopplaMöte(m.id, till: projektnamn, för: kund)
        möteskopplingar = arkiv.möteskopplingar(för: kund)
    }

    private func kopplatProjekt(_ m: Kalendern.Möte) -> Projekt? {
        möteskopplingar[m.id].flatMap { namn in projekt.first { $0.namn == namn } }
    }

    /// "om 20 minuter", "i dag 14:00", "på torsdag" — närmare till hands än
    /// ett datum när allt som visas ligger framåt.
    private func närText(_ start: Date) -> String {
        let kalender = Calendar.current
        let om = start.timeIntervalSinceNow
        if om < 3600 {
            return "om \(max(1, Int(om / 60))) minuter"
        }
        if kalender.isDateInToday(start) {
            return "i dag \(DateFormatter.timme.string(from: start))"
        }
        if kalender.isDateInTomorrow(start) {
            return "i morgon \(DateFormatter.timme.string(from: start))"
        }
        if om < 7 * 24 * 3600 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "sv_SE")
            f.dateFormat = "EEEE HH:mm"
            return f.string(from: start)
        }
        return DateFormatter.klocka.string(from: start)
    }

    private var projektavsnitt: some View {
        avsnitt("Projekt", knapp: ("Nytt projekt", { visaNyttProjekt = true })) {
            if projekt.isEmpty {
                Text("Inga projekt än.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(projekt) { p in
                        Button { väljProjekt(p) } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(p.namn).lineLimit(1)
                                Spacer()
                            }
                            .padding(10)
                            .kort(hörn: Stil.radhörn)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var kontaktavsnitt: some View {
        avsnitt("Kontakter", knapp: ("Hantera", { visaKontakter = true })) {
            if kontakter.isEmpty {
                Text("Inga kontakter än.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(kontakter) { k in
                        HStack(spacing: 10) {
                            Kontaktsigill(kontakt: k, kund: kund, sida: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.namn)
                                if let r = k.roll {
                                    Text(r).font(.caption).foregroundStyle(.secondary)
                                } else if let e = k.förstaEpost {
                                    Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .kort(hörn: Stil.radhörn)
                    }
                }
            }
        }
    }

    // MARK: - Inspelningar

    @ViewBuilder
    private var inspelningsflik: some View {
        if !ofullständiga.isEmpty { ofullständigaAvsnitt }
        avsnitt("Inspelningar", knapp: ("Lägg till", { släpptFil = nil; visaImport = true })) {
            if inspelningar.isEmpty {
                Text("Inga inspelningar än. Släpp en ljud- eller videofil här för att lägga till en.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                inspelningslista(inspelningar)
            }
        }
    }

    /// Inspelningar vars ljud finns men vars transkript aldrig blev klart.
    private var ofullständigaAvsnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Påbörjade inspelningar").font(.headline)
            Text("Ljudet finns men transkriberingen blev aldrig klar.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(ofullständiga.enumerated()), id: \.offset) { i, rad in
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rad.mapp.lastPathComponent).lineLimit(1)
                            Text("\(rad.storlek / 1_000_000) MB ljud")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if kö.gäller(rad.mapp) {
                            ProgressView().controlSize(.small)
                            Text(kö.aktuell?.mapp == rad.mapp ? kö.steg : "I kö …")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            // Språket väljs här: en import som föll på fel
                            // språk ska inte behöva göras om från början.
                            Menu("Gör klart") {
                                Button("På svenska") { görKlart(rad.mapp, språk: "sv") }
                                Button("På engelska") { görKlart(rad.mapp, språk: "en") }
                                Button("Låt motorn avgöra") { görKlart(rad.mapp, språk: nil) }
                            }
                            .fixedSize()
                            Button {
                                try? arkiv.kastaInspelning(i: rad.mapp)
                                läsOm()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Flytta till papperskorgen")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if i < ofullständiga.count - 1 { Divider() }
                }
            }
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }

    /// Mappen säger var inspelningen hör hemma: under Samtal, eller under
    /// ett projekts Inspelningar. Tidigare hamnade allt på kundnivå, och
    /// projektkopplingen försvann.
    private func görKlart(_ mapp: URL, språk: String?) {
        let förälder = mapp.deletingLastPathComponent().standardizedFileURL
        let placering: Placering = projekt
            .first { $0.inspelningsmapp.standardizedFileURL == förälder }
            .map { .projekt($0) } ?? .kund(kund)
        kö.köaSlutförande(mapp: mapp, placering: placering, kund: kund, språk: språk)
    }

    private func inspelningslista(_ rader: [(Inspelning, URL)]) -> some View {
        Inspelningslista(kund: kund, rader: rader,
                         öppna: { öppnad = Öppnad(inspelning: $0, mapp: $1) },
                         kasta: { attKasta = Öppnad(inspelning: $0, mapp: $1) })
    }

    // MARK: - Mail

    @ViewBuilder
    private var mailflik: some View {
        mejlavsnitt
        if !bilagor.isEmpty { bilageavsnitt }
    }

    private var mejlavsnitt: some View {
        avsnitt("Mail", knapp: mejlknapp) {
            switch mejlLäge {
            case .ejHämtat:
                Text(kontakter.flatMap(\.epost).isEmpty
                     ? "Lägg till en kontakt med e-postadress för att kunna söka."
                     : "Inte hämtat än.")
                    .foregroundStyle(.secondary)
            case .hämtar(let vad):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(vad).foregroundStyle(.secondary)
                }
            case .fel(let text):
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .klar:
                if mejl.isEmpty {
                    Text("Inga mejl hittades.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(mejl.prefix(25).enumerated()), id: \.offset) { i, m in
                            Button { m.öppna() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: m.skickat ? "arrow.up" : "arrow.down")
                                        .font(.caption)
                                        .foregroundStyle(m.skickat ? Color.blue : Color.secondary)
                                        .frame(width: 12)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.ämne).lineLimit(1)
                                        Text("\(m.skickat ? "Du" : m.avsändarnamn) · \(m.datum.map(DateFormatter.klocka.string) ?? m.datumText)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if i < min(25, mejl.count) - 1 { Divider() }
                        }
                    }
                    .kort(hörn: Stil.radhörn)
                }
            }
        }
    }

    /// Bilagorna, med markering för vilka som gick att läsa text ur.
    /// Det är texten som är sökbar; en bild utan text säger inget.
    ///
    /// Hopfälld som standard. Ett par mejlväxlingar räcker för att ge trettio
    /// skärmdumpar, och då är det bilagorna man ser i mailfliken i stället för
    /// mejlen. Att de är sökbara är det som betyder något; namnen letar man
    /// sällan efter.
    private var bilageavsnitt: some View {
        let lästa = bilagor.filter { $0.text?.isEmpty == false }
        return DisclosureGroup(isExpanded: $visaBilagor) {
            VStack(spacing: 0) {
                ForEach(Array(bilagor.enumerated()), id: \.element.id) { i, b in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([b.url])
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: b.text?.isEmpty == false ? "doc.text.magnifyingglass" : "doc")
                                .foregroundStyle(b.text?.isEmpty == false ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.namn).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(b.ämne).lineLimit(1)
                                    Text("· \(b.storlek / 1024) kB")
                                    if let t = b.text, !t.isEmpty {
                                        Text("· \(t.count) tecken text")
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if i < bilagor.count - 1 { Divider() }
                }
            }
            .kort(hörn: Stil.radhörn)
            .padding(.top, 8)
        } label: {
            Text("Bilagor · \(lästa.count) av \(bilagor.count) sökbara").font(.headline)
        }
    }

    private var mejlknapp: (String, () -> Void)? {
        guard !kontakter.flatMap(\.epost).isEmpty else { return nil }
        if case .hämtar = mejlLäge { return nil }
        return (mejl.isEmpty ? "Hämta" : "Uppdatera", { Task { await hämtaMejl() } })
    }

    // MARK: - Stomme

    private func avsnitt<I: View>(_ rubrik: String,
                                  knapp: (String, () -> Void)? = nil,
                                  @ViewBuilder _ innehåll: () -> I) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Avsnittsrubrik(rubrik)
                Spacer()
                if let knapp { Button(knapp.0, action: knapp.1).buttonStyle(.link) }
            }
            innehåll()
        }
    }

    private var nyttProjektBlad: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nytt projekt hos \(kund.namn)").font(.headline)
            TextField("Namn", text: $nyttProjektnamn)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(skapaProjekt)
            HStack {
                Spacer()
                Button("Avbryt") { visaNyttProjekt = false; nyttProjektnamn = "" }
                Button("Skapa", action: skapaProjekt)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nyttProjektnamn.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Data

    private func skapaProjekt() {
        let namn = nyttProjektnamn.trimmingCharacters(in: .whitespaces)
        guard !namn.isEmpty else { return }
        _ = try? arkiv.skapaProjekt(namn: namn, hos: kund)
        nyttProjektnamn = ""
        visaNyttProjekt = false
        läsOm()
    }

    private func läsOm() {
        projekt = arkiv.projekt(för: kund)
        möteskopplingar = arkiv.möteskopplingar(för: kund)
        kontakter = arkiv.kontakter(för: kund)
        inspelningar = arkiv.inspelningar(för: kund)
        ofullständiga = arkiv.ofullständiga(för: kund)
    }

    /// Kopplade kontakter utan bild får sin profilbild ur macOS Kontakter,
    /// i tysthet — den som redan lagt in bilder där ska inte göra om jobbet.
    private func hämtaKontaktbilder() {
        guard adressbok.harTillgång else { return }
        Task {
            var ändrade = false
            for var k in arkiv.kontakter(för: kund)
            where k.systemID != nil && k.bild == nil {
                guard let data = adressbok.bilddata(för: k) else { continue }
                try? arkiv.sparaKontaktbild(data, för: &k, hos: kund)
                ändrade = true
            }
            if ändrade { kontakter = arkiv.kontakter(för: kund) }
        }
    }

    private func hämtaMöten() async {
        guard kalender.harTillgång else { return }
        let mina = arkiv.kontakter(för: kund)
        let kopplade = arkiv.möteskopplingar(för: kund)
        // Reglerna tar de flesta, men ett möte utan deltagare och utan
        // kundnamn i titeln kan ingen regel känna igen — de tas i anspråk
        // för hand och känns igen på att nyckeln finns.
        möten = kalender.möten().filter {
            kopplade[$0.id] != nil || Kalendern.hör($0, till: kund, kontakter: mina)
        }
    }

    /// - Parameter äldreÄn: hämta om cachen är äldre än så här. Timern och
    ///   återkomsten till appen använder olika gränser: den som just kommit
    ///   tillbaka vill se det senaste, medan en timer som går hela dagen inte
    ///   ska söka i Mail i onödan.
    private func visaMejl(äldreÄn: TimeInterval = 15 * 60) async {
        // Kontakterna läses här och inte ur vyns tillstånd: den fylls av
        // onAppear, som kan hinna köra efter den här uppgiften.
        let adresser = Array(Set(arkiv.kontakter(för: kund).flatMap(\.epost))).prefix(5)
        guard !adresser.isEmpty else { return }

        guard let cache = arkiv.mailcache(för: kund) else {
            // Ingen cache alls: kunden har aldrig hämtat mejl. Att avbryta här
            // gjorde att första hämtningen aldrig skedde av sig själv.
            await hämtaMejl()
            return
        }
        mejl = cache.mejl
        bilagor = cache.bilagor
        mejlLäge = .klar

        if cache.ålder >= äldreÄn {
            await hämtaMejl()
        } else if cache.bilagor.isEmpty {
            // Mejlen kan vara färska men hämtade innan bilagorna fanns med.
            // Då ska bilagorna hämtas för sig, inte vänta på att cachen
            // åldras ut.
            await hämtaBilagor(Array(adresser))
            mejlLäge = .klar
        }
    }

    private func hämtaMejl() async {
        // Timern, återkomsten till appen och knappen kan alla vilja hämta.
        // Två sökningar samtidigt skrev tidigare över varandras resultat.
        if case .hämtar = mejlLäge { return }
        let adresser = Array(Set(arkiv.kontakter(för: kund).flatMap(\.epost))).prefix(5)
        guard !adresser.isEmpty else { return }
        mejlLäge = .hämtar("Söker i Mail …")
        let mailen = Mailen()
        var samlat: [Mailen.Mejl] = []
        do {
            for a in adresser { samlat += try await mailen.sök(adress: a, max: 20) }
        } catch {
            mejlLäge = .fel(error.localizedDescription)
            return
        }
        var sedda = Set<String>()
        mejl = samlat.filter { sedda.insert($0.id).inserted }
            .sorted { ($0.datum ?? .distantPast) > ($1.datum ?? .distantPast) }
        try? arkiv.sparaMail(mejl, bilagor: bilagor, för: kund)

        await hämtaBilagor(Array(adresser))
        mejlLäge = .klar
    }

    private func hämtaBilagor(_ adresser: [String]) async {
        let skript = URL(fileURLWithPath: Bundle.main.bundlePath)
            .appending(path: "Contents/Resources/mail-bilagor.applescript")
        guard FileManager.default.fileExists(atPath: skript.path) else {
            mejlLäge = .fel("Skriptet som hämtar bilagor saknas i appen.")
            return
        }

        mejlLäge = .hämtar("Hämtar bilagor …")
        let mapp = kund.mailmapp.appending(path: "Bilagor")
        var hittade: [Bilagor.Bilaga] = []
        for a in adresser {
            do {
                hittade += try await Bilagor.hämta(adress: a, till: mapp, skript: skript)
            } catch {
                // Ett tyst misslyckande här var orsaken till att bilagorna
                // aldrig dök upp: felet syntes ingenstans.
                mejlLäge = .fel("Bilagorna kunde inte hämtas: \(error.localizedDescription)")
                return
            }
        }
        var sedda = Set<String>()
        hittade = hittade.filter { sedda.insert($0.fil).inserted }
        guard !hittade.isEmpty else { return }

        // Text som redan lästs ut behålls: bildtolkningen tar sekunder per
        // bilaga, och den kördes tidigare om på allt vid varje uppdatering.
        var kända: [String: Bilagor.Bilaga] = [:]
        for b in bilagor + (arkiv.mailcache(för: kund)?.bilagor ?? []) where b.text != nil {
            kända[b.fil] = b
        }
        for (i, b) in hittade.enumerated() {
            if let k = kända[b.fil], k.storlek == b.storlek {
                hittade[i].text = k.text
                continue
            }
            mejlLäge = .hämtar("Läser bilaga \(i + 1) av \(hittade.count) — \(b.namn)")
            hittade[i].text = await Bilagor.text(ur: b)
        }
        bilagor = hittade
        try? arkiv.sparaMail(mejl, bilagor: hittade, för: kund)
        indexeraIBakgrunden()
        // Nya mejl kan bära åtaganden. Görs efter indexeringen, i bakgrunden,
        // så att listan inte står och väntar.
        let mejlen = mejl
        Task { await Uppgiftssamling.frånMejl(mejlen, kund: kund) }
    }

    /// Håller indexet aktuellt utan att man behöver öppna chatten.
    ///
    /// Sökningen bygger inga index — den läser dem som finns. Utan det här
    /// blev nyhämtade mejl och bilagor osökbara tills chatten öppnats.
    private func indexeraIBakgrunden() {
        let kund = kund, arkiv = arkiv
        Task.detached(priority: .utility) {
            guard let bank = try? Kunskapsbank(kund: kund) else { return }
            try? Indexering.kör(för: kund, bank: bank, arkiv: arkiv)
            await Inbäddare.kör(bank: bank)
        }
    }
}

/// Lista över inspelningar, med papperskorg vid hovring.
///
/// Raden säger också hur mötet mår: om arkivpasset pågår, föll eller
/// avbröts — och en omkörning finns i högerklicksmenyn. Tidigare stod ett
/// möte vars bearbetning gått fel som «live» för alltid, utan väg tillbaka.
struct Inspelningslista: View {
    let kund: Kund
    let rader: [(Inspelning, URL)]
    var öppna: (Inspelning, URL) -> Void
    var kasta: (Inspelning, URL) -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var session: Inspelningssession
    @ObservedObject private var kö = Importkö.delad
    @State private var hovrad: Int?
    @State private var namnbyte: Byte?

    struct Byte: Identifiable {
        let inspelning: Inspelning
        let mapp: URL
        var id: UUID { inspelning.id }
    }

    var body: some View {
        lista
            .sheet(item: $namnbyte) { v in
                Namnblad(rubrik: "Byt namn på mötet", nuvarande: v.inspelning.titel,
                         förklaring: "Mappen döps om med den nya titeln, och uppgifterna "
                            + "som kom ur mötet följer med.") { nytt in
                    _ = try arkiv.döpOm(v.inspelning, i: v.mapp, till: nytt, hos: kund)
                }
            }
    }

    private var lista: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rader.enumerated()), id: \.offset) { i, rad in
                ZStack(alignment: .trailing) {
                    Button { öppna(rad.0, rad.1) } label: { innehåll(rad.0, mapp: rad.1) }
                        .buttonStyle(.plain)
                    if hovrad == i {
                        Button { kasta(rad.0, rad.1) } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Flytta inspelningen till papperskorgen")
                        .padding(.trailing, 12)
                    }
                }
                .onHover { hovrar in hovrad = hovrar ? i : (hovrad == i ? nil : hovrad) }
                .contextMenu {
                    Button("Visa i Finder") { NSWorkspace.shared.open(rad.1) }
                    if !bearbetas(rad.1) {
                        Button("Byt namn …") { namnbyte = Byte(inspelning: rad.0, mapp: rad.1) }
                        flyttmeny(rad.0, rad.1)
                        Menu("Efterbearbeta igen") {
                            Button("På svenska") { körOm(rad.0, rad.1, språk: "sv") }
                            Button("På engelska") { körOm(rad.0, rad.1, språk: "en") }
                            Button("Låt motorn avgöra") { körOm(rad.0, rad.1, språk: nil) }
                        }
                    }
                    Divider()
                    Button("Flytta till papperskorgen", role: .destructive) { kasta(rad.0, rad.1) }
                }
                if i < rader.count - 1 { Divider() }
            }
        }
        .kort(hörn: Stil.radhörn)
    }

    private func innehåll(_ i: Inspelning, mapp: URL) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.titel)
                HStack(spacing: 6) {
                    Text(DateFormatter.klocka.string(from: i.inledd))
                    if let p = i.projekt { Text("· \(p)") }
                    if i.enspårig { Text("· importerad") }
                    let namn = Set(i.röstnamn.values).sorted()
                    if !namn.isEmpty { Text("· \(namn.joined(separator: ", "))").lineLimit(1) }
                    if let steg = pågår(mapp) {
                        ProgressView().controlSize(.mini)
                        Text(steg).foregroundStyle(.orange)
                    } else if let fel = i.arkivfel {
                        Märke(text: "fel", färg: .red, ikon: "exclamationmark.triangle")
                            .help("Efterbearbetningen misslyckades: \(fel)\nHögerklicka för att köra om.")
                    } else if i.avbruten {
                        Märke(text: "avbruten", färg: .orange, ikon: "pause")
                            .help("Efterbearbetningen avbröts. Högerklicka för att köra om.")
                    } else if !i.efterbearbetad {
                        Märke(text: "live", färg: .orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formateraLängd(i.längd))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(.rect)
    }

    private func bearbetas(_ mapp: URL) -> Bool {
        session.bearbetadMapp == mapp || kö.gäller(mapp)
    }

    /// Kundnivån, kundens projekt, och andra kunder med sina projekt. Ett
    /// möte som startats hos fel kund gick tidigare bara att rätta i Finder,
    /// med handredigerad JSON.
    private func flyttmeny(_ i: Inspelning, _ mapp: URL) -> some View {
        Menu("Flytta till") {
            if i.projekt != nil {
                Button("\(kund.namn) — kundnivå") { flytta(i, mapp, till: .kund(kund)) }
            }
            ForEach(arkiv.projekt(för: kund).filter { $0.namn != i.projekt }) { p in
                Button(p.namn) { flytta(i, mapp, till: .projekt(p)) }
            }
            let andra = arkiv.kunder.filter { $0 != kund }
            if !andra.isEmpty {
                Divider()
                ForEach(andra) { annan in
                    Menu(annan.namn) {
                        Button("Kundnivå") { flytta(i, mapp, till: .kund(annan)) }
                        ForEach(arkiv.projekt(för: annan)) { p in
                            Button(p.namn) { flytta(i, mapp, till: .projekt(p)) }
                        }
                    }
                }
            }
        }
    }

    private func flytta(_ i: Inspelning, _ mapp: URL, till placering: Placering) {
        guard !bearbetas(mapp) else { return }
        _ = try? arkiv.flytta(i, från: mapp, till: placering, hos: kund)
    }

    /// Var bearbetningen står, för raden vars inspelning just nu jobbas på.
    private func pågår(_ mapp: URL) -> String? {
        if session.bearbetadMapp == mapp {
            if session.sammanfattar { return "Sammanfattar …" }
            if session.analyserarRöster { return "Delar upp röster …" }
            if session.efterbearbetar {
                return "Transkriberar \(Int(session.efterbearbetningsandel * 100)) % …"
            }
        }
        if kö.aktuell?.mapp == mapp {
            return kö.andel.map { "\(kö.steg) \(Int($0 * 100)) % …" } ?? "\(kö.steg) …"
        }
        if kö.väntande.contains(where: { $0.mapp == mapp }) { return "I kö …" }
        return nil
    }

    /// Kör arkivpasset igen. Namn som satts för hand lärs först in som
    /// röstavtryck, så att personerna känns igen när rösterna delas om.
    private func körOm(_ i: Inspelning, _ mapp: URL, språk: String?) {
        let placering: Placering = i.projekt.flatMap { namn in
            arkiv.projekt(för: kund).first { $0.namn == namn }.map { .projekt($0) }
        } ?? .kund(kund)
        Task {
            if !i.röstnamn.isEmpty {
                _ = await Röstanalys().lärIn(i, mapp: mapp, kund: kund, arkiv: arkiv)
            }
            kö.köaOmkörning(i, mapp: mapp, placering: placering, kund: kund, språk: språk)
        }
    }
}

/// Väljaren för möten som reglerna inte känner igen.
///
/// Kalenderposter utan deltagarlista och utan kundnamn i titeln — vanligt
/// när en inbjudan vidarebefordrats eller skrivits in för hand — kan ingen
/// regel para ihop med en kund. Här tas de i anspråk med ett klick.
struct Mötesplockare: View {
    let kund: Kund
    var vidVal: () -> Void

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var kalender: Kalendern
    @Environment(\.dismiss) private var stäng

    @State private var kandidater: [Kalendern.Möte] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lägg till möte hos \(kund.namn)").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()

            if kandidater.isEmpty {
                TomtLäge(ikon: "calendar", rubrik: "Inga fler möten",
                         text: "Alla kommande möten i kalendern hör redan till någon kund.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(kandidater.enumerated()), id: \.element.id) { i, m in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.titel)
                                    Text(DateFormatter.klocka.string(from: m.start))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Lägg till") {
                                    try? arkiv.kopplaMöte(m.id, till: nil, för: kund)
                                    vidVal()
                                    stäng()
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            if i < kandidater.count - 1 { Divider() }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Stäng") { stäng() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 380)
        .onAppear(perform: läsIn)
    }

    /// Alla kommande möten som inte redan hör till någon kund.
    private func läsIn() {
        // En kalenderfråga, inte en per kund.
        let alla = kalender.möten()
        var tagna = Set<String>()
        for k in arkiv.kunder {
            let kontakter = arkiv.kontakter(för: k)
            let kopplade = arkiv.möteskopplingar(för: k)
            for m in alla
            where kopplade[m.id] != nil || Kalendern.hör(m, till: k, kontakter: kontakter) {
                tagna.insert(m.id)
            }
        }
        kandidater = alla.filter { !tagna.contains($0.id) }
    }
}
