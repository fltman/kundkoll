import Foundation
import AppKit

/// Öppnar en mapp eller fil i Obsidian.
///
/// `obsidian://open?path=` fungerar bara för filer som ligger i ett **känt**
/// valv — annars svarar Obsidian "Vault not found". Kundmapparna har `.obsidian`
/// och är valv i allt utom att Obsidian ännu inte hört talas om dem.
///
/// Att öppna mappen med `open -a Obsidian` registrerar den inte. Det som
/// fungerar är att lägga till den i Obsidians egen lista, och den läses om
/// direkt utan omstart. Appen skriver alltså i en annan apps
/// inställningsfil — motiverat därför att det är enda vägen, ändringen är
/// precis vad knappen utlovar, och den går att ta bort i Obsidian.
enum Obsidian {
    static var finns: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Obsidian.app")
    }

    private static var listan: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/obsidian/obsidian.json")
    }

    /// Sökvägarna till de valv Obsidian känner till.
    static func kändaValv() -> [String] {
        guard let data = try? Data(contentsOf: listan),
              let rot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valv = rot["vaults"] as? [String: Any] else { return [] }
        return valv.values.compactMap { ($0 as? [String: Any])?["path"] as? String }
    }

    /// Vilket känt valv filen ligger i, om något.
    static func valv(för url: URL) -> String? {
        let väg = url.standardizedFileURL.path
        return kändaValv()
            .filter { väg == $0 || väg.hasPrefix($0 + "/") }
            // Djupast liggande valv vinner om de skulle vara nästlade.
            .max { $0.count < $1.count }
    }

    /// Går uppåt från en fil tills en mapp med `.obsidian` dyker upp.
    static func hittaValvrot(från url: URL) -> URL? {
        var mapp = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: mapp.appending(path: ".obsidian").path) {
                return mapp
            }
            let upp = mapp.deletingLastPathComponent()
            if upp == mapp { break }
            mapp = upp
        }
        return nil
    }

    /// Lägger till mappen i Obsidians lista. Obsidian läser om den direkt.
    @discardableResult
    static func registrera(valv mapp: URL) -> Bool {
        let väg = mapp.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: väg) else { return false }
        if kändaValv().contains(väg) { return true }

        guard let data = try? Data(contentsOf: listan),
              var rot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var valv = rot["vaults"] as? [String: Any] else { return false }

        // Obsidian identifierar valv med 16 hexadecimala tecken.
        var id = ""
        for _ in 0..<16 { id += String(Int.random(in: 0..<16), radix: 16) }
        valv[id] = ["path": väg,
                    "ts": Int(Date().timeIntervalSince1970 * 1000),
                    "open": false] as [String: Any]
        rot["vaults"] = valv

        guard let ny = try? JSONSerialization.data(withJSONObject: rot) else { return false }
        return (try? ny.write(to: listan, options: .atomic)) != nil
    }

    /// Tar bort mappen ur Obsidians lista, när kunden tagits bort.
    @discardableResult
    static func avregistrera(valv mapp: URL) -> Bool {
        skrivOmValv { valv in
            let väg = mapp.standardizedFileURL.path
            valv = valv.filter { ($0.value as? [String: Any])?["path"] as? String != väg }
        }
    }

    /// Pekar om ett valv efter ett namnbyte. Obsidian läser listan när den
    /// startar, så en körande Obsidian ser det först efter omstart.
    @discardableResult
    static func byt(valv gammal: URL, till ny: URL) -> Bool {
        skrivOmValv { valv in
            let g = gammal.standardizedFileURL.path
            for (id, post) in valv {
                guard var p = post as? [String: Any], p["path"] as? String == g else { continue }
                p["path"] = ny.standardizedFileURL.path
                valv[id] = p
            }
        }
    }

    /// Skriver Obsidians lista bara om något faktiskt ändrats — det är en
    /// annan apps fil, och den ska inte röras i onödan.
    private static func skrivOmValv(_ ändra: (inout [String: Any]) -> Void) -> Bool {
        guard let data = try? Data(contentsOf: listan),
              var rot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var valv = rot["vaults"] as? [String: Any] else { return false }
        let före = valv.mapValues { ($0 as? [String: Any])?["path"] as? String ?? "" }
        ändra(&valv)
        let efter = valv.mapValues { ($0 as? [String: Any])?["path"] as? String ?? "" }
        guard före != efter else { return false }
        rot["vaults"] = valv
        guard let ny = try? JSONSerialization.data(withJSONObject: rot) else { return false }
        return (try? ny.write(to: listan, options: .atomic)) != nil
    }

    /// Öppnar sökvägen, och gör mappen känd för Obsidian först om det behövs.
    /// - Parameter valvrot: kundens mapp. Utelämnas den letas den upp genom
    ///   att gå uppåt tills en mapp med `.obsidian` hittas.
    static func öppna(_ url: URL, valvrot: URL? = nil) {
        let varOkänt = valv(för: url) == nil
        if varOkänt, let rot = valvrot ?? hittaValvrot(från: url) {
            registrera(valv: rot)
            // Obsidian läser sin valvlista när den startar. Ett valv som just
            // lagts till syns därför inte förrän den startats om, och länken
            // svarar "Vault not found" tills dess.
            if kör {
                berättaOmOmstart(valv: rot)
                return
            }
        }
        guard let kodad = url.path.addingPercentEncoding(
                withAllowedCharacters: .urlQueryValueAllowed),
              let mål = URL(string: "obsidian://open?path=\(kodad)") else { return }
        NSWorkspace.shared.open(mål)
    }

    static var kör: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty
    }

    /// Frågar om Obsidian får startas om, så att det nya valvet syns.
    private static func berättaOmOmstart(valv rot: URL) {
        let ruta = NSAlert()
        ruta.messageText = "\(rot.lastPathComponent) är nu ett valv i Obsidian"
        ruta.informativeText = """
            Obsidian läser sin lista över valv när den startar, så den behöver             startas om innan länkarna hittar hit.
            """
        ruta.addButton(withTitle: "Starta om Obsidian")
        ruta.addButton(withTitle: "Senare")
        guard ruta.runModal() == .alertFirstButtonReturn else { return }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian") {
            app.terminate()
        }
        // Vänta tills den faktiskt stängt, annars startar den inte om.
        Task { @MainActor in
            for _ in 0..<40 {
                if !kör { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/Obsidian.app"),
                configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

extension CharacterSet {
    /// Tecken som får stå i ett frågesträngsvärde. Snedstreck och åäö måste
    /// kodas, annars tappar Obsidian sökvägen.
    static let urlQueryValueAllowed: CharacterSet = {
        var c = CharacterSet.urlQueryAllowed
        c.remove(charactersIn: "/?&=+")
        return c
    }()
}
