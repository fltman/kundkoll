import SwiftUI
import AppKit

/// Innehållet i inspelningsfönstret.
///
/// Startas den från ett kalendermöte finns titel och deltagare redan, och
/// mikrofonen är den som användes sist — då börjar inspelningen direkt. Ett
/// möte inleds sällan med att man vill fylla i ett formulär.
struct Inspelningsvy: View {
    let kund: Kund
    var projekt: Projekt?
    var möte: Kalendern.Möte?

    @EnvironmentObject private var arkiv: Arkivet
    @EnvironmentObject private var session: Inspelningssession

    @State private var titel = ""
    @State private var valtProjekt: Projekt?
    @State private var språk = "sv"
    @State private var mikrofoner: [Ljudinfångning.Mikrofon] = []
    @State private var valdMikrofon: Ljudinfångning.Mikrofon?
    @State private var projektlista: [Projekt] = []

    /// Mikrofonen man valde sist. Den är nästan alltid rätt igen.
    @AppStorage("kundkoll.mikrofon") private var sparadMikrofon = ""

    var body: some View {
        VStack(spacing: 0) {
            switch session.läge {
            case .vilande, .fel:
                uppstart
            case .förbereder(let steg):
                förbereder(steg)
            case .spelarIn, .avslutar:
                pågående
            case .klar(let mapp):
                klar(mapp)
            }
        }
        .frame(minWidth: session.pågår ? 820 : 460, minHeight: 540)
        .onAppear(perform: förbered)
    }

    private func förbered() {
        mikrofoner = Ljudinfångning.mikrofoner()
        valdMikrofon = mikrofoner.first { $0.id == sparadMikrofon } ?? mikrofoner.first
        projektlista = arkiv.projekt(för: kund)
        valtProjekt = projekt
        if titel.isEmpty { titel = möte?.titel ?? "" }

        // Startat från ett möte: allt som behövs är redan känt.
        if möte != nil, case .vilande = session.läge, valdMikrofon != nil {
            starta()
        }
    }

    // MARK: - Innan

    private var uppstart: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ny inspelning").font(.title2.weight(.semibold))

            Form {
                TextField("Vad gäller samtalet?", text: $titel)
                Picker("Hör till", selection: $valtProjekt) {
                    Text(kund.namn).tag(Projekt?.none)
                    ForEach(projektlista) { p in Text(p.namn).tag(Projekt?.some(p)) }
                }
                Picker("Språk", selection: $språk) {
                    Text("Svenska").tag("sv")
                    Text("Engelska").tag("en")
                }
                .help("Liven transkriberar på det valda språket, och arkivpasset "
                      + "efteråt likaså. KB-Whisper översätter engelska till "
                      + "svenska, så engelska möten tar arkivvägen via MLX eller "
                      + "molnet.")
                Picker("Mikrofon", selection: $valdMikrofon) {
                    ForEach(mikrofoner) { m in Text(m.namn).tag(Ljudinfångning.Mikrofon?.some(m)) }
                }
            }
            .formStyle(.grouped)

            Label("Datorljudet spelas in på ett eget spår, så att du och motparten hålls isär i transkriptet.",
                  systemImage: "waveform")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .fel(let text) = session.läge {
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Button("Avbryt") {
                    // Ett fel som lämnas kvar i sessionen låste tidigare
                    // nästa «Spela in» tills appen startats om.
                    session.återställ()
                    Inspelningsfönster.stäng()
                }
                Spacer()
                Button(action: starta) {
                    Label("Spela in", systemImage: "record.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(valdMikrofon == nil)
            }
        }
        .padding(20)
    }

    private func förbereder(_ steg: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(steg).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Under

    private var pågående: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 9, height: 9).symbolEffect(.pulse)
                Text(formateraLängd(session.förfluten))
                    .font(.title3.monospacedDigit())
                Text(session.titel).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                mätare("Jag", session.nivåJag, .blue)
                mätare("Motpart", session.nivåMotpart, .purple)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let varning = session.livevarning {
                Label(varning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }

            HStack(spacing: 0) {
                ScrollViewReader { rulle in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.yttranden) { y in rad(y).id(y.id) }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: session.yttranden.count) {
                        if let sista = session.yttranden.last {
                            withAnimation { rulle.scrollTo(sista.id, anchor: .bottom) }
                        }
                    }
                    .overlay {
                        if session.yttranden.isEmpty {
                            Text("Lyssnar …").foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Insiktspanel(insikter: session.liveinsikter)
                    .frame(width: 340)
            }

            Divider()
            HStack {
                Text("Du kan använda resten av appen medan det spelas in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await session.stoppa() }
                } label: {
                    Label("Stoppa", systemImage: "stop.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.läge == .avslutar)
            }
            .padding(16)
        }
    }

    private func mätare(_ namn: String, _ nivå: Float, _ färg: Color) -> some View {
        HStack(spacing: 6) {
            Text(namn).font(.caption).foregroundStyle(.secondary)
            Capsule().fill(.quaternary).frame(width: 50, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(färg).frame(width: 50 * CGFloat(min(1, nivå)), height: 4)
                }
        }
    }

    private func rad(_ y: Yttrande) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(y.röst.etikett)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(y.röst == .jag ? Color.blue : Color.purple)
                Text(y.tidsstämpel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(y.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Efter

    private func klar(_ mapp: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.green)
            Text("Inspelningen är sparad").font(.title3.weight(.semibold))
            Text(mapp.lastPathComponent).font(.callout).foregroundStyle(.secondary)

            if session.efterbearbetar {
                VStack(spacing: 8) {
                    Text(session.analyserarRöster
                         ? "Delar upp rösterna"
                         : "KB-Whisper går igenom ljudet för arkivkvalitet")
                        .font(.callout).foregroundStyle(.secondary)
                    if session.analyserarRöster || session.efterbearbetningsandel <= 0 {
                        ProgressView().frame(width: 240)
                    } else {
                        ProgressView(value: session.efterbearbetningsandel).frame(width: 240)
                    }
                    if !session.senasteArkivrad.isEmpty {
                        Text("«\(session.senasteArkivrad)»")
                            .font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    Text("Du kan stänga fönstret — arbetet fortsätter.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 340)
            }
            if let fel = session.efterbearbetningsfel {
                Label(fel, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                Text("Livetranskriptet är sparat. Högerklicka på mötet i listan för att köra om.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack {
                Button("Visa i Finder") { NSWorkspace.shared.open(mapp) }
                Button("Klar") {
                    session.återställ()
                    Inspelningsfönster.stäng()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func starta() {
        guard let mikrofon = valdMikrofon else { return }
        sparadMikrofon = mikrofon.id
        let placering: Placering = valtProjekt.map { .projekt($0) } ?? .kund(kund)
        let namn = titel.trimmingCharacters(in: .whitespaces)
        Task {
            await session.starta(
                placering: placering,
                titel: namn.isEmpty ? (möte?.titel ?? "Samtal") : namn,
                mikrofon: mikrofon,
                kallade: möte?.deltagare.filter { !$0.ärJag }.map(\.namn) ?? [],
                språk: språk)
        }
    }
}
