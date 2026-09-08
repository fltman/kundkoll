import Foundation
import AppKit

/// Söker i Mail via AppleScript.
///
/// Valet av väg är mätt: mejlen ligger också som filer under ~/Library/Mail,
/// och att söka dem direkt tar konstant 3,5 s oavsett träffmängd — snabbare
/// vid stora sökningar. Men den vägen kräver Full Disk Access, medan
/// AppleScript bara behöver automationsbehörighet. Eftersom vi alltid söker på
/// en bestämd kundadress och inte på breda domäner räcker AppleScript väl.
actor Mailen {

    /// Ett mejl.
    ///
    /// Avkodningen är skriven för hand. Swift använder **inte** standardvärden
    /// när en nyckel saknas i JSON — den kastar. Ett nytt fält gör då att alla
    /// tidigare sparade filer slutar gå att läsa, och felet syns bara som att
    /// ingenting händer. Det inträffade när brödtexten lades till: hela
    /// mejlcachen blev oläsbar och bilagorna hämtades aldrig.
    struct Mejl: Identifiable, Hashable, Codable {
        var id: String { meddelandeID.isEmpty ? "\(datum)-\(ämne)" : meddelandeID }
        var datum: Date?
        var datumText: String
        var avsändare: String
        var ämne: String
        var meddelandeID: String
        var konto: String
        var låda: String
        /// "från" för mottagna, "till" för sådana jag skickat.
        var riktning: String
        /// Brödtexten, kapad. Ämnesraden säger sällan vad som faktiskt stod.
        var text: String = ""

        var skickat: Bool { riktning == "till" }

        init(datum: Date?, datumText: String, avsändare: String, ämne: String,
             meddelandeID: String, konto: String, låda: String, riktning: String,
             text: String = "") {
            self.datum = datum
            self.datumText = datumText
            self.avsändare = avsändare
            self.ämne = ämne
            self.meddelandeID = meddelandeID
            self.konto = konto
            self.låda = låda
            self.riktning = riktning
            self.text = text
        }

        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            datum = try c.decodeIfPresent(Date.self, forKey: .datum)
            datumText = try c.decodeIfPresent(String.self, forKey: .datumText) ?? ""
            avsändare = try c.decodeIfPresent(String.self, forKey: .avsändare) ?? ""
            ämne = try c.decodeIfPresent(String.self, forKey: .ämne) ?? ""
            meddelandeID = try c.decodeIfPresent(String.self, forKey: .meddelandeID) ?? ""
            konto = try c.decodeIfPresent(String.self, forKey: .konto) ?? ""
            låda = try c.decodeIfPresent(String.self, forKey: .låda) ?? ""
            riktning = try c.decodeIfPresent(String.self, forKey: .riktning) ?? "fran"
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        }

        /// Namnet ur "Anna Svensson <anna@acme.se>".
        var avsändarnamn: String {
            guard let i = avsändare.firstIndex(of: "<") else { return avsändare }
            return String(avsändare[..<i])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }

        var avsändaradress: String {
            guard let a = avsändare.firstIndex(of: "<"),
                  let b = avsändare.firstIndex(of: ">"), a < b else { return avsändare }
            return String(avsändare[avsändare.index(after: a)..<b])
        }

        /// Öppnar mejlet i Mail.
        func öppna() {
            guard !meddelandeID.isEmpty else { return }
            let rensat = meddelandeID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let kodat = rensat.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "message://%3c\(kodat)%3e") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private let skript: URL

    init(skript: URL? = nil) {
        self.skript = skript ?? URL(fileURLWithPath: Bundle.main.bundlePath)
            .appending(path: "Contents/Resources/mail-sok.applescript")
    }

    var finns: Bool { FileManager.default.fileExists(atPath: skript.path) }

    /// Mejl till eller från en adress, nyast först.
    ///
    /// `antal` gäller per postlåda i skriptet, så resultatet kan bli fler —
    /// annars skulle inkorgen fylla hela kvoten och det man själv skickat
    /// aldrig komma med. Här klipps listan efter att den sorterats på datum.
    func sök(adress: String, max antal: Int = 20) async throws -> [Mejl] {
        guard FileManager.default.fileExists(atPath: skript.path) else {
            throw Fel.skriptSaknas
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [skript.path, adress, String(antal)]
        // Mail som står och väntar på en behörighetsfråga fick tidigare
        // sökningen att hänga för evigt.
        let utfall = try await Underprocess.kör(p, tidsgräns: 3 * 60)

        if utfall.kod != 0 {
            let text = utfall.feltext
            throw text.contains("not allowed") || text.contains("-1743")
                ? Fel.nekad
                : Fel.frånMail(text)
        }
        return Array(Self.tolka(utfall.uttext).prefix(antal * 2))
    }

    /// Fälten är åtskilda av ASCII 31, eftersom ämnesrader gärna innehåller
    /// både tabbar och rörtecken.
    static func tolka(_ text: String) -> [Mejl] {
        text.split(separator: "\n").compactMap { rad -> Mejl? in
            let f = rad.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { return nil }
            return Mejl(datum: datum(ur: f[0]), datumText: f[0], avsändare: f[1],
                        ämne: f[2], meddelandeID: f[3], konto: f[4], låda: f[5],
                        riktning: f.count > 6 ? f[6].trimmingCharacters(in: .whitespacesAndNewlines) : "fran",
                        text: f.count > 7 ? Self.städaBrödtext(f[7]) : "")
        }
        .sorted { ($0.datum ?? .distantPast) > ($1.datum ?? .distantPast) }
    }

    /// Tar bort citerade svar och signaturer. Ett långt mejl är ofta mest
    /// tidigare korrespondens, och den finns redan indexerad var för sig.
    static func städaBrödtext(_ rå: String) -> String {
        var text = rå.trimmingCharacters(in: .whitespacesAndNewlines)
        let markörer = ["Från: ", "From: ", "-----Ursprungligt meddelande-----",
                        "-----Original Message-----", "Skickat från min iPhone",
                        "Sent from my iPhone"]
        for markör in markörer {
            if let träff = text.range(of: markör) {
                text = String(text[..<träff.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mail lämnar datum som "Tuesday, 18 August 2026 at 00:49:37".
    /// Att fråga efter datumobjekt i stället går inte att lita på, se
    /// anteckningarna om datumfiltrering i AppleScript.
    private static let datumformat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm:ss"
        return f
    }()

    static func datum(ur text: String) -> Date? {
        datumformat.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    enum Fel: LocalizedError {
        case skriptSaknas, nekad, frånMail(String)
        var errorDescription: String? {
            switch self {
            case .skriptSaknas: "Sökskriptet för Mail saknas i appen."
            case .nekad: "\(Appnamn.visat) får inte styra Mail. Ge tillstånd i Systeminställningar → Integritet och säkerhet → Automatisering."
            case .frånMail(let f): "Mail svarade med ett fel: \(f)"
            }
        }
    }
}
