import Foundation

/// Det som syns: namnet i Dock, menyer, fönster och texter. Identiteten
/// under huven — bundle-id, `.kundkoll`-mapparna, inställningsnycklarna
/// och nyckelringstjänsten — heter fortfarande kundkoll: ett byte där
/// nollställer behörigheterna och tappar nycklarna.
enum Appnamn {
    static let visat = "Bjarbys kundkoll"
    static let hemsida = URL(string: "https://anders.bjarby.com")!
    static let patreon = URL(string: "https://www.patreon.com/AndersBjarby")!

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}
