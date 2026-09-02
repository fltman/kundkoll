import Foundation

/// Lyssnar på ett pågående samtal och hittar sådant som behöver slås upp.
///
/// Detekteringen körs på en lokal modell via Ollama. Apples inbyggda
/// FoundationModels provades först och dög inte: den träffade 3 av 8 och
/// hittade frågeställningar där det inte fanns några — en liten modell som
/// ombeds skriva fritt vill alltid vara hjälpsam. Dess strukturerade utdata,
/// som hade gjort det till en ren klassificering, kräver ett makro-plugin som
/// bara finns i Xcode-toolchainen.
///
/// Uppmätt på tolv stycken ur riktiga möten:
///
/// | modell | rätt | falska larm | median |
/// |---|---|---|---|
/// | Apple FoundationModels | 3/8 | många | 0,6 s |
/// | gemma3:1b | 7/12 | 4 | 0,8 s |
/// | gemma3:4b | 11/12 | 1 | 1,7 s |
/// | qwen3:8b | 12/12 | 0 | 2,4 s |
///
/// Allt stannar på datorn. Först när en frågeställning hittats går den vidare
/// till kunskapsbanken, och därifrån till den modell som valts för chatten.
actor Insikter {

    struct Bedömning: Decodable {
        var behoverSlaUpp: Bool
        var fragestallning: String
    }

    /// qwen3:8b var den enda som inte gav ett enda falskt larm. Ett falskt larm
    /// är värre än ett missat: en assistent som avbryter mötet med påhittade
    /// frågor blir avstängd, en som missar en fråga stör ingen.
    static let standardmodell = "qwen3:8b"

    private let modell: String
    private let adress: URL
    private let session: URLSession

    init(modell: String = Inställningar.insiktsmodell,
         adress: URL = URL(string: "http://127.0.0.1:11434/api/chat")!) {
        self.modell = modell
        self.adress = adress
        let k = URLSessionConfiguration.ephemeral
        k.timeoutIntervalForRequest = 90
        session = URLSession(configuration: k)
    }

    static let instruktion = """
    Du lyssnar på ett affärssamtal och avgör en enda sak: behöver deltagarna slå \
    upp något i tidigare möten, mejl eller anteckningar med kunden?

    Sätt behoverSlaUpp till true bara när någon inte minns vad som sagts \
    tidigare, behöver kontrollera en uppgift, ett pris, en tid eller ett löfte, \
    eller säger att något ska kollas upp.

    false är det vanliga svaret. Det gäller resonemang och samtalsämnen, \
    retoriska frågor, frågor om vem som ska tala, artigheter, och allt som \
    besvaras direkt i samtalet.

    Skriv fragestallning som en fråga man kan slå upp, på svenska.
    """

    /// Ollama tar emot ett JSON-schema och håller sig till det. Utan det blir
    /// svaret fritext, och då hittar modellen alltid något att säga.
    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "behoverSlaUpp": ["type": "boolean"],
            "fragestallning": ["type": "string"],
        ],
        "required": ["behoverSlaUpp", "fragestallning"],
    ]

    var tillgänglig: Bool {
        get async {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
            r.timeoutInterval = 2
            return (try? await session.data(for: r)) != nil
        }
    }

    /// Ser efter om ett stycke samtal innehåller något att slå upp.
    func granska(_ text: String) async throws -> String? {
        let kropp: [String: Any] = [
            "model": modell,
            "messages": [
                ["role": "system", "content": Self.instruktion],
                ["role": "user", "content": text],
            ],
            "stream": false,
            "format": Self.schema,
            "options": ["temperature": 0, "num_predict": 200],
            // Utan detta lägger qwen3 tid på att tänka högt, vilket inte
            // behövs för en ja-eller-nej-fråga.
            "think": false,
        ]
        var r = URLRequest(url: adress)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: kropp)

        let (data, svar) = try await session.data(for: r)
        guard let http = svar as? HTTPURLResponse, http.statusCode == 200 else {
            throw Fel.ingenModell
        }
        struct Yttre: Decodable {
            struct M: Decodable { let content: String }
            let message: M
        }
        guard let yttre = try? JSONDecoder().decode(Yttre.self, from: data),
              let inre = try? JSONDecoder().decode(
                Bedömning.self, from: Data(yttre.message.content.utf8))
        else { throw Fel.otolkbart }

        guard inre.behoverSlaUpp else { return nil }
        let fråga = inre.fragestallning.trimmingCharacters(in: .whitespacesAndNewlines)
        return fråga.count >= 8 ? fråga : nil
    }

    enum Fel: LocalizedError {
        case ingenModell, otolkbart
        var errorDescription: String? {
            switch self {
            case .ingenModell:
                "Når ingen lokal modell. Insikter kräver att Ollama är igång."
            case .otolkbart: "Den lokala modellen svarade med något oväntat."
            }
        }
    }
}

/// Inställningar som gäller hela appen.
enum Inställningar {
    /// Modellen som lyssnar efter frågeställningar under samtal.
    static var insiktsmodell: String {
        get { UserDefaults.standard.string(forKey: "kundkoll.insiktsmodell") ?? Insikter.standardmodell }
        set { UserDefaults.standard.set(newValue, forKey: "kundkoll.insiktsmodell") }
    }

    /// Om appen ska lyssna efter frågeställningar under inspelning.
    static var insikterPå: Bool {
        get { UserDefaults.standard.object(forKey: "kundkoll.insikterPå") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "kundkoll.insikterPå") }
    }

    /// Om chatten ska ligga uppfälld i transkriptvyn.
    static var mötesChattPå: Bool {
        get { UserDefaults.standard.object(forKey: "kundkoll.mötesChattPå") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "kundkoll.mötesChattPå") }
    }

    /// Om en röst som lärts in hos en kund ska kännas igen hos andra.
    ///
    /// Av som standard: profilerna ligger hos kunden med flit, och samma
    /// person kan förekomma i flera kundärenden utan att man vill koppla ihop
    /// dem. Men träffar man samma leverantör hos två kunder är det bara
    /// dubbelarbete att namnge om.
    static var delaRöstprofiler: Bool {
        get { UserDefaults.standard.bool(forKey: "kundkoll.delaRöstprofiler") }
        set { UserDefaults.standard.set(newValue, forKey: "kundkoll.delaRöstprofiler") }
    }

    /// Om modellen får skriva sammanfattningar, leta uppgifter i mejl och
    /// skriva lägesbilder utan att någon bett om det.
    ///
    /// Med en molnmodell vald betyder det att hela transkript och mejl
    /// lämnar datorn i bakgrunden. Det står i inställningarna i klartext,
    /// och det går att stänga av: då skrivs sammanfattningen först när man
    /// trycker på knappen i mötesvyn.
    static var automatiskaModellanrop: Bool {
        get { UserDefaults.standard.object(forKey: "kundkoll.automatiskaModellanrop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "kundkoll.automatiskaModellanrop") }
    }

    /// Var whisper.cpp ligger. Tomt betyder ~/Projekt/whisper.cpp.
    static var whisperRot: String? {
        get { tom(UserDefaults.standard.string(forKey: "kundkoll.whisperRot")) }
        set { UserDefaults.standard.set(tom(newValue), forKey: "kundkoll.whisperRot") }
    }

    /// Pythonmiljön med torch, speechbrain och mlx-whisper. Tomt betyder
    /// ~/Projekt/transcriber/venv.
    static var pythonMiljö: String? {
        get { tom(UserDefaults.standard.string(forKey: "kundkoll.pythonMiljö")) }
        set { UserDefaults.standard.set(tom(newValue), forKey: "kundkoll.pythonMiljö") }
    }

    private static func tom(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}
