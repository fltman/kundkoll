import Foundation
import Contacts

/// Läser och skriver macOS Kontakter.
///
/// Kundens kontaktlista bor i kundmappen och adressboken är i första hand en
/// källa att hämta från. Skrivning sker bara när användaren uttryckligen ber om
/// det för en enskild person — ingen synk i bakgrunden, eftersom adressboken är
/// användarens egen och delas med telefon och andra datorer.
@MainActor
final class Adressboken: ObservableObject {
    static let shared = Adressboken()

    private let butik = CNContactStore()

    @Published private(set) var behörighet: CNAuthorizationStatus =
        CNContactStore.authorizationStatus(for: .contacts)

    var harTillgång: Bool { behörighet == .authorized }

    private static let nycklar = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
        CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
        CNContactImageDataKey, CNContactThumbnailImageDataKey,
    ] as [CNKeyDescriptor]

    @discardableResult
    func begärTillgång() async -> Bool {
        let ok = (try? await butik.requestAccess(for: .contacts)) ?? false
        behörighet = CNContactStore.authorizationStatus(for: .contacts)
        return ok
    }

    /// Söker i adressboken. Tom sträng ger inget — hela adressboken är sällan
    /// vad man vill se.
    func sök(_ text: String) -> [Kontakt] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard harTillgång, !text.isEmpty else { return [] }
        let begäran = CNContactFetchRequest(keysToFetch: Self.nycklar)
        begäran.predicate = CNContact.predicateForContacts(matchingName: text)
        return hämta(begäran)
    }

    /// Alla i adressboken som hör till en organisation. Används när en kund
    /// läggs upp: oftast finns personerna redan.
    func hosOrganisation(_ namn: String) -> [Kontakt] {
        guard harTillgång else { return [] }
        let sökt = förenkla(namn)
        guard !sökt.isEmpty else { return [] }
        let begäran = CNContactFetchRequest(keysToFetch: Self.nycklar)
        return hämta(begäran).filter { kontakt in
            guard let systemID = kontakt.systemID,
                  let org = organisationer[systemID] else { return false }
            let o = förenkla(org)
            return !o.isEmpty && (o.contains(sökt) || sökt.contains(o))
        }
    }

    private var organisationer: [String: String] = [:]

    // MARK: - Skriva

    /// Lägger upp personen i macOS Kontakter och returnerar kontakten med
    /// identifieraren ifylld, så att den fortsättningsvis hör ihop med posten.
    func läggTillIAdressboken(_ kontakt: Kontakt, organisation: String?) throws -> Kontakt {
        guard harTillgång else { throw Fel.ingenTillgång }
        let ny = CNMutableContact()
        fyll(ny, ur: kontakt, organisation: organisation)

        let begäran = CNSaveRequest()
        begäran.add(ny, toContainerWithIdentifier: nil)
        try butik.execute(begäran)

        var ut = kontakt
        ut.systemID = ny.identifier
        return ut
    }

    /// Skriver tillbaka ändringar till en post som redan finns i adressboken.
    func uppdateraIAdressboken(_ kontakt: Kontakt, organisation: String?) throws {
        guard harTillgång else { throw Fel.ingenTillgång }
        guard let id = kontakt.systemID else { throw Fel.ingenPost }
        // Bara de nycklar vi faktiskt rör; CNSaveRequest kräver att posten
        // hämtats med varje fält som ändras.
        guard let befintlig = try? butik.unifiedContact(withIdentifier: id, keysToFetch: Self.nycklar),
              let ändringsbar = befintlig.mutableCopy() as? CNMutableContact else {
            throw Fel.ingenPost
        }
        fyll(ändringsbar, ur: kontakt, organisation: organisation)

        let begäran = CNSaveRequest()
        begäran.update(ändringsbar)
        try butik.execute(begäran)
    }

    /// Profilbilden ur macOS Kontakter, när posten har en.
    func bilddata(för kontakt: Kontakt) -> Data? {
        guard harTillgång, let id = kontakt.systemID,
              let post = try? butik.unifiedContact(withIdentifier: id,
                                                   keysToFetch: Self.nycklar)
        else { return nil }
        return post.imageData ?? post.thumbnailImageData
    }

    /// Finns posten kvar? En kontakt kan ha raderats i Kontakter sedan vi
    /// kopplade den.
    func finnsIAdressboken(_ kontakt: Kontakt) -> Bool {
        guard harTillgång, let id = kontakt.systemID else { return false }
        return (try? butik.unifiedContact(withIdentifier: id, keysToFetch: Self.nycklar)) != nil
    }

    private func fyll(_ post: CNMutableContact, ur kontakt: Kontakt, organisation: String?) {
        let delar = kontakt.namn.split(separator: " ", maxSplits: 1).map(String.init)
        post.givenName = delar.first ?? kontakt.namn
        post.familyName = delar.count > 1 ? delar[1] : ""
        if let org = organisation, post.organizationName.isEmpty { post.organizationName = org }
        if let roll = kontakt.roll { post.jobTitle = roll }
        post.emailAddresses = kontakt.epost.map {
            CNLabeledValue(label: CNLabelWork, value: $0 as NSString)
        }
        post.phoneNumbers = kontakt.telefon.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }
    }

    enum Fel: LocalizedError {
        case ingenTillgång, ingenPost
        var errorDescription: String? {
            switch self {
            case .ingenTillgång:
                "\(Appnamn.visat) har inte tillgång till Kontakter. Ge tillgång i Systeminställningar → Integritet och säkerhet → Kontakter."
            case .ingenPost:
                "Posten finns inte kvar i Kontakter. Den kan ha raderats."
            }
        }
    }

    // MARK: - Läsa

    private func hämta(_ begäran: CNContactFetchRequest) -> [Kontakt] {
        var ut: [Kontakt] = []
        try? butik.enumerateContacts(with: begäran) { c, _ in
            let namn = [c.givenName, c.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let visat = namn.isEmpty ? c.organizationName : namn
            guard !visat.isEmpty else { return }
            self.organisationer[c.identifier] = c.organizationName
            ut.append(Kontakt(
                namn: visat,
                roll: c.jobTitle.isEmpty ? nil : c.jobTitle,
                epost: c.emailAddresses.map { $0.value as String },
                telefon: c.phoneNumbers.map { $0.value.stringValue },
                systemID: c.identifier))
        }
        return ut.sorted { $0.namn.localizedStandardCompare($1.namn) == .orderedAscending }
    }

    /// Tar bort bolagsformer och skiftläge, så att "Acme AB" matchar "Acme".
    private func förenkla(_ s: String) -> String {
        var t = s.lowercased()
        for ord in [" ab", " aktiebolag", " hb", " kb", " ekonomisk förening",
                    " a/s", " as", " oy", " gmbh", " ltd", " inc", " llc"] {
            if t.hasSuffix(ord) { t = String(t.dropLast(ord.count)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
