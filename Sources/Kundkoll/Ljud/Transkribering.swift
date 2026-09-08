import Foundation

/// Vilken motor som transkriberar färdiga inspelningar, och med vilken modell.
///
/// Livetranskriberingen är alltid lokal — fönstren är sekunder långa och går
/// genom whisper-server som håller modellen varm. Det här valet gäller
/// arkivpasset: genomlyssningen efter mötet och importerade filer.
enum Transkriberingsmotor: String, Codable, CaseIterable, Identifiable {
    case whisperCpp, mlx, openai, elevenlabs

    var id: String { rawValue }

    var namn: String {
        switch self {
        case .whisperCpp: "Lokal (whisper.cpp)"
        case .mlx: "Lokal (MLX)"
        case .openai: "OpenAI"
        case .elevenlabs: "ElevenLabs"
        }
    }

    var beskrivning: String {
        switch self {
        case .whisperCpp:
            "KB-Whisper på den här datorn. Slog large-v3-turbo på svenska i "
            + "mätningarna, och ljudet lämnar aldrig maskinen."
        case .mlx:
            "Whisper via Apples MLX, på den här datorn. Snabb på Apple Silicon; "
            + "large-v3-turbo låg dock under KB-Whisper på svenska i mätningarna."
        case .openai:
            "Whisper hos OpenAI. Ljudet skickas dit, komprimerat till m4a."
        case .elevenlabs:
            "Scribe hos ElevenLabs. Ljudet skickas dit. Bäst av molnen på "
            + "svenska i mätningen."
        }
    }

    var standardmodell: String {
        switch self {
        case .whisperCpp: "kb_whisper_ggml_medium.bin"
        case .mlx: "mlx-community/whisper-large-v3-turbo"
        case .openai: "whisper-1"
        case .elevenlabs: "scribe_v2"
        }
    }

    var lokal: Bool { self == .whisperCpp || self == .mlx }
    var behöverNyckel: Bool { !lokal }

    var nyckelkonto: String? {
        switch self {
        case .openai: Leverantör.openai.nyckelkonto
        case .elevenlabs: "kundkoll-elevenlabs"
        default: nil
        }
    }

    var miljövariabel: String? {
        switch self {
        case .openai: "OPENAI_API_KEY"
        case .elevenlabs: "ELEVENLABS_API_KEY"
        default: nil
        }
    }

    var nyckel: String? {
        guard let konto = nyckelkonto else { return nil }
        return Nyckelring.hämta(konto, miljö: miljövariabel)
    }
}

/// Valet, sparat som inställning — det gäller hela appen, inte en kund.
struct Transkriberingsval: Codable {
    var motor: Transkriberingsmotor = .whisperCpp
    /// Arkivmodellen. Tom betyder motorns standard.
    var modell: String = ""
    /// Modellen för livetranskriberingen, alltid en ggml-fil i whisper.cpp.
    var livemodell: String = Whisper.Sökvägar.standard.livemodell

    var arkivmodell: String { modell.isEmpty ? motor.standardmodell : modell }

    init(motor: Transkriberingsmotor = .whisperCpp, modell: String = "",
         livemodell: String = Whisper.Sökvägar.standard.livemodell) {
        self.motor = motor
        self.modell = modell
        self.livemodell = livemodell
    }

    /// Skriven för hand: se `Inspelning`.
    init(from avkodare: Decoder) throws {
        let c = try avkodare.container(keyedBy: CodingKeys.self)
        motor = try c.decodeIfPresent(Transkriberingsmotor.self, forKey: .motor) ?? .whisperCpp
        modell = try c.decodeIfPresent(String.self, forKey: .modell) ?? ""
        livemodell = try c.decodeIfPresent(String.self, forKey: .livemodell)
            ?? Whisper.Sökvägar.standard.livemodell
    }

    private static let nyckel = "kundkoll.transkribering"

    static func läs() -> Transkriberingsval {
        guard let data = UserDefaults.standard.data(forKey: nyckel),
              let v = try? JSONDecoder().decode(Transkriberingsval.self, from: data)
        else { return Transkriberingsval() }
        return v
    }

    func spara() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.nyckel)
    }

    /// Modellerna som finns att välja på för whisper.cpp — ggml-filerna i
    /// modellkatalogen, utan testfixturer och taldetektorer.
    static func lokalaModeller(i rot: URL = Whisper.Sökvägar.standard.rot) -> [String] {
        let mapp = rot.appending(path: "models")
        guard let filer = try? FileManager.default.contentsOfDirectory(atPath: mapp.path)
        else { return [] }
        return filer
            .filter { $0.hasSuffix(".bin") }
            .filter { !$0.hasPrefix("for-tests") }
            .filter { !$0.contains("silero") && !$0.contains("vad") }
            .sorted()
    }
}

/// Språken ett möte kan sättas till. nil är «avgör själv».
///
/// Norska och danska finns med för att kunderna finns där. Utan dem blev
/// «avgör själv» det enda valet för ett norskt möte — och avgörandet föll
/// på engelska, som översätter i stället för att skriva av.
enum Mötesspråk {
    static let val: [(kod: String, namn: String)] = [
        ("sv", "Svenska"),
        ("no", "Norska"),
        ("da", "Danska"),
        ("en", "Engelska"),
    ]

    static func namn(_ kod: String?) -> String {
        guard let kod else { return "Avgör själv" }
        return val.first { $0.kod == kod }?.namn ?? kod
    }
}

/// Arkivtranskriberingen: en ingång, fyra motorer.
enum Arkivtranskribering {

    /// `språk` är "sv", "en" eller nil för att låta motorn avgöra själv.
    static func kör(fil: URL, röst: Röst, språk: String? = "sv",
                    totalLängd: Double? = nil,
                    vidFramsteg: (@Sendable (Whisper.Framsteg) -> Void)? = nil)
    async throws -> [Yttrande] {
        let val = Transkriberingsval.läs()
        guard let väg = vägval(motor: val.motor, modell: val.arkivmodell, språk: språk) else {
            throw Enkeltfel("KB-Whisper är svensktrimmad och översätter andra språk "
                            + "till svenska. För det här mötet behövs MLX "
                            + "(pip install mlx-whisper i transcriber-venven) "
                            + "eller en molnmotor — välj under ⌘,.")
        }
        // «Avgör själv» avgörs här, på en bit där någon talar. Vägvalet görs
        // ändå på användarens val, inte på gissningen: ett möte på svenska
        // och norska ska inte hamna hos den svensktrimmade modellen bara för
        // att gissningen råkade landa på svenska.
        var körsSpråk = språk
        if körsSpråk == nil, väg.motor.lokal { körsSpråk = await gissaSpråk(fil: fil) }
        let rader: [Yttrande]
        switch väg.motor {
        case .whisperCpp:
            rader = try await Whisper.delad.arkivtranskribera(
                fil: fil, röst: röst, modell: väg.modell, språk: körsSpråk,
                totalLängd: totalLängd, vidFramsteg: vidFramsteg)
        case .mlx:
            rader = try await MlxWhisper.transkribera(
                fil: fil, röst: röst, modell: väg.modell, språk: körsSpråk,
                totalLängd: totalLängd, vidFramsteg: vidFramsteg)
        case .openai:
            rader = try await Molntranskribering.openai(
                fil: fil, röst: röst, modell: väg.modell, språk: språk,
                vidFramsteg: vidFramsteg)
        case .elevenlabs:
            rader = try await Molntranskribering.scribe(
                fil: fil, röst: röst, modell: väg.modell, språk: språk,
                vidFramsteg: vidFramsteg)
        }
        // Text är text, oavsett var den kom ifrån: rader utan tal bakom sig
        // kastas för alla motorer. MLX och molnen har ingen egen VAD.
        return Tystnadsfilter.rensa(rader, ljud: fil)
    }

    /// Vart ett språk får ta vägen.
    ///
    /// KB-modellerna översätter allt till svenska — uppmätt: engelskt ljud
    /// med -l en blev svenska med kb_medium. För andra språk än svenska går
    /// whisper.cpp-vägen därför via MLX, som upptäcker språket själv och
    /// bevisligen behåller det. Finns inte MLX blir svaret nil och anroparen
    /// får säga ifrån i klartext.
    static func vägval(motor: Transkriberingsmotor, modell: String, språk: String?)
    -> (motor: Transkriberingsmotor, modell: String)? {
        guard motor == .whisperCpp, modell.contains("kb_whisper"), språk != "sv" else {
            return (motor, modell)
        }
        guard FileManager.default.isExecutableFile(atPath: MlxWhisper.körbar.path) else {
            return nil
        }
        return (.mlx, Transkriberingsmotor.mlx.standardmodell)
    }

    /// Gissar mötets språk ur ljudet, för «avgör själv».
    ///
    /// Motorerna avgör språket ur filens första trettio sekunder. Ett möte
    /// spelas nästan alltid in innan någon börjat tala, och tystnad kan bli
    /// vilket språk som helst: uppmätt gav en timmes norskt möte «English» på
    /// sin första halvminut — tio minuter tyst väntrum — och hela timmen
    /// översattes till engelska i stället för att skrivas av. Samma modell på
    /// en bit med tal i svarade rätt. Därför gissas språket där någon talar.
    ///
    /// Ger nil när gissningen inte går att göra; då avgör motorn som förr.
    static func gissaSpråk(fil: URL) async -> String? {
        guard let start = förstaTalet(i: fil) else { return nil }
        let prov = Wav.prov(ur: fil, från: start, sekunder: 90)
        guard prov.count >= Int(Ljudbuffring.målfrekvens * 5) else { return nil }
        let bit = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-språk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: bit) }
        guard (try? Wav.data(av: prov).write(to: bit)) != nil else { return nil }
        return await MlxWhisper.språk(i: bit)
    }

    /// Var i ljudet någon börjar tala, i sekunder. nil om ingenstans.
    ///
    /// Ett enstaka block kan vara en dörr som slår igen eller ett tangentslag.
    /// Först när en tiosekundersruta bär två sekunder tal är det någon som
    /// talar, och då pekas rutans början ut.
    static func förstaTalet(i fil: URL) -> Double? {
        guard let rms = Tystnadsfilter.blockRMS(i: fil) else { return nil }
        return förstaTalet(blockRMS: rms)
    }

    /// Utbruten för att kunna provas utan en fil.
    static func förstaTalet(blockRMS rms: [Float], ruta: Double = 10, krav: Double = 2) -> Double? {
        let tal = Tystnadsfilter.talblock(rms)
        let blockSekunder = Double(Ljudbuffring.blocklängd) / Ljudbuffring.målfrekvens
        let rutblock = max(1, Int(ruta / blockSekunder))
        let kravblock = max(1, Int(krav / blockSekunder))
        var summa = 0
        for i in 0..<tal.count {
            if tal[i] { summa += 1 }
            if i >= rutblock, tal[i - rutblock] { summa -= 1 }
            if summa >= kravblock {
                return max(0, Double(i - rutblock) * blockSekunder)
            }
        }
        return nil
    }

    /// Vad som saknas för att det valda ska kunna köra. Tomt är gott.
    static func brister(_ val: Transkriberingsval = .läs()) -> [String] {
        switch val.motor {
        case .whisperCpp:
            return Whisper.Sökvägar.standard.brister
        case .mlx:
            return FileManager.default.isExecutableFile(atPath: MlxWhisper.körbar.path)
                ? [] : ["mlx_whisper saknas — installera med: "
                        + "\(MlxWhisper.venv.path)/bin/pip install mlx-whisper"]
        case .openai, .elevenlabs:
            return val.motor.nyckel == nil
                ? ["API-nyckel för \(val.motor.namn) saknas"] : []
        }
    }
}

// MARK: - MLX

/// Whisper via Apples MLX. Samma pythonmiljö som röstanalysen lånar.
enum MlxWhisper {
    /// Miljön kan pekas ut under ⌘,; annars ~/Projekt/transcriber/venv.
    static var venv: URL {
        Inställningar.pythonMiljö.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Projekt/transcriber/venv")
    }
    static var körbar: URL { venv.appending(path: "bin/mlx_whisper") }

    static func transkribera(fil: URL, röst: Röst, modell: String,
                             språk: String? = "sv",
                             totalLängd: Double?,
                             vidFramsteg: (@Sendable (Whisper.Framsteg) -> Void)?)
    async throws -> [Yttrande] {
        guard FileManager.default.isExecutableFile(atPath: körbar.path) else {
            throw Enkeltfel("mlx_whisper saknas i \(venv.path). "
                            + "Installera med: pip install mlx-whisper")
        }
        let ut = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-mlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ut, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ut) }

        let p = Process()
        p.executableURL = körbar
        var argument = [fil.path,
                        "--model", modell,
                        "--output-dir", ut.path,
                        "--output-format", "json",
                        // mlx saknar Silero-VAD, och utan de här två fastnade
                        // den i en loop på ett riktigt möte: 60 s tystnad i
                        // början gav 773 rader «Good afternoon.» i följd.
                        "--condition-on-previous-text", "False",
                        "--hallucination-silence-threshold", "2"]
        // Utan språk får modellen avgöra själv — uppmätt hittar den rätt.
        if let språk { argument += ["--language", språk] }
        p.arguments = argument

        // mlx_whisper skriver segmenten till stdout medan den arbetar, på
        // samma form som whisper-cli — framstegen läses därifrån.
        let rör = Pipe()
        p.standardOutput = rör
        p.standardError = FileHandle.nullDevice
        if let vidFramsteg {
            let längd = totalLängd ?? 0
            nonisolated(unsafe) var rest = ""
            vidFramsteg(Whisper.Framsteg(andel: 0, senasteRad: ""))
            rör.fileHandleForReading.readabilityHandler = { handtag in
                guard let text = String(data: handtag.availableData, encoding: .utf8),
                      !text.isEmpty else { return }
                rest += text
                while let träff = Whisper.nästaSegment(&rest) {
                    let andel = längd > 0 ? min(1, träff.slut / längd) : 0
                    vidFramsteg(Whisper.Framsteg(andel: andel, senasteRad: träff.text))
                }
            }
        }

        do {
            try await Underprocess.väntaIn(p, namn: "mlx_whisper",
                                           tidsgräns: max(15 * 60, (totalLängd ?? 0) * 4))
        } catch {
            rör.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        rör.fileHandleForReading.readabilityHandler = nil
        vidFramsteg?(Whisper.Framsteg(andel: 1, senasteRad: ""))

        let namn = fil.deletingPathExtension().lastPathComponent
        let json = ut.appending(path: "\(namn).json")
        guard let data = try? Data(contentsOf: json) else {
            throw Enkeltfel("mlx_whisper lämnade ingen utdata.")
        }
        return tolka(data, röst: röst)
    }

    /// Vilket språk mlx_whisper hör i en kort bit ljud — koden ur JSON:ens
    /// `language`, eller nil om passet inte gick igenom. Bara en gissning:
    /// den som faller tyst låter motorn avgöra som förr.
    static func språk(i fil: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: körbar.path) else { return nil }
        let ut = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-mlx-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: ut, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: ut) }

        let p = Process()
        p.executableURL = körbar
        p.arguments = [fil.path,
                       "--model", Transkriberingsmotor.mlx.standardmodell,
                       "--output-dir", ut.path,
                       "--output-format", "json",
                       "--condition-on-previous-text", "False"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? await Underprocess.väntaIn(p, namn: "mlx_whisper", tidsgräns: 300)) != nil
        else { return nil }

        struct Fil: Decodable { let language: String? }
        let json = ut.appending(path: fil.deletingPathExtension().lastPathComponent + ".json")
        guard let data = try? Data(contentsOf: json),
              let hörd = try? JSONDecoder().decode(Fil.self, from: data).language
        else { return nil }
        return kod(hörd)
    }

    /// mlx_whisper svarar med koden ("sv"), men äldre versioner med namnet
    /// ("Swedish"). Båda ska bli en kod motorerna känner igen.
    static func kod(_ svar: String) -> String? {
        let s = svar.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let namn = ["swedish": "sv", "norwegian": "no", "nynorsk": "no",
                    "danish": "da", "english": "en"]
        if let k = namn[s] { return k }
        // Whisper skiljer på bokmål och nynorsk; motorerna vill ha "no".
        if s == "nb" || s == "nn" { return "no" }
        return s.count <= 3 ? s : nil
    }

    /// mlx_whispers JSON: segments[].start/end i sekunder.
    static func tolka(_ data: Data, röst: Röst) -> [Yttrande] {
        struct Fil: Decodable {
            struct Segment: Decodable { let start: Double; let end: Double; let text: String }
            let segments: [Segment]
        }
        guard let f = try? JSONDecoder().decode(Fil.self, from: data) else { return [] }
        let rader = f.segments.compactMap { s -> Yttrande? in
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !Whisper.ärTomtLjud(t) else { return nil }
            return Yttrande(röst: röst, text: t, start: s.start, slut: s.end)
        }
        return utanUpprepningar(rader)
    }

    /// Samma text många gånger i rad är alltid en modell som fastnat, aldrig
    /// någon som talar — uppmätt gav 60 s tystnad i början av ett möte 773
    /// rader «Good afternoon.» i följd. Första förekomsten behålls, den kan
    /// vara äkta.
    static func utanUpprepningar(_ rader: [Yttrande], tak: Int = 4) -> [Yttrande] {
        var ut: [Yttrande] = []
        var i = 0
        while i < rader.count {
            var j = i
            while j < rader.count, rader[j].text == rader[i].text { j += 1 }
            ut.append(rader[i])
            // Korta upprepningar är äkta tal — «Ja. Ja.» händer. Långa är det
            // aldrig.
            if j - i < tak { ut.append(contentsOf: rader[(i + 1)..<j]) }
            i = j
        }
        return ut
    }
}

// MARK: - Molnen

/// OpenAI och ElevenLabs. Ljudet lämnar datorn — det är hela skillnaden,
/// och det står i inställningarna i klartext.
enum Molntranskribering {

    // MARK: OpenAI

    static func openai(fil: URL, röst: Röst, modell: String,
                       språk: String? = "sv",
                       vidFramsteg: (@Sendable (Whisper.Framsteg) -> Void)?)
    async throws -> [Yttrande] {
        guard let nyckel = Transkriberingsmotor.openai.nyckel else {
            throw Enkeltfel("Ingen API-nyckel för OpenAI. Lägg in den under ⌘,.")
        }
        vidFramsteg?(Whisper.Framsteg(andel: 0, senasteRad: "Komprimerar ljudet …"))
        // WAV är för stort att skicka: 39 minuter väger 75 MB och gränsen är
        // 25. AAC i m4a klarar samma ljud på ett par megabyte.
        let m4a = try await komprimera(fil)
        defer { try? FileManager.default.removeItem(at: m4a) }
        let storlek = (try? FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
        guard storlek < 24_000_000 else {
            throw Enkeltfel("Inspelningen är för lång för OpenAI (över 25 MB "
                            + "komprimerad). Välj den lokala motorn för den här.")
        }

        vidFramsteg?(Whisper.Framsteg(andel: 0.2, senasteRad: "Skickar till OpenAI …"))
        var delar: [(String, String)] = [("model", modell),
                                         ("response_format", "verbose_json")]
        if let språk { delar.append(("language", språk)) }
        let data = try await skickaMultipart(
            till: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            huvuden: ["Authorization": "Bearer \(nyckel)"],
            fält: delar, fil: m4a, filtyp: "audio/mp4")
        vidFramsteg?(Whisper.Framsteg(andel: 1, senasteRad: ""))
        delar.removeAll()
        return tolkaOpenAI(data, röst: röst)
    }

    /// verbose_json: segments[].start/end i sekunder.
    static func tolkaOpenAI(_ data: Data, röst: Röst) -> [Yttrande] {
        struct Svar: Decodable {
            struct Segment: Decodable { let start: Double; let end: Double; let text: String }
            let segments: [Segment]?
        }
        guard let s = try? JSONDecoder().decode(Svar.self, from: data) else { return [] }
        return (s.segments ?? []).compactMap { seg in
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !Whisper.ärTomtLjud(t) else { return nil }
            return Yttrande(röst: röst, text: t, start: seg.start, slut: seg.end)
        }
    }

    // MARK: ElevenLabs

    static func scribe(fil: URL, röst: Röst, modell: String,
                       språk: String? = nil,
                       vidFramsteg: (@Sendable (Whisper.Framsteg) -> Void)?)
    async throws -> [Yttrande] {
        guard let nyckel = Transkriberingsmotor.elevenlabs.nyckel else {
            throw Enkeltfel("Ingen API-nyckel för ElevenLabs. Lägg in den under ⌘,.")
        }
        vidFramsteg?(Whisper.Framsteg(andel: 0.1, senasteRad: "Skickar till ElevenLabs …"))
        let data = try await skickaMultipart(
            till: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
            huvuden: ["xi-api-key": nyckel],
            fält: [("model_id", modell)] + (språk.map { [("language_code", $0)] } ?? []),
            fil: fil, filtyp: "audio/wav")
        vidFramsteg?(Whisper.Framsteg(andel: 1, senasteRad: ""))
        return tolkaScribe(data, röst: röst)
    }

    /// Scribe ger ord med tider, inte segment. Orden sys ihop till yttranden
    /// vid pauserna — samma gräns som livebuffringen använder för att stänga
    /// ett fönster.
    static func tolkaScribe(_ data: Data, röst: Röst, paus: Double = 0.9,
                            maxLängd: Double = 15) -> [Yttrande] {
        struct Svar: Decodable {
            struct Ord: Decodable {
                let text: String; let start: Double?; let end: Double?; let type: String
            }
            let words: [Ord]?
            let detail: Detalj?
            struct Detalj: Decodable { let message: String? }
        }
        guard let s = try? JSONDecoder().decode(Svar.self, from: data) else { return [] }

        var ut: [Yttrande] = []
        var text = ""
        var start: Double?
        var slut: Double = 0
        func stäng() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, !t.isEmpty, !Whisper.ärTomtLjud(t) {
                ut.append(Yttrande(röst: röst, text: t, start: start, slut: slut))
            }
            text = ""; start = nil
        }
        for ord in s.words ?? [] where ord.type == "word" {
            guard let ordStart = ord.start, let ordSlut = ord.end else { continue }
            if start != nil, ordStart - slut >= paus || ordSlut - (start ?? 0) > maxLängd {
                stäng()
            }
            if start == nil { start = ordStart }
            text += (text.isEmpty ? "" : " ") + ord.text
            slut = ordSlut
        }
        stäng()
        return ut
    }

    // MARK: Gemensamt

    private static func komprimera(_ fil: URL) async throws -> URL {
        let ut = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-\(UUID().uuidString).m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", fil.path, ut.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try await Underprocess.väntaIn(p, tidsgräns: 5 * 60)
        guard p.terminationStatus == 0 else {
            throw Enkeltfel("Ljudet gick inte att komprimera inför uppladdningen.")
        }
        return ut
    }

    private static func skickaMultipart(till url: URL, huvuden: [String: String],
                                        fält: [(String, String)],
                                        fil: URL, filtyp: String) async throws -> Data {
        let gräns = "kundkoll-\(UUID().uuidString)"
        var kropp = Data()
        for (namn, värde) in fält {
            kropp.append("--\(gräns)\r\nContent-Disposition: form-data; name=\"\(namn)\"\r\n\r\n\(värde)\r\n".data(using: .utf8)!)
        }
        kropp.append("--\(gräns)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fil.lastPathComponent)\"\r\nContent-Type: \(filtyp)\r\n\r\n".data(using: .utf8)!)
        kropp.append(try Data(contentsOf: fil))
        kropp.append("\r\n--\(gräns)--\r\n".data(using: .utf8)!)

        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(gräns)", forHTTPHeaderField: "Content-Type")
        for (namn, värde) in huvuden { r.setValue(värde, forHTTPHeaderField: namn) }
        r.httpBody = kropp
        r.timeoutInterval = 600

        let (data, svar) = try await URLSession.shared.data(for: r)
        guard let http = svar as? HTTPURLResponse, http.statusCode == 200 else {
            let kod = (svar as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw Enkeltfel("Transkriberingstjänsten svarade \(kod): \(text)")
        }
        return data
    }
}
