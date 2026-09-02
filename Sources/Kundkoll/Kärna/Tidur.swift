import Foundation
import AppKit
import UserNotifications

/// Ett stoppur för arbetstid: starta, skriv vad du gör, stoppa — posten
/// loggas på projektet.
///
/// Går datorn i vila fryser uret vid insomningen. Vid uppvaknandet kommer en
/// notis med frågan: logga tiden som den står, eller fortsätt räkna? Tills
/// någon svarar står uret stilla — tid som gick åt till att sova ska aldrig
/// smyga in i loggen.
@MainActor
final class Tidur: ObservableObject {
    static let delad = Tidur()

    struct Pågående: Codable, Equatable {
        var kund: String
        var projekt: String?
        var vad: String
        var start: Date
        /// Sekunder räknade före den senaste återupptagningen.
        var ackumulerat: Double = 0
        /// När det nuvarande räknandet började.
        var senasteStart: Date
        var pausad = false

        init(kund: String, projekt: String?, vad: String,
             start: Date = Date()) {
            self.kund = kund
            self.projekt = projekt
            self.vad = vad
            self.start = start
            self.senasteStart = start
        }

        /// Skriven för hand: se `Inspelning`.
        init(from avkodare: Decoder) throws {
            let c = try avkodare.container(keyedBy: CodingKeys.self)
            kund = try c.decodeIfPresent(String.self, forKey: .kund) ?? ""
            projekt = try c.decodeIfPresent(String.self, forKey: .projekt)
            vad = try c.decodeIfPresent(String.self, forKey: .vad) ?? ""
            start = try c.decodeIfPresent(Date.self, forKey: .start) ?? Date()
            ackumulerat = try c.decodeIfPresent(Double.self, forKey: .ackumulerat) ?? 0
            senasteStart = try c.decodeIfPresent(Date.self, forKey: .senasteStart) ?? Date()
            pausad = try c.decodeIfPresent(Bool.self, forKey: .pausad) ?? false
        }

        /// Så här länge har uret gått, sovtid borträknad.
        func gången(nu: Date = Date()) -> Double {
            ackumulerat + (pausad ? 0 : max(0, nu.timeIntervalSince(senasteStart)))
        }
    }

    @Published private(set) var pågående: Pågående? {
        didSet { sparaUndan() }
    }

    private var lyssnare: [NSObjectProtocol] = []
    private static let nyckel = "kundkoll.tidur"

    init() {
        // Ett ur som gick när appen stängdes ska gå när den öppnas igen —
        // klockan är väggtid, inte processortid.
        if let data = UserDefaults.standard.data(forKey: Self.nyckel),
           let p = try? JSONDecoder.kundkoll.decode(Pågående.self, from: data) {
            pågående = p
        }

        let central = NSWorkspace.shared.notificationCenter
        lyssnare.append(central.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Tidur.delad.datornSomnar() }
        })
        lyssnare.append(central.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Tidur.delad.datornVaknar() }
        })
    }

    // MARK: - Körning

    func starta(kund: String, projekt: String?, vad: String) {
        guard pågående == nil else { return }
        pågående = Pågående(kund: kund, projekt: projekt, vad: vad)
        Notiser.begär()
    }

    func byt(vad: String) {
        pågående?.vad = vad
    }

    /// Ett ur som går hos en kund som byter namn ska följa med.
    func byt(kund gammalt: String, till nytt: String) {
        guard pågående?.kund == gammalt else { return }
        pågående?.kund = nytt
    }

    func byt(projekt gammalt: String, till nytt: String, hos kund: String) {
        guard pågående?.kund == kund, pågående?.projekt == gammalt else { return }
        pågående?.projekt = nytt
    }

    func pausa(vid tid: Date = Date()) {
        guard var p = pågående, !p.pausad else { return }
        p.ackumulerat += max(0, tid.timeIntervalSince(p.senasteStart))
        p.pausad = true
        pågående = p
    }

    func fortsätt(från tid: Date = Date()) {
        guard var p = pågående, p.pausad else { return }
        p.senasteStart = tid
        p.pausad = false
        pågående = p
    }

    /// Stoppar och loggar. Ger posten som skrevs, om det fanns någon tid.
    @discardableResult
    func stoppa(vid tid: Date = Date()) -> Tidspost? {
        guard let p = pågående else { return nil }
        pågående = nil
        let sekunder = p.gången(nu: tid)
        guard sekunder >= 30 else { return nil }   // kortare är ett felklick
        let post = Tidspost(vad: p.vad.isEmpty ? "Arbete" : p.vad,
                            projekt: p.projekt, start: p.start, sekunder: sekunder)
        if let kund = Arkivet.shared.kunder.first(where: { $0.namn == p.kund }) {
            try? Arkivet.shared.läggTill(post, för: kund)
        }
        return post
    }

    /// Kastar uret utan att logga.
    func släng() {
        pågående = nil
    }

    // MARK: - Vila

    private func datornSomnar() {
        guard pågående != nil, pågående?.pausad == false else { return }
        pausa()
    }

    private func datornVaknar() {
        guard let p = pågående, p.pausad else { return }
        let text = "Uret för \(p.projekt ?? p.kund) pausades när datorn somnade — "
            + "\(Tidspost.längdtext(p.gången())) räknade. Logga, eller fortsätt räkna?"
        Notiser.tidursfråga(text)
    }

    private func sparaUndan() {
        if let p = pågående, let data = try? JSONEncoder.kundkoll.encode(p) {
            UserDefaults.standard.set(data, forKey: Self.nyckel)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.nyckel)
        }
    }
}
