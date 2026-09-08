import Foundation
import EventKit

/// Läser möten ur Kalender och knyter dem till rätt kund.
///
/// Bara läsning. Nyttan är dubbel: man ser vad som är på gång hos en kund, och
/// när en inspelning startas från ett möte följer titel och deltagare med — och
/// deltagarlistan är precis de kandidater röstanalysen behöver för att sätta
/// namn på rösterna.
@MainActor
final class Kalendern: ObservableObject {
    static let shared = Kalendern()

    private let butik = EKEventStore()

    @Published private(set) var behörighet: EKAuthorizationStatus =
        EKEventStore.authorizationStatus(for: .event)
    /// Räknas upp när kalendern ändrats. Vyer som visar möten lyssnar på den
    /// och hämtar om — ett nyinbokat möte ska synas utan att man byter kund.
    @Published private(set) var ändringar = 0

    private var lyssnare: NSObjectProtocol?

    init() {
        lyssnare = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: butik, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ändringar += 1 }
        }
    }

    deinit {
        if let lyssnare { NotificationCenter.default.removeObserver(lyssnare) }
    }

    var harTillgång: Bool { behörighet == .fullAccess }

    struct Möte: Identifiable, Hashable {
        var id: String
        var titel: String
        var start: Date
        var slut: Date
        var deltagare: [Deltagare]
        var plats: String?
        /// Länk till Teams, Zoom, Meet och liknande, om mötet har en.
        var möteslänk: URL?

        var pågår: Bool { let nu = Date(); return start <= nu && nu <= slut }
        var längd: Double { slut.timeIntervalSince(start) }
    }

    struct Deltagare: Hashable {
        var namn: String
        var epost: String?
        var ärJag: Bool
    }

    @discardableResult
    func begärTillgång() async -> Bool {
        let ok = (try? await butik.requestFullAccessToEvents()) ?? false
        behörighet = EKEventStore.authorizationStatus(for: .event)
        return ok
    }

    /// Möten som ännu inte är över.
    ///
    /// Passerade möten hörde tidigare med, men det finns inget att göra med
    /// dem: ett möte som var i förrgår går inte att spela in, och de trängde
    /// undan de som faktiskt är på gång. Vill man lägga till en inspelning i
    /// efterhand görs det under Inspelningar.
    func möten(tillDagar framåt: Int = 21) -> [Möte] {
        guard harTillgång else { return [] }
        let nu = Date()
        // Dagens början, så att ett möte som just tagit slut fortfarande går
        // att hitta — det filtreras bort nedan men fångas av predikatet.
        let start = Calendar.current.startOfDay(for: nu)
        let slut = Calendar.current.date(byAdding: .day, value: framåt, to: nu) ?? nu
        let predikat = butik.predicateForEvents(withStart: start, end: slut, calendars: nil)
        let alla = butik.events(matching: predikat)
            .filter { !$0.isAllDay }
            .map(omvandla)

        // Samma möte ligger ofta i flera kalendrar samtidigt.
        var sedda = Set<String>()
        let unika = alla.filter {
            sedda.insert("\($0.titel)|\($0.start.timeIntervalSince1970)").inserted
        }

        return unika
            .filter { $0.slut >= Date() }
            .sorted { $0.start < $1.start }
    }

    private func omvandla(_ e: EKEvent) -> Möte {
        var seddaDeltagare = Set<String>()
        let deltagare = (e.attendees ?? []).compactMap { d -> Deltagare? in
            let namn = d.name ?? d.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
            // Konferensrum och annan utrustning är också deltagare i EventKit,
            // men de säger inget om vem man ska prata med.
            guard d.participantType == .person || d.participantType == .unknown else { return nil }
            guard !namn.isEmpty, seddaDeltagare.insert(namn.lowercased()).inserted else { return nil }
            let epost = d.url.scheme == "mailto"
                ? d.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                : nil
            return Deltagare(namn: namn, epost: epost, ärJag: Self.ärJag(d, namn: namn))
        }
        return Möte(
            id: e.eventIdentifier ?? UUID().uuidString,
            titel: e.title ?? "Möte",
            start: e.startDate,
            slut: e.endDate,
            deltagare: deltagare,
            plats: e.location?.isEmpty == false ? e.location : nil,
            möteslänk: Self.möteslänk(i: e))
    }

    /// `isCurrentUser` räcker inte: den känner bara igen en av användarens
    /// adresser, så samma person kan dyka upp som både sig själv och deltagare
    /// när inbjudan gått till en annan av adresserna.
    private static func ärJag(_ d: EKParticipant, namn: String) -> Bool {
        if d.isCurrentUser { return true }
        return namn.compare(NSFullUserName(), options: .caseInsensitive) == .orderedSame
    }

    /// Letar upp konferenslänken. Den ligger olika beroende på vem som bjudit in.
    private static func möteslänk(i e: EKEvent) -> URL? {
        if let url = e.url, ärMöteslänk(url) { return url }
        let text = [e.location, e.notes].compactMap { $0 }.joined(separator: "\n")
        guard let hittare = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let träffar = hittare.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return träffar.compactMap(\.url).first(where: ärMöteslänk)
    }

    private static func ärMöteslänk(_ url: URL) -> Bool {
        guard let värd = url.host?.lowercased() else { return false }
        return ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com",
                "whereby.com", "webex.com", "meet.jit.si", "daily.co"]
            .contains { värd.hasSuffix($0) }
    }

    /// "om 20 minuter", "i dag 14:00", "på torsdag" — närmare till hands än
    /// ett datum när allt som visas ligger framåt.
    nonisolated static func närText(_ start: Date) -> String {
        let kalender = Calendar.current
        let om = start.timeIntervalSinceNow
        if om < 3600 {
            return "om \(max(1, Int(om / 60))) minuter"
        }
        if kalender.isDateInToday(start) {
            return "i dag \(DateFormatter.timme.string(from: start))"
        }
        if kalender.isDateInTomorrow(start) {
            return "i morgon \(DateFormatter.timme.string(from: start))"
        }
        if om < 7 * 24 * 3600 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "sv_SE")
            f.dateFormat = "EEEE HH:mm"
            return f.string(from: start)
        }
        return DateFormatter.klocka.string(from: start)
    }

    /// Vilka möten hör till kunden?
    ///
    /// Ett möte räknas som kundens om någon deltagare finns bland kundens
    /// kontakter, om någon har kundens e-postdomän, eller om kundnamnet står
    /// i titeln. Domänmatchningen är det som fungerar bäst i praktiken —
    /// kalenderinbjudningar har nästan alltid med adresserna.
    static func hör(_ möte: Möte, till kund: Kund, kontakter: [Kontakt]) -> Bool {
        let adresser = kontakter.flatMap(\.epost).map { $0.lowercased() }
        for d in möte.deltagare where !d.ärJag {
            guard let e = d.epost?.lowercased() else { continue }
            if adresser.contains(e) { return true }
        }
        let kundensDomäner = domäner(hos: kontakter)
        if !kundensDomäner.isEmpty {
            for d in möte.deltagare where !d.ärJag {
                guard let e = d.epost?.lowercased(),
                      let domän = e.split(separator: "@").last.map(String.init) else { continue }
                if kundensDomäner.contains(domän) { return true }
            }
        }
        let titel = möte.titel.lowercased()
        let namn = kund.namn.lowercased()
        return titel.contains(namn)
    }

    /// Domäner som hör till kunden, med de vanliga e-postleverantörerna
    /// bortsorterade — annars skulle varje möte med en gmail-adress matcha.
    static func domäner(hos kontakter: [Kontakt]) -> Set<String> {
        let allmänna: Set = ["gmail.com", "hotmail.com", "outlook.com", "icloud.com",
                             "live.com", "me.com", "yahoo.com", "telia.com", "bredband.net"]
        var ut = Set<String>()
        for e in kontakter.flatMap(\.epost) {
            guard let d = e.lowercased().split(separator: "@").last.map(String.init),
                  !allmänna.contains(d) else { continue }
            ut.insert(d)
        }
        return ut
    }
}
