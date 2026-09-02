import Foundation

/// Skriver ett uppföljningsmejl ur mötets sammanfattning.
///
/// Utkastet öppnas i Mail — det skickas aldrig av appen. Texten är medvetet
/// mallad och inte modellskriven: den ska vara förutsägbar, komma på en
/// sekund och fungera utan nyckel. Det man vill ändra ändrar man i Mail.
enum Uppföljning {

    /// Brödtexten, punkt för punkt ur det mötet landade i.
    static func brödtext(för inspelning: Inspelning) -> String {
        guard let s = inspelning.sammanfattning else { return "" }
        var delar: [String] = ["Hej!", "Tack för mötet. Så här uppfattade jag att vi landade:"]

        if !s.beslut.isEmpty {
            delar.append("Beslut:\n" + s.beslut.map { "• \($0)" }.joined(separator: "\n"))
        }
        if !s.åtaganden.isEmpty {
            let rader = s.åtaganden.map { å in
                let vem = [å.vem, å.när].compactMap { $0 }.joined(separator: ", ")
                return "• \(å.vad)" + (vem.isEmpty ? "" : " (\(vem))")
            }
            delar.append("Att göra:\n" + rader.joined(separator: "\n"))
        }
        if !s.öppet.isEmpty {
            delar.append("Öppet till nästa gång:\n"
                         + s.öppet.map { "• \($0)" }.joined(separator: "\n"))
        }
        delar.append("Säg till om jag har missuppfattat något eller om något saknas.")

        let förnamn = NSFullUserName().components(separatedBy: " ").first ?? ""
        delar.append(förnamn.isEmpty ? "Hälsningar" : "Hälsningar\n\(förnamn)")
        return delar.joined(separator: "\n\n")
    }

    /// Deltagarnas adresser: de namngivna rösterna slås upp bland kundens
    /// kontakter. Blir det ingen träff lämnas mottagaren tom — hellre det än
    /// fel adress förifylld.
    static func mottagare(för inspelning: Inspelning, kontakter: [Kontakt]) -> [String] {
        let namn = Set(inspelning.röstnamn.values)
        return kontakter
            .filter { namn.contains($0.namn) }
            .compactMap(\.epost.first)
    }

    /// Öppnar ett utkast i Mail, synligt och osänt. Asynkron: är Mail inte
    /// igång tar starten sekunder, och de ska inte frysa fönstret.
    static func öppnaUtkast(ämne: String, text: String, till: [String]) async throws {
        var rader = [
            "tell application \"Mail\"",
            "set utkast to make new outgoing message with properties "
            + "{subject:\"\(fly(ämne))\", content:\"\(fly(text))\", visible:true}",
        ]
        for adress in till {
            rader.append("tell utkast to make new to recipient at end of to recipients "
                         + "with properties {address:\"\(fly(adress))\"}")
        }
        rader += ["activate", "end tell"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = rader.flatMap { ["-e", $0] }
        let utfall = try await Underprocess.kör(p, tidsgräns: 60)
        guard utfall.kod == 0 else {
            let text = utfall.feltext
            throw Enkeltfel("Mail kunde inte öppna utkastet: " + (text.isEmpty ? "okänt fel" : text))
        }
    }

    /// AppleScript-strängar flyr citattecken och bakstreck, inget annat.
    static func fly(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
