import Foundation

/// Frågor och svar om en kund, med kundens eget material som underlag.
///
/// Modellen nås via OpenRouter, som Anders redan har nyckel till. Bara det som
/// sökningen plockat fram skickas — inte hela kundmappen — och bara när han
/// själv ställer en fråga. Under pågående samtal används den lokala modellen.
actor Chatt {

    /// En källa svaret byggde på.
    struct Hänvisning: Codable, Hashable, Identifiable {
        var id: String { "\(nummer)-\(titel)" }
        var nummer: Int
        var titel: String
        var typ: String
        /// Filen den kommer ur, så att den går att öppna.
        var källa: String
        var datum: Date?

        var beskrivning: String {
            datum.map { "\(titel) · \(DateFormatter.dag.string(from: $0))" } ?? titel
        }

        init(nummer: Int, titel: String, typ: String, källa: String, datum: Date? = nil) {
            self.nummer = nummer
            self.titel = titel
            self.typ = typ
            self.källa = källa
            self.datum = datum
        }

        /// Skriven för hand: se `Inspelning`.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            nummer = try c.decodeIfPresent(Int.self, forKey: .nummer) ?? 0
            titel = try c.decodeIfPresent(String.self, forKey: .titel) ?? ""
            typ = try c.decodeIfPresent(String.self, forKey: .typ) ?? ""
            källa = try c.decodeIfPresent(String.self, forKey: .källa) ?? ""
            datum = try c.decodeIfPresent(Date.self, forKey: .datum)
        }

        var ikon: String {
            switch typ {
            case "transkript": "waveform"
            case "anteckning": "note.text"
            case "mejl": "envelope"
            case "bilaga": "paperclip"
            case "chatt": "bubble.left.and.text.bubble.right"
            case "fil": "folder"
            case "sammanfattning": "list.bullet.rectangle"
            case "kontakt": "person"
            default: "doc.text"
            }
        }
    }

    struct Meddelande: Codable, Identifiable, Hashable {
        enum Roll: String, Codable { case människa, assistent }
        /// Varifrån svaret kommer. Kunskapsbanken svarar på sekunder ur det
        /// som sagts och skrivits; en kodagent tar längre tid men har läst
        /// filerna i en kopplad mapp.
        enum Ursprung: String, Codable { case kunskapsbank, mapp }

        var id = UUID()
        var roll: Roll
        var text: String
        var tid = Date()
        /// Vad svaret byggde på.
        var hänvisningar: [Hänvisning] = []
        var ursprung: Ursprung = .kunskapsbank
        /// Mappen svaret kommer ur, när det är en agent som svarat.
        var mapp: String?

        init(id: UUID = UUID(), roll: Roll, text: String, tid: Date = Date(),
             hänvisningar: [Hänvisning] = [], ursprung: Ursprung = .kunskapsbank,
             mapp: String? = nil) {
            self.id = id
            self.roll = roll
            self.text = text
            self.tid = tid
            self.hänvisningar = hänvisningar
            self.ursprung = ursprung
            self.mapp = mapp
        }

        /// Hela samtalshistoriken ligger i de här. Skriven för hand så att ett
        /// nytt fält inte tar den med sig — se `Inspelning`.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            roll = try c.decodeIfPresent(Roll.self, forKey: .roll) ?? .assistent
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            tid = try c.decodeIfPresent(Date.self, forKey: .tid) ?? Date()
            hänvisningar = try c.decodeIfPresent([Hänvisning].self, forKey: .hänvisningar) ?? []
            ursprung = try c.decodeIfPresent(Ursprung.self, forKey: .ursprung) ?? .kunskapsbank
            mapp = try c.decodeIfPresent(String.self, forKey: .mapp)
        }
    }

    struct Svar {
        var text: String
        var hänvisningar: [Hänvisning]
    }

    private let val: Modellval
    private let session: URLSession

    init(val: Modellval = .läs()) {
        self.val = val
        let k = URLSessionConfiguration.ephemeral
        // En lokal modell på en vanlig laptop kan tänka länge.
        k.timeoutIntervalForRequest = 300
        session = URLSession(configuration: k)
    }

    var färdig: Bool { val.färdig }
    var leverantör: Leverantör { val.leverantör }

    /// Ställer en fråga med utdrag ur kunskapsbanken som underlag.
    ///
    /// Med `vidDelta` strömmas svaret bit för bit medan det skrivs — de
    /// första orden syns på under sekunden i stället för att hela svaret
    /// landar efter flera. Hänvisningarna kommer ändå sist: de plockas ur
    /// den färdiga texten.
    func fråga(_ text: String,
               om kund: String,
               projekt: String?,
               träffar: [Kunskapsbank.Träff],
               historik: [Meddelande],
               vidDelta: (@Sendable (String) -> Void)? = nil) async throws -> Svar {
        guard let url = val.url else { throw Fel.trasigAdress }
        let nyckel = Nyckelring.förLeverantör(val.leverantör)
        if val.leverantör.behöverNyckel && nyckel == nil { throw Fel.ingenNyckel(val.leverantör) }

        let system = Self.systemtext(kund: kund, projekt: projekt, träffar: träffar)
        // Bara de senaste turerna: äldre frågor har sitt eget underlag som
        // inte längre finns med, och drar svaret fel.
        let tidigare = historik.suffix(8)

        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try kropp(system: system, tidigare: Array(tidigare), fråga: text,
                               ström: vidDelta != nil)

        switch val.leverantör {
        case .anthropic:
            r.setValue(nyckel, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .azure:
            r.setValue(nyckel, forHTTPHeaderField: "api-key")
        case .openrouter:
            r.setValue("Bearer \(nyckel ?? "")", forHTTPHeaderField: "Authorization")
            r.setValue(Appnamn.visat, forHTTPHeaderField: "X-Title")
        case .openai:
            r.setValue("Bearer \(nyckel ?? "")", forHTTPHeaderField: "Authorization")
        case .lokal:
            if let nyckel { r.setValue("Bearer \(nyckel)", forHTTPHeaderField: "Authorization") }
        }

        if let vidDelta {
            let hela = try await strömma(r, url: url, vidDelta: vidDelta)
            return Svar(text: hela, hänvisningar: Self.använda(i: hela, av: träffar))
        }

        let (data, svar): (Data, URLResponse)
        do {
            (data, svar) = try await session.data(for: r)
        } catch {
            // En lokal modell som inte är igång är det vanligaste felet här.
            if val.leverantör == .lokal { throw Fel.nårInteLokal(url.host ?? "") }
            throw error
        }
        guard let http = svar as? HTTPURLResponse else { throw Fel.ingetSvar }
        guard http.statusCode == 200 else {
            throw Fel.frånTjänsten(http.statusCode, Self.felmeddelande(data))
        }

        let innehåll = val.leverantör.talarAnthropic
            ? Self.läsAnthropic(data)
            : Self.läsOpenAI(data)
        guard let innehåll, !innehåll.isEmpty else { throw Fel.tomtSvar }

        return Svar(text: innehåll, hänvisningar: Self.använda(i: innehåll, av: träffar))
    }

    /// Läser svaret som SSE-rader och lämnar ut varje textbit direkt.
    private func strömma(_ r: URLRequest, url: URL,
                         vidDelta: @Sendable (String) -> Void) async throws -> String {
        let (rader, svar): (URLSession.AsyncBytes, URLResponse)
        do {
            (rader, svar) = try await session.bytes(for: r)
        } catch {
            if val.leverantör == .lokal { throw Fel.nårInteLokal(url.host ?? "") }
            throw error
        }
        guard let http = svar as? HTTPURLResponse else { throw Fel.ingetSvar }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in rader { data.append(byte) }
            throw Fel.frånTjänsten(http.statusCode, Self.felmeddelande(data))
        }

        var hela = ""
        for try await rad in rader.lines {
            guard rad.hasPrefix("data:") else { continue }
            let nytto = rad.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if nytto == "[DONE]" { break }
            let bit = val.leverantör.talarAnthropic
                ? Self.deltaAnthropic(Data(nytto.utf8))
                : Self.deltaOpenAI(Data(nytto.utf8))
            if let bit, !bit.isEmpty {
                hela += bit
                vidDelta(bit)
            }
        }
        guard !hela.isEmpty else { throw Fel.tomtSvar }
        return hela
    }

    // MARK: - Format

    static func systemtext(kund: String, projekt: String?,
                          träffar: [Kunskapsbank.Träff]) -> String {
        let sammanhang = träffar.enumerated().map { i, t in
            "[\(i + 1)] \(t.typ.uppercased()) — \(t.hänvisning)\n\(t.text)"
        }.joined(separator: "\n\n")

        var ut = """
        Du hjälper Anders att hålla ordning på sitt arbete med kunden \(kund).
        \(projekt.map { "Frågan gäller projektet \($0)." } ?? "")

        Svara på svenska, kort och konkret. Du får bara bygga svaret på
        underlaget nedan. Hittar du inte svaret där säger du det rent ut i
        stället för att gissa — att sakna uppgiften är ett användbart svar,
        ett påhittat är det inte.

        Hänvisa till underlaget med dess nummer i hakparentes, till exempel [2],
        direkt efter det du hämtat därifrån.
        """
        if träffar.isEmpty {
            ut += "\n\nDet finns inget underlag att gå på den här gången. Säg det."
        } else {
            ut += "\n\n# Underlag\n\n\(sammanhang)"
        }
        return ut
    }

    private func kropp(system: String, tidigare: [Meddelande], fråga: String,
                       ström: Bool = false) throws -> Data {
        var turer: [[String: String]] = []
        for m in tidigare {
            turer.append(["role": m.roll == .människa ? "user" : "assistant", "content": m.text])
        }
        turer.append(["role": "user", "content": fråga])

        if val.leverantör.talarAnthropic {
            // Anthropic har systemtexten som eget fält, inte som ett meddelande.
            var kropp: [String: Any] = [
                "model": val.modell,
                "max_tokens": 2000,
                "system": system,
                "messages": turer,
            ]
            if ström { kropp["stream"] = true }
            return try JSONSerialization.data(withJSONObject: kropp)
        }

        var kropp: [String: Any] = [
            "messages": [["role": "system", "content": system]] + turer,
            "max_tokens": 2000,
        ]
        if ström { kropp["stream"] = true }
        // Azure får modellen ur adressen, inte ur kroppen.
        if val.leverantör != .azure { kropp["model"] = val.modell }
        if val.leverantör == .openrouter {
            // Anthropic-modeller via OpenRouter kan annars lägga hela utrymmet
            // på att tänka och svara med tomt innehåll.
            kropp["reasoning"] = ["enabled": false]
        }
        return try JSONSerialization.data(withJSONObject: kropp)
    }

    static func läsOpenAI(_ data: Data) -> String? {
        struct Svarskropp: Decodable {
            struct Val: Decodable {
                struct M: Decodable { let content: String? }
                let message: M
            }
            let choices: [Val]
        }
        return (try? JSONDecoder().decode(Svarskropp.self, from: data))?
            .choices.first?.message.content
    }

    /// En SSE-rad från OpenAI-dialekten: texten ligger i choices[0].delta.
    static func deltaOpenAI(_ data: Data) -> String? {
        struct Rad: Decodable {
            struct Val: Decodable {
                struct D: Decodable { let content: String? }
                let delta: D?
            }
            let choices: [Val]?
        }
        return (try? JSONDecoder().decode(Rad.self, from: data))?
            .choices?.first?.delta?.content
    }

    /// En SSE-rad från Anthropic: bara content_block_delta bär text.
    static func deltaAnthropic(_ data: Data) -> String? {
        struct Rad: Decodable {
            struct D: Decodable { let type: String?; let text: String? }
            let type: String?
            let delta: D?
        }
        guard let rad = try? JSONDecoder().decode(Rad.self, from: data),
              rad.type == "content_block_delta",
              rad.delta?.type == "text_delta" else { return nil }
        return rad.delta?.text
    }

    static func läsAnthropic(_ data: Data) -> String? {
        struct Svarskropp: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        guard let k = try? JSONDecoder().decode(Svarskropp.self, from: data) else { return nil }
        return k.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    }

    /// Vilka av underlagen svaret faktiskt hänvisade till.
    static func använda(i text: String, av träffar: [Kunskapsbank.Träff]) -> [Hänvisning] {
        var ut: [Hänvisning] = []
        for (i, t) in träffar.enumerated() where text.contains("[\(i + 1)]") {
            ut.append(Hänvisning(nummer: i + 1, titel: t.titel, typ: t.typ,
                                 källa: t.källa, datum: t.tid))
        }
        return ut
    }

    private static func felmeddelande(_ data: Data) -> String {
        struct F: Decodable { struct I: Decodable { let message: String? }; let error: I? }
        return (try? JSONDecoder().decode(F.self, from: data))?.error?.message
            ?? String(data: data, encoding: .utf8)?.prefix(200).description
            ?? "okänt fel"
    }

    enum Fel: LocalizedError {
        case ingenNyckel(Leverantör), ingetSvar, tomtSvar, trasigAdress
        case nårInteLokal(String), frånTjänsten(Int, String)
        var errorDescription: String? {
            switch self {
            case .ingenNyckel(let l):
                "Ingen API-nyckel för \(l.namn). Lägg in den under Inställningar (⌘,)."
            case .ingetSvar: "Fick inget svar från modellen."
            case .tomtSvar: "Modellen svarade utan innehåll."
            case .trasigAdress: "Adressen till modellen går inte att tolka."
            case .nårInteLokal(let värd):
                "Når ingen modell på \(värd). Är Ollama eller LM Studio igång?"
            case .frånTjänsten(let kod, let text): "Modellen svarade \(kod): \(text)"
            }
        }
    }
}
