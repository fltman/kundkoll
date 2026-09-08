import Foundation
import PDFKit
import Vision
import AppKit

/// Hämtar bilagor ur mejl och plockar ut texten i dem.
///
/// Det är texten som ska in i kunskapsbanken: en offert i en PDF eller en
/// skärmbild med en tabell säger ofta mer än mejlet den satt i.
///
/// Allt görs på datorn. PDFKit läser PDF:er, Vision läser text i bilder — och
/// stöder svenska, vilket är en förutsättning här.
///
/// Ingenting här rör gränssnittet, så det ligger utanför huvudaktören. Att
/// binda det dit skulle låsa huvudtråden under textutvinningen, som tar
/// sekunder per bild.
enum Bilagor {

    struct Bilaga: Codable, Hashable, Identifiable {
        var id: String { fil }
        var ämne: String
        var namn: String
        var fil: String
        var storlek: Int
        /// Texten som gick att få ut, om någon.
        var text: String?

        init(ämne: String, namn: String, fil: String, storlek: Int, text: String? = nil) {
            self.ämne = ämne
            self.namn = namn
            self.fil = fil
            self.storlek = storlek
            self.text = text
        }

        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            ämne = try c.decodeIfPresent(String.self, forKey: .ämne) ?? ""
            namn = try c.decodeIfPresent(String.self, forKey: .namn) ?? ""
            fil = try c.decodeIfPresent(String.self, forKey: .fil) ?? ""
            storlek = try c.decodeIfPresent(Int.self, forKey: .storlek) ?? 0
            text = try c.decodeIfPresent(String.self, forKey: .text)
        }

        var url: URL { URL(fileURLWithPath: fil) }
        var ändelse: String { url.pathExtension.lowercased() }
    }

    /// Format det är någon mening med att spara. Kalenderfiler och signaturer
    /// hamnar annars i mängd utan att tillföra något.
    static let ointressanta: Set<String> = ["ics", "vcf", "p7s", "asc", "sig"]

    static func ärIntressant(_ namn: String) -> Bool {
        let ändelse = (namn as NSString).pathExtension.lowercased()
        if ointressanta.contains(ändelse) { return false }
        // Inbäddade signaturbilder heter nästan alltid så här och innehåller
        // logotyper, inte information.
        let bas = (namn as NSString).deletingPathExtension.lowercased()
        if bas.hasPrefix("image00") && bas.count <= 8 { return false }
        return true
    }

    // MARK: - Hämta

    /// Sparar bilagor från mejl till eller från en adress.
    static func hämta(adress: String, till mapp: URL, max antal: Int = 40,
                      skript: URL) async throws -> [Bilaga] {
        try FileManager.default.createDirectory(at: mapp, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [skript.path, adress, mapp.path, String(antal)]
        let utfall = try await Underprocess.kör(p, tidsgräns: 10 * 60)

        guard utfall.kod == 0 else {
            let text = utfall.feltext
            throw text.contains("not allowed") || text.contains("-1743")
                ? Fel.nekad
                : Fel.frånMail(text)
        }
        return tolka(utfall.uttext, inom: mapp)
    }

    /// - Parameter inom: mappen bilagorna ska ligga i. Filnamnet kommer från
    ///   avsändaren, och ett namn med snedstreck eller punkt-punkt får inte
    ///   peka någon annanstans. Skriptet rensar namnet; det här är bältet
    ///   till hängslena.
    static func tolka(_ text: String, inom mapp: URL? = nil) -> [Bilaga] {
        return text.split(separator: "\n").compactMap { rad in
            let f = rad.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let storlek = Int(f[3].trimmingCharacters(in: .whitespaces)),
                  ärIntressant(f[1]) else { return nil }
            let väg = URL(fileURLWithPath: f[2]).standardizedFileURL.path
            if let mapp, !Arkivet.ligger(väg, i: mapp) || Arkivet.kanonisk(väg) == Arkivet.kanonisk(mapp.path) {
                return nil
            }
            return Bilaga(ämne: f[0], namn: f[1], fil: väg, storlek: storlek)
        }
    }

    enum Fel: LocalizedError {
        case nekad, frånMail(String)
        var errorDescription: String? {
            switch self {
            case .nekad:
                "\(Appnamn.visat) får inte styra Mail. Ge tillstånd i Systeminställningar → Integritet och säkerhet → Automatisering."
            case .frånMail(let f):
                f.isEmpty ? "Mail svarade med ett fel." : "Mail svarade: \(f)"
            }
        }
    }

    // MARK: - Läsa

    /// Plockar ut texten ur en bilaga. Nil när formatet inte bär text.
    static func text(ur bilaga: Bilaga) async -> String? {
        let url = bilaga.url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        switch bilaga.ändelse {
        case "pdf":
            return textUrPDF(url)
        case "txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
             "log", "rtf", "yaml", "yml", "toml", "css", "scss",
             "swift", "py", "js", "jsx", "ts", "tsx", "rb", "go", "rs", "java",
             "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash",
             "zsh", "sql", "r", "jl", "lua", "pl", "vue", "svelte":
            return textUrFil(url)
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp":
            return await textUrBild(url)
        case "docx", "pptx", "xlsx":
            return await textUrKontorsfil(url)
        default:
            return nil
        }
    }

    private static func textUrPDF(_ url: URL) -> String? {
        guard let dok = PDFDocument(url: url) else { return nil }
        var ut = ""
        for i in 0..<dok.pageCount {
            if let sida = dok.page(at: i)?.string { ut += sida + "\n" }
        }
        let rent = ut.trimmingCharacters(in: .whitespacesAndNewlines)
        // En inskannad PDF har inget textlager. Den skulle behöva bildtolkning
        // sida för sida, vilket är mer än det oftast är värt.
        return rent.count > 20 ? rent : nil
    }

    private static func textUrFil(_ url: URL) -> String? {
        for kodning in [String.Encoding.utf8, .isoLatin1, .macOSRoman] {
            if let s = try? String(contentsOf: url, encoding: kodning) {
                let rent = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return rent.isEmpty ? nil : rent
            }
        }
        return nil
    }

    /// Läser text i en bild. Skärmbilder ur mejl innehåller ofta tabeller och
    /// siffror som inte finns någon annanstans.
    private static func textUrBild(_ url: URL) async -> String? {
        guard let bild = NSImage(contentsOf: url),
              let cg = bild.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        return await withCheckedContinuation { fortsätt in
            let begäran = VNRecognizeTextRequest { svar, _ in
                let rader = (svar.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = rader.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Ett par lösryckta ord är oftast en logotyp, inte innehåll.
                fortsätt.resume(returning: text.count > 25 ? text : nil)
            }
            begäran.recognitionLevel = .accurate
            begäran.recognitionLanguages = ["sv-SE", "en-US"]
            begäran.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([begäran])
        }
    }

    /// docx, pptx och xlsx är zip-arkiv med XML. Texten sitter mellan taggarna.
    private static func textUrKontorsfil(_ url: URL) async -> String? {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq", "-o", url.path, "-d", temp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? await Underprocess.väntaIn(p, tidsgräns: 60)) != nil else { return nil }
        guard p.terminationStatus == 0 else { return nil }

        guard let filer = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil)
        else { return nil }
        var ut = ""
        for fall in filer {
            guard let f = fall as? URL, f.pathExtension == "xml",
                  ärInnehåll(f), let xml = try? String(contentsOf: f, encoding: .utf8)
            else { continue }
            ut += strippaTaggar(xml) + "\n"
        }
        let rent = ut.trimmingCharacters(in: .whitespacesAndNewlines)
        return rent.count > 20 ? rent : nil
    }

    /// Bara filerna som bär text. Ett kontorsdokument innehåller också
    /// inställningar, teman och egenskaper, och de gav rader som "Microsoft
    /// Office Word 0 406 248" mitt i innehållet.
    static func ärInnehåll(_ url: URL) -> Bool {
        let väg = url.path.lowercased()
        // word/document.xml, ppt/slides/slideN.xml, xl/sharedStrings.xml
        if väg.contains("/word/document.xml") { return true }
        if väg.contains("/ppt/slides/slide") { return true }
        if väg.contains("/xl/sharedstrings.xml") { return true }
        if väg.contains("/word/footnotes.xml") || väg.contains("/word/endnotes.xml") { return true }
        return false
    }

    static func strippaTaggar(_ xml: String) -> String {
        var ut = ""
        var iTagg = false
        for tecken in xml {
            if tecken == "<" { iTagg = true; ut += " " }
            else if tecken == ">" { iTagg = false }
            else if !iTagg { ut.append(tecken) }
        }
        let rent = ut.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // XML-entiteter blir annars kvar mitt i texten.
        return rent
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
