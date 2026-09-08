import SwiftUI
import AppKit

/// Ett möte, efter mötet.
///
/// Transkriptet är sällan det man vill läsa. Det man vill veta är vad mötet
/// landade i, vad någon lovade, och svaret på den fråga man kom hit med —
/// därför ligger sammanfattningen först, uppgifterna bredvid och en chatt som
/// har hela samtalet som underlag i panelen till höger.
struct Transkriptvy: View {
    let kund: Kund
    @State var inspelning: Inspelning
    @State var mapp: URL
    @Environment(\.dismiss) private var stäng
    @EnvironmentObject private var arkiv: Arkivet

    @State private var visaRöster = false
    @State private var visaChatt = Inställningar.mötesChattPå
    @State private var flik: Flik = .sammanfattning
    @State private var uppgifter: [Uppgift] = []
    @State private var redigerad: Uppgift?
    @State private var ny = ""
    @State private var sammanfattar = false
    @State private var fel: String?
    @ObservedObject private var kö = Importkö.delad
    @EnvironmentObject private var session: Inspelningssession
    @StateObject private var spelare = Yttrandespelare()
    @State private var hovrad: UUID?
    /// Tiden man drar mot i spelaren, tills fingret släpper.
    @State private var dragTid: Double?
    /// Närmast föregående möte i samma serie, när det finns ett.
    @State private var förra: (Inspelning, URL)?
    /// Åtaganden från förra mötet som fortfarande är öppna.
    @State private var kvarSedanSist = 0

    private enum Flik: String, CaseIterable, Identifiable {
        case sammanfattning, transkript, attGöra
        var id: String { rawValue }
        var namn: String {
            switch self {
            case .sammanfattning: "Sammanfattning"
            case .transkript: "Transkript"
            case .attGöra: "Att göra"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                rubrik
                Divider()
                Picker("", selection: $flik) {
                    ForEach(Flik.allCases) { f in
                        Text(f == .attGöra && !uppgifter.isEmpty
                             ? "\(f.namn) \(uppgifter.count)" : f.namn).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                switch flik {
                case .sammanfattning: sammanfattningsflik
                case .transkript: transkriptflik
                case .attGöra: uppgiftsflik
                }

                Divider()
                HStack {
                    if let körOmSteg {
                        ProgressView().controlSize(.small)
                        Text(körOmSteg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let fel {
                        Text(fel).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                    Spacer()
                    Button("Stäng") { stäng() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("möte.stäng")
                }
                .padding(16)
            }
            .frame(width: 700)

            if visaChatt {
                Divider()
                Chattpanel(kund: kund, projekt: projekt, möte: inspelning, mötesmapp: mapp,
                           extraUnderlag: förraSomUnderlag)
                    .id(inspelning.id)
                    .frame(width: 400)
            }
        }
        .frame(height: 660)
        .onAppear {
            läsUppgifter()
            spelare.ladda(mapp: mapp, inspelning: inspelning)
        }
        .onDisappear { spelare.sluta() }
        // En omkörning i bakgrunden skriver möte.json; vyn ska följa med.
        .onChange(of: arkiv.sparningar) { läsOmFrånDisk() }
        .sheet(isPresented: $visaRöster) {
            Röstvy(kund: kund, mapp: mapp, inspelning: inspelning) { inspelning = $0 }
        }
        .sheet(item: $redigerad) { u in
            Uppgiftsredigering(uppgift: u, kund: kund, vidSparat: läsUppgifter)
        }
    }

    // MARK: - Rubrik

    private var rubrik: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(inspelning.titel).font(.headline)
                Text("\(DateFormatter.klocka.string(from: inspelning.inledd)) · \(formateraLängd(inspelning.längd))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let arkivfel = inspelning.arkivfel {
                Märke(text: "fel", färg: .red, ikon: "exclamationmark.triangle")
                    .help("Efterbearbetningen misslyckades: \(arkivfel)")
            } else if inspelning.avbruten && körOmSteg == nil {
                Märke(text: "avbruten", färg: .orange, ikon: "pause")
                    .help("Efterbearbetningen avbröts. Kör om den med pilknappen.")
            } else if !inspelning.efterbearbetad {
                Märke(text: "live", färg: .orange)
            }
            // Knappen ska finnas även när uppdelningen inte gav några
            // grupper — det är ju precis då man vill köra om den med ett
            // angivet antal.
            if inspelning.yttranden.contains(where: { $0.röst == .motpart }) {
                Button {
                    visaRöster = true
                } label: {
                    Label("Vem är vem", systemImage: "person.wave.2")
                }
                .help("Dela upp rösterna på motpartsspåret och sätt namn")
                .accessibilityIdentifier("möte.vem-är-vem")
            }
            if Obsidian.finns {
                Button {
                    Obsidian.öppna(mapp.appending(path: "Transkript.md"), valvrot: kund.mapp)
                } label: {
                    Image(systemName: "book.closed")
                }
                .help("Öppna transkriptet i Obsidian")
            }
            Button {
                NSWorkspace.shared.open(mapp)
            } label: {
                Image(systemName: "folder")
            }
            .help("Visa i Finder")
            // Fel språk, en motor som saknades, ett pass som avbröts: ljudet
            // finns kvar, så allt går att köra om — även för möten som
            // spelats in i appen, med båda spåren.
            Menu {
                ForEach(Mötesspråk.val, id: \.kod) { s in
                    Button("Transkribera om på \(s.namn.lowercased())") { transkriberaOm(s.kod) }
                }
                Divider()
                Button("Transkribera om — avgör själv") { transkriberaOm(nil) }
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(körOmSteg != nil)
            .help("Kör om transkribering, röster och sammanfattning på valt språk")
            Button {
                visaChatt.toggle()
                Inställningar.mötesChattPå = visaChatt
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .help(visaChatt ? "Dölj chatten" : "Fråga om mötet")
        }
        .padding(16)
    }

    // MARK: - Flikar

    @ViewBuilder
    private var sammanfattningsflik: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if förra != nil { förraGången }
                if let s = inspelning.sammanfattning, !s.tom || !s.kärna.isEmpty {
                    if !s.kärna.isEmpty {
                        Text(s.kärna)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !s.beslut.isEmpty { punktlista("Beslut", s.beslut) }
                    if !s.öppet.isEmpty { punktlista("Öppna frågor", s.öppet) }
                    if !s.beslut.isEmpty || !s.öppet.isEmpty || !uppgifter.isEmpty {
                        Divider()
                    }
                    if !uppgifter.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Att göra").font(.subheadline.weight(.semibold))
                            Text("\(uppgifter.count) på tavlan")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 16) {
                        Button("Skriv uppföljningsmejl") { uppföljningsmejl() }
                            .help("Öppnar ett utkast i Mail med beslut och åtaganden. Inget skickas.")
                        Button(sammanfattar ? "Skriver om …" : "Skriv om sammanfattningen") {
                            Task { await sammanfatta() }
                        }
                        .disabled(sammanfattar)
                        .buttonStyle(.link)
                    }
                } else {
                    saknasSammanfattning
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    /// Serien binder ihop återkommande möten: samma titel så när som på
    /// siffrorna. Det man vill veta inför och efter ett 1:1 är nästan alltid
    /// vad som sades på förra.
    @ViewBuilder
    private var förraGången: some View {
        if let (f, _) = förra {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Förra gången · \(DateFormatter.dag.string(from: f.inledd))",
                          systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Öppna") { if let förra { visa(förra) } }
                        .buttonStyle(.link)
                }
                if let kärna = f.sammanfattning?.kärna, !kärna.isEmpty {
                    Text(kärna)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if kvarSedanSist > 0 {
                    Text(kvarSedanSist == 1
                         ? "1 åtagande därifrån är fortfarande öppet"
                         : "\(kvarSedanSist) åtaganden därifrån är fortfarande öppna")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        }
    }

    /// Byter till ett annat möte i samma vy — bläddring i serien.
    private func visa(_ annat: (Inspelning, URL)) {
        inspelning = annat.0
        mapp = annat.1
        läsUppgifter()
        spelare.ladda(mapp: mapp, inspelning: inspelning)
    }

    private var saknasSammanfattning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ingen sammanfattning än")
                .font(.subheadline.weight(.semibold))
            Text("En modell läser igenom mötet och skriver vad det handlade om, "
                 + "vad som beslutades och vad någon lovade att göra. "
                 + "Åtagandena hamnar på tavlan.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let orsak = inspelning.sammanfattningsfel {
                Label(orsak, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(sammanfattar ? "Sammanfattar …" : "Sammanfatta mötet") {
                Task { await sammanfatta() }
            }
            .disabled(sammanfattar || inspelning.yttranden.isEmpty)
            if sammanfattar { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private var transkriptflik: some View {
        VStack(spacing: 0) {
            ScrollViewReader { rulle in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(inspelning.yttranden) { y in
                            transkriptrad(y).id(y.id)
                        }
                    }
                    .padding(14)
                }
                // Raden som hörs ska synas — men bara medan ljudet spelar,
                // så att den som rullar själv inte rycks tillbaka.
                .onChange(of: spelare.aktuell) {
                    if spelare.igång, let id = spelare.aktuell {
                        withAnimation { rulle.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Divider()
            spelarrad
        }
    }

    private func transkriptrad(_ y: Yttrande) -> some View {
        let hörs = spelare.aktuell == y.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(y.etikett(inspelning.röstnamn, enspårig: inspelning.enspårig))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(färg(y))
                Text(y.tidsstämpel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                // Transkriptet är whispers ord; ljudet är facit. Knappen
                // spelar härifrån och vidare, i stället för bara raden.
                Button {
                    spelare.växla(y)
                } label: {
                    Image(systemName: hörs && spelare.igång ? "pause.fill" : "play.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hörs ? Color.accentColor : Color.secondary)
                .opacity(hörs || hovrad == y.id ? 1 : 0)
                .help(hörs && spelare.igång ? "Pausa" : "Spela upp härifrån")
            }
            Text(y.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(hörs ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: .rect(cornerRadius: 6))
        .onHover { över in hovrad = över ? y.id : (hovrad == y.id ? nil : hovrad) }
    }

    /// Spelaren längst ned i transkriptfliken: spela, pausa, dra i tiden.
    private var spelarrad: some View {
        HStack(spacing: 12) {
            Button {
                spelare.växla()
            } label: {
                Image(systemName: spelare.igång ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(!spelare.harLjud)
            .help(spelare.igång ? "Pausa" : "Spela upp mötet")
            Text(formateraLängd(dragTid ?? spelare.tid))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Slider(value: Binding(get: { dragTid ?? spelare.tid },
                                  set: { dragTid = $0 }),
                   in: 0...max(1, spelare.längd)) { drar in
                // Hoppet görs när fingret släpper, inte för varje pixel.
                if !drar, let t = dragTid {
                    spelare.hoppa(till: t)
                    dragTid = nil
                }
            }
            .disabled(!spelare.harLjud)
            Text(formateraLängd(spelare.längd))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if !spelare.harLjud {
                Text("Ljudet saknas i mappen")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var uppgiftsflik: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if uppgifter.isEmpty {
                        Text(inspelning.sammanfattning == nil
                             ? "Åtagandena plockas ut när mötet sammanfattas."
                             : "Mötet gav inga åtaganden.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(uppgifter) { u in uppgiftsrad(u) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Lägg till något ur mötet", text: $ny)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(läggTill)
                Button("Lägg till", action: läggTill)
                    .disabled(ny.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
    }

    private func uppgiftsrad(_ u: Uppgift) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                bocka(u)
            } label: {
                Image(systemName: u.läge == .klart ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(u.läge == .klart ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(u.vad)
                    .strikethrough(u.läge == .klart)
                    .foregroundStyle(u.läge == .klart ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if u.vem != nil || u.när != nil {
                    Text([u.vem, u.när].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if u.läge == .pågår {
                Text("Pågår").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        .onTapGesture { redigerad = u }
    }

    private func punktlista(_ rubrik: String, _ rader: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rubrik).font(.subheadline.weight(.semibold))
            ForEach(Array(rader.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").foregroundStyle(.secondary)
                    Text(r).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Handling

    private var projekt: Projekt? {
        inspelning.projekt.flatMap { namn in
            arkiv.projekt(för: kund).first { $0.namn == namn }
        }
    }

    /// Uppgifterna som kom ur det här mötet. Tavlan är sanningen — det som
    /// står i sammanfattningen är en ögonblicksbild från när den skrevs.
    private func läsUppgifter() {
        uppgifter = arkiv.uppgifter(för: kund)
            .filter { Uppgiftssamling.hör($0, till: mapp, titel: inspelning.titel) }
            .sorted { $0.skapad < $1.skapad }
        förra = Mötesserie.föregående(inspelning, bland: arkiv.inspelningar(för: kund))
        kvarSedanSist = förra.map { f in
            arkiv.uppgifter(för: kund)
                .filter { Uppgiftssamling.hör($0, till: f.1, titel: f.0.titel) }
                .filter { $0.läge != .klart }
                .count
        } ?? 0
    }

    /// Förra mötets sammanfattning som underlag åt chatten, så att "vad sa
    /// vi förra gången?" har något att stå på även utan sökträff.
    private var förraSomUnderlag: [Kunskapsbank.Träff] {
        guard let (f, m) = förra, let s = f.sammanfattning, !s.kärna.isEmpty else { return [] }
        var text = s.kärna
        if !s.beslut.isEmpty { text += "\nBeslut: " + s.beslut.joined(separator: "; ") }
        if !s.öppet.isEmpty { text += "\nÖppet: " + s.öppet.joined(separator: "; ") }
        return [Kunskapsbank.Träff(
            id: -2, typ: "sammanfattning", titel: "Förra mötet · \(f.titel)",
            text: text, källa: m.appending(path: "möte.json").path,
            tid: f.inledd, poäng: 0)]
    }

    private func bocka(_ u: Uppgift) {
        var ändrad = u
        ändrad.läge = u.läge == .klart ? .attGöra : .klart
        try? arkiv.uppdatera(ändrad, för: kund)
        läsUppgifter()
    }

    private func läggTill() {
        let text = ny.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        try? arkiv.läggTill([Uppgift(vad: text, ursprung: .möte, källa: mapp.path,
                                     källtitel: inspelning.titel,
                                     projekt: inspelning.projekt)], för: kund)
        ny = ""
        läsUppgifter()
    }

    /// Ett utkast i Mail ur det mötet landade i. Skickas aldrig härifrån.
    private func uppföljningsmejl() {
        let text = Uppföljning.brödtext(för: inspelning)
        guard !text.isEmpty else { return }
        let till = Uppföljning.mottagare(för: inspelning,
                                         kontakter: arkiv.kontakter(för: kund))
        let ämne = "Uppföljning: \(inspelning.titel)"
        Task {
            do {
                try await Uppföljning.öppnaUtkast(ämne: ämne, text: text, till: till)
            } catch {
                fel = error.localizedDescription
            }
        }
    }

    /// Var en omkörning av det här mötet står, om en pågår.
    private var körOmSteg: String? {
        if kö.aktuellMapp == mapp {
            return kö.andel.map { "\(kö.steg) · \(Int($0 * 100)) %" } ?? kö.steg
        }
        if kö.väntande.contains(where: { $0.mapp == mapp }) { return "I kö …" }
        if session.bearbetadMapp == mapp { return "Efterbearbetas …" }
        return nil
    }

    /// Gör om hela inspelningen från ljudet: transkribering på valt språk,
    /// röstuppdelning, sammanfattning. Mötet behåller sitt id, så chattar
    /// och kopplingar överlever; namn som satts för hand lärs in som
    /// röstavtryck först, så att personerna känns igen i den nya
    /// uppdelningen. Arbetet går i kön längst ned, och vyn läser om sig
    /// själv när det är klart.
    private func transkriberaOm(_ språk: String?) {
        guard körOmSteg == nil else { return }
        fel = nil
        spelare.sluta()
        let placering: Placering = projekt.map { .projekt($0) } ?? .kund(kund)
        let i = inspelning
        Task {
            if !i.röstnamn.isEmpty {
                _ = await Röstanalys().lärIn(i, mapp: mapp, kund: kund, arkiv: arkiv)
            }
            kö.köaOmkörning(i, mapp: mapp, placering: placering, kund: kund, språk: språk)
        }
    }

    /// Läser om mötet från möte.json, när något skrivit den i bakgrunden.
    private func läsOmFrånDisk() {
        guard let data = try? Data(contentsOf: mapp.appending(path: "möte.json")),
              let ny = try? JSONDecoder.kundkoll.decode(Inspelning.self, from: data),
              ny.id == inspelning.id, ny != inspelning else { return }
        inspelning = ny
        läsUppgifter()
        // Nya rader efter en omkörning: spelaren ska peka på dem, inte de
        // gamla. Mitt i en uppspelning får den vänta.
        if !spelare.igång { spelare.ladda(mapp: mapp, inspelning: inspelning) }
    }

    private func sammanfatta() async {
        sammanfattar = true
        fel = nil
        defer { sammanfattar = false }
        do {
            let s = try await Sammanfattare().skriv(för: inspelning, kund: kund.namn)
            inspelning.sammanfattning = s
            try arkiv.spara(inspelning, i: mapp)
            Uppgiftssamling.frånMöte(s, inspelning: inspelning, mapp: mapp)
            läsUppgifter()
        } catch {
            fel = error.localizedDescription
        }
    }

    /// Egen färg per röst, så att man ser talarbyten utan att läsa namnen.
    private func färg(_ y: Yttrande) -> Color {
        guard y.röst == .motpart || inspelning.enspårig else { return .blue }
        let paletten: [Color] = [.purple, .orange, .teal, .pink, .indigo, .brown]
        guard let g = y.röstgrupp else { return .purple }
        return paletten[g % paletten.count]
    }
}
