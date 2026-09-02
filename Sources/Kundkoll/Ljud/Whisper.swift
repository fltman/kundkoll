import Foundation

/// Kör KB-Whisper via whisper.cpp.
///
/// Under samtal hålls en `whisper-server` igång med den lilla modellen så att
/// modellen ligger kvar i minnet mellan fönstren — uppmätt 0,47 s per 15 s
/// fönster, mot flera sekunder om processen startas om varje gång.
/// Efter samtalet körs `whisper-cli` en gång med den större modellen.
actor Whisper {

    struct Sökvägar: Codable, Hashable {
        var rot: URL
        var livemodell: String
        var arkivmodell: String
        /// Silero, som avgör om det ens finns tal i ljudet.
        var vadmodell: String

        /// Roten kan pekas ut under ⌘,; annars ~/Projekt/whisper.cpp.
        static var standard: Sökvägar {
            Sökvägar(
                rot: Inställningar.whisperRot.map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projekt/whisper.cpp"),
                livemodell: "kb_whisper_ggml_small.bin",
                arkivmodell: "kb_whisper_ggml_medium.bin",
                vadmodell: "ggml-silero-v5.1.2.bin"
            )
        }

        var server: URL { rot.appending(path: "build/bin/whisper-server") }
        var cli: URL { rot.appending(path: "build/bin/whisper-cli") }
        func modell(_ namn: String) -> URL { rot.appending(path: "models").appending(path: namn) }

        /// Vad som saknas för att transkriberingen ska fungera.
        var brister: [String] {
            var f: [String] = []
            let fm = FileManager.default
            if !fm.isExecutableFile(atPath: server.path) { f.append("whisper-server saknas i \(rot.path)/build/bin") }
            if !fm.isExecutableFile(atPath: cli.path) { f.append("whisper-cli saknas i \(rot.path)/build/bin") }
            if !fm.fileExists(atPath: modell(livemodell).path) { f.append("modellen \(livemodell) saknas") }
            if !fm.fileExists(atPath: modell(arkivmodell).path) { f.append("modellen \(arkivmodell) saknas") }
            if !fm.fileExists(atPath: modell(vadmodell).path) { f.append("VAD-modellen \(vadmodell) saknas") }
            return f
        }
    }

    /// En delad instans, så att servern kan stanna kvar mellan inspelningar.
    /// Att ladda modellen tar omkring tio sekunder, och den väntan låg
    /// tidigare mellan «Spela in» och första ordet.
    static let delad = Whisper()

    private let sökvägar: Sökvägar
    private var process: Process?
    private var port: Int = 0
    private let session: URLSession

    init(sökvägar: Sökvägar = .standard) {
        self.sökvägar = sökvägar
        let k = URLSessionConfiguration.ephemeral
        k.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: k)
    }

    // MARK: - Live

    func startaServer() async throws {
        // Servern kan ha dött sedan sist.
        if let p = process, !p.isRunning { process = nil }
        guard process == nil else { return }
        if let brist = sökvägar.brister.first { throw Fel.saknas(brist) }

        port = try Self.ledigPort()
        // Livemodellen kan väljas i inställningarna; en vald fil som inte
        // finns faller tillbaka på standarden.
        var livemodell = Transkriberingsval.läs().livemodell
        if !FileManager.default.fileExists(atPath: sökvägar.modell(livemodell).path) {
            livemodell = sökvägar.livemodell
        }
        let p = Process()
        p.executableURL = sökvägar.server
        p.currentDirectoryURL = sökvägar.rot
        p.arguments = [
            "-m", sökvägar.modell(livemodell).path,
            "-l", "sv",
            "--host", "127.0.0.1",
            "--port", String(port),
            "-nt",
            "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
        ] + Self.vadflaggor(sökvägar)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p

        // Vänta tills modellen är laddad och porten svarar.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if await svarar() { return }
            try? await Task.sleep(for: .milliseconds(250))
            if !p.isRunning { throw Fel.serverDog }
        }
        throw Fel.startTimeout
    }

    /// Låter servern stå kvar. Den tar minne men sparar uppstarten nästa gång.
    func stoppaServer() {
        // Behålls med flit: nästa inspelning slipper vänta på modellen.
        // `avsluta()` stänger den på riktigt.
    }

    /// Stänger servern. Anropas när appen avslutas.
    func avsluta() {
        process?.terminate()
        process = nil
    }

    /// Startar servern i förväg, så att den är varm när den behövs.
    func värmUpp() async {
        guard process == nil, sökvägar.brister.isEmpty else { return }
        try? await startaServer()
    }

    private func svarar() async -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        r.timeoutInterval = 1
        return (try? await session.data(for: r)) != nil
    }

    /// Transkriberar ett talfönster. Tom sträng om whisper inte hörde något.
    func transkribera(prov: [Float], språk: String = "sv") async throws -> String {
        guard process != nil else { throw Fel.serverEjIgång }
        let gräns = "kundkoll-\(UUID().uuidString)"
        var kropp = Data()
        func del(_ namn: String, _ värde: String) {
            kropp.append("--\(gräns)\r\nContent-Disposition: form-data; name=\"\(namn)\"\r\n\r\n\(värde)\r\n".data(using: .utf8)!)
        }
        kropp.append("--\(gräns)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"f.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        kropp.append(Wav.data(av: prov))
        kropp.append("\r\n".data(using: .utf8)!)
        del("temperature", "0")
        del("response_format", "json")
        del("language", språk)
        kropp.append("--\(gräns)--\r\n".data(using: .utf8)!)

        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(gräns)", forHTTPHeaderField: "Content-Type")
        r.httpBody = kropp

        let (data, _) = try await session.data(for: r)
        struct Svar: Decodable { let text: String }
        let text = (try? JSONDecoder().decode(Svar.self, from: data).text) ?? ""
        return städa(text)
    }

    // MARK: - Arkiv

    /// Hur långt den stora modellen kommit.
    struct Framsteg: Sendable {
        /// 0–1, räknat på var i ljudet whisper är.
        var andel: Double
        /// Det senaste den skrev ut, så att man ser att det faktiskt händer.
        var senasteRad: String
    }

    /// Kör den stora modellen på en färdig ljudfil och ger tidsstämplade rader.
    ///
    /// Framstegen läses ur whispers egen utskrift. Flaggan `-pp` finns men ger
    /// bara 40, 80 och 121 procent; tidsstämplarna på varje segment säger
    /// exakt var i ljudet den är, och texten är dessutom värd att visa.
    func arkivtranskribera(fil: URL, röst: Röst, förskjutning: Double = 0,
                           modell: String? = nil,
                           språk: String? = "sv",
                           totalLängd: Double? = nil,
                           vidFramsteg: (@Sendable (Framsteg) -> Void)? = nil) async throws -> [Yttrande] {
        if let brist = sökvägar.brister.first { throw Fel.saknas(brist) }
        let ut = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-\(UUID().uuidString)")

        // En vald modell som inte finns faller tillbaka på standarden i
        // stället för att fälla hela efterbearbetningen.
        var vald = modell ?? sökvägar.arkivmodell
        if !FileManager.default.fileExists(atPath: sökvägar.modell(vald).path) {
            vald = sökvägar.arkivmodell
        }

        let p = Process()
        p.executableURL = sökvägar.cli
        p.currentDirectoryURL = sökvägar.rot
        p.arguments = [
            "-m", sökvägar.modell(vald).path,
            "-l", språk ?? "auto",
            "-f", fil.path,
            "-oj",                       // JSON bredvid, med tider
            "-of", ut.path,
            "-np",
        ] + Self.vadflaggor(sökvägar)

        let rör = Pipe()
        p.standardOutput = vidFramsteg == nil ? FileHandle.nullDevice : rör
        p.standardError = FileHandle.nullDevice
        let längd = totalLängd ?? Self.längd(av: fil)

        if let vidFramsteg {
            nonisolated(unsafe) var rest = ""
            vidFramsteg(Framsteg(andel: 0, senasteRad: ""))
            rör.fileHandleForReading.readabilityHandler = { handtag in
                let bit = handtag.availableData
                guard !bit.isEmpty, let text = String(data: bit, encoding: .utf8) else { return }
                rest += text
                // Whisper skriver utan radbrytning mellan segment ibland, så
                // raderna plockas ut på hakparentesen i stället.
                while let träff = Self.nästaSegment(&rest) {
                    let andel = längd > 0 ? min(1, träff.slut / längd) : 0
                    vidFramsteg(Framsteg(andel: andel, senasteRad: träff.text))
                }
            }
        }

        // Fyra gånger realtid är gott om marginal — arkivmodellen går i
        // fjorton — men en modell som fastnat ska inte få stå för evigt.
        do {
            try await Underprocess.väntaIn(p, namn: "whisper-cli",
                                           tidsgräns: max(15 * 60, längd * 4))
        } catch {
            rör.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        rör.fileHandleForReading.readabilityHandler = nil
        // Sista segmentet väntar annars för evigt på en hakparentes som aldrig
        // kommer, och stapeln stannar strax före slutet.
        vidFramsteg?(Framsteg(andel: 1, senasteRad: ""))

        let jsonfil = URL(fileURLWithPath: ut.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonfil) }
        guard let data = try? Data(contentsOf: jsonfil) else { throw Fel.ingenUtdata }
        return Self.tolka(data, röst: röst, förskjutning: förskjutning)
    }

    /// Plockar ut nästa `[00:01:23.000 --> 00:01:30.000] text` ur strömmen.
    /// Returnerar sluttiden i sekunder och texten, och tar bort det lästa.
    static func nästaSegment(_ buffert: inout String) -> (slut: Double, text: String)? {
        guard let start = buffert.range(of: "[") ,
              let pil = buffert.range(of: " --> ", range: start.upperBound..<buffert.endIndex),
              let slutKlammer = buffert.range(of: "]", range: pil.upperBound..<buffert.endIndex)
        else { return nil }

        let slutTid = String(buffert[pil.upperBound..<slutKlammer.lowerBound])
        guard let sekunder = tid(ur: slutTid) else {
            buffert = String(buffert[slutKlammer.upperBound...])
            return nil
        }
        // Texten går fram till nästa segments hakparentes, om den redan kommit.
        let efter = buffert[slutKlammer.upperBound...]
        guard let nästa = efter.range(of: "[") else { return nil }
        let text = String(efter[..<nästa.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        buffert = String(efter[nästa.lowerBound...])
        return (sekunder, text)
    }

    /// "00:01:30.080" → 90.08
    static func tid(ur text: String) -> Double? {
        let delar = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard delar.count == 3,
              let t = Double(delar[0]), let m = Double(delar[1]), let s = Double(delar[2])
        else { return nil }
        return t * 3600 + m * 60 + s
    }

    private static func längd(av fil: URL) -> Double {
        // 16 kHz mono 16-bitars: 32 000 byte per sekund, minus WAV-huvudet.
        guard let storlek = try? FileManager.default
            .attributesOfItem(atPath: fil.path)[.size] as? Int else { return 0 }
        return Double(max(0, storlek - 44)) / 32_000
    }

    /// whisper.cpp:s JSON: transcription[].offsets är millisekunder.
    static func tolka(_ data: Data, röst: Röst, förskjutning: Double) -> [Yttrande] {
        struct Fil: Decodable {
            struct Rad: Decodable {
                struct Tider: Decodable { let from: Int; let to: Int }
                let text: String
                let offsets: Tider
            }
            let transcription: [Rad]
        }
        guard let f = try? JSONDecoder().decode(Fil.self, from: data) else { return [] }
        return f.transcription.compactMap { rad in
            let t = rad.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !ärTomtLjud(t) else { return nil }
            return Yttrande(röst: röst,
                            text: t,
                            start: Double(rad.offsets.from) / 1000 + förskjutning,
                            slut: Double(rad.offsets.to) / 1000 + förskjutning)
        }
    }

    /// Utan taldetektering hittar whisper på text ur tystnad. Uppmätt: fem
    /// sekunder tystnad blir "Tack." Med Silero blir svaret tomt.
    /// Det här är den viktigaste raden i hela filen.
    static func vadflaggor(_ sökvägar: Sökvägar) -> [String] {
        ["--vad",
         "-vm", sökvägar.modell(sökvägar.vadmodell).path,
         "-vt", "0.5",
         "-vsd", "150",     // så att korta pauser inte klipper mitt i en mening
         "-vp", "60"]       // lite marginal runt talet, annars kapas begynnelseljud
    }

    // MARK: - Småsaker

    private func städa(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.ärTomtLjud(t) ? "" : t
    }

    /// whisper hittar gärna på "[Musik]" eller "Tack." ur ren tystnad.
    ///
    /// Taldetekteringen tar det mesta, men inte allt: svagt tal och brus kan
    /// fortfarande ge påhitt, och då är de nästan alltid antingen en av några
    /// få stående fraser eller ett ord som fastnat i en loop.
    static func ärTomtLjud(_ t: String) -> Bool {
        if t.isEmpty { return true }
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }
        if t.hasPrefix("(") && t.hasSuffix(")") { return true }
        let bara = t.trimmingCharacters(in: CharacterSet(charactersIn: " .!?…-"))
        if bara.isEmpty { return true }
        if ärLoop(t) { return true }
        return stående.contains(bara.lowercased())
    }

    /// Fraser whisper lägger i munnen på tystnad. Bara exakta träffar räknas —
    /// "Tack." är påhitt, men "Tack för att du tog dig tid" är riktigt tal.
    private static let stående: Set<String> = [
        "tack", "tack.", "tack!", "tack så mycket", "tack för att ni tittade",
        "tack för att du tittade", "tack för hjälpen", "textning av", "hej då",
        "undertexter av", "undertextning av", "svensktextning", "amara.org",
        "textning.nu", "you", "thank you", "thanks for watching",
    ]

    /// "Ett stort stort stort stort …" — samma ord om och om igen är alltid
    /// en modell som fastnat, aldrig någon som talar.
    static func ärLoop(_ t: String) -> Bool {
        let ord = t.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard ord.count >= 6 else { return false }
        var längstaKedja = 1, kedja = 1
        for i in 1..<ord.count {
            kedja = ord[i] == ord[i - 1] ? kedja + 1 : 1
            längstaKedja = max(längstaKedja, kedja)
        }
        if längstaKedja >= 4 { return true }
        // Ett fåtal unika ord utspridda över en lång text är samma sak.
        return ord.count >= 12 && Set(ord).count * 4 <= ord.count
    }

    /// Frågar operativsystemet efter en port ingen annan använder. Nödvändigt:
    /// den här maskinen har gott om lokala tjänster som redan tagit portar.
    static func ledigPort() throws -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw Fel.ingenPort }
        defer { close(s) }
        var adr = sockaddr_in()
        adr.sin_family = sa_family_t(AF_INET)
        adr.sin_port = 0                       // 0 = valfri ledig
        adr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var längd = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bunden = withUnsafePointer(to: &adr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, längd) }
        }
        guard bunden == 0 else { throw Fel.ingenPort }
        let hämtad = withUnsafeMutablePointer(to: &adr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &längd) }
        }
        guard hämtad == 0 else { throw Fel.ingenPort }
        return Int(UInt16(bigEndian: adr.sin_port))
    }

    enum Fel: LocalizedError {
        case saknas(String), serverDog, startTimeout, serverEjIgång, ingenPort, ingenUtdata
        var errorDescription: String? {
            switch self {
            case .saknas(let v): "Transkriberingen kan inte starta: \(v)."
            case .serverDog: "whisper-server avslutades direkt."
            case .startTimeout: "whisper-server svarade inte inom en minut."
            case .serverEjIgång: "whisper-server är inte igång."
            case .ingenPort: "Hittade ingen ledig port åt whisper-server."
            case .ingenUtdata: "whisper-cli lämnade ingen utdata."
            }
        }
    }
}
