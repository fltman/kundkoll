import Foundation
import Combine

/// Följer ett pågående samtal och slår upp det deltagarna undrar över.
///
/// Kedjan är densamma som i chatten, med ett steg före: en lokal modell
/// avgör om det som just sagts innehåller något att slå upp. Först då går
/// frågan vidare till kunskapsbanken och därifrån till chattens modell.
///
/// Ordningen spelar roll för integriteten. Allt som sägs granskas lokalt;
/// bara de frågeställningar som faktiskt hittas lämnar datorn — och bara om
/// chatten är inställd på en molnmodell.
@MainActor
final class Liveinsikter: ObservableObject {

    struct Insikt: Identifiable {
        let id = UUID()
        var fråga: String
        /// Vad som sades och ledde fram till frågan.
        var utdrag: String
        var svar: String?
        var hänvisningar: [Chatt.Hänvisning] = []
        var fel: String?
        var tid = Date()
        var väntar: Bool { svar == nil && fel == nil }
    }

    @Published private(set) var insikter: [Insikt] = []
    @Published private(set) var lyssnar = false
    @Published private(set) var granskar = false
    @Published var på = Inställningar.insikterPå {
        didSet { Inställningar.insikterPå = på }
    }
    /// Sätts när den lokala modellen inte går att nå.
    @Published private(set) var varning: String?

    private let insiktsmodell = Insikter()
    private let chatt = Chatt()
    private var bank: Kunskapsbank?
    private var kund: Kund?
    private var projekt: Projekt?

    /// Yttranden som ännu inte granskats.
    private var obehandlade: [Yttrande] = []
    private var jobb: Task<Void, Never>?
    private var väckare: Timer?

    /// Så mycket text ska ha samlats innan det är värt att granska. Ett par
    /// meningar räcker sällan för att avgöra om något behöver slås upp.
    static let minstaText = 180
    /// Och så länge väntar vi som mest, så att ett långsamt samtal ändå får
    /// sina insikter.
    static let längstVäntan: TimeInterval = 25

    /// Är det samlade värt att skicka till den lokala modellen?
    static func dagsAttGranska(tecken: Int, väntat: TimeInterval) -> Bool {
        tecken > 0 && (tecken >= minstaText || väntat >= längstVäntan)
    }

    /// När den äldsta ogranskade raden kom. Väntetiden räknas därifrån, inte
    /// från förra granskningen: annars skulle en enda mening efter en lång
    /// paus granskas direkt, och en mening räcker sällan.
    private var samladeSedan = Date()

    func börja(kund: Kund, projekt: Projekt?) {
        self.kund = kund
        self.projekt = projekt
        insikter = []
        obehandlade = []
        samladeSedan = Date()
        lyssnar = true
        varning = nil
        väckare?.invalidate()
        väckare = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pröva() }
        }

        // Indexet byggs i bakgrunden: mötet har just börjat, och huvudtråden
        // ska rita livetranskriptet, inte läsa gamla möten.
        let arkiv = Arkivet.shared
        Task.detached(priority: .utility) { [weak self] in
            guard let b = try? Kunskapsbank(kund: kund) else { return }
            _ = try? Indexering.kör(för: kund, bank: b, arkiv: arkiv)
            await MainActor.run { self?.bank = b }
        }
        Task {
            if await !insiktsmodell.tillgänglig {
                varning = "Når ingen lokal modell. Starta Ollama för att få insikter under samtalet."
            }
        }
    }

    func sluta() {
        lyssnar = false
        väckare?.invalidate()
        väckare = nil
        jobb?.cancel()
        jobb = nil
    }

    /// Matas med varje ny rad ur transkriptet.
    func tog(_ yttrande: Yttrande) {
        guard lyssnar, på else { return }
        if obehandlade.isEmpty { samladeSedan = Date() }
        obehandlade.append(yttrande)
        pröva()
    }

    /// Avgör om det samlade är värt att granska.
    ///
    /// Anropas både när en ny rad kommer och med jämna mellanrum. Utan det
    /// senare vore väntetiden bara ett löfte: i ett samtal med pauser dyker
    /// nästa rad upp långt efter att den har gått ut, och då granskas det
    /// som sades först när någon råkar säga något mer.
    func pröva() {
        guard lyssnar, på, !obehandlade.isEmpty, jobb == nil else { return }
        let text = obehandlade.map(\.text).joined(separator: " ")
        guard Self.dagsAttGranska(tecken: text.count,
                                  väntat: Date().timeIntervalSince(samladeSedan)) else { return }
        obehandlade = []
        granska(text)
    }

    private func granska(_ stycke: String) {
        jobb = Task { [weak self] in
            defer { Task { @MainActor in self?.jobb = nil } }
            guard let self else { return }
            granskar = true
            defer { granskar = false }

            guard let fråga = try? await insiktsmodell.granska(stycke), !fråga.isEmpty else { return }
            // Samma sak frågas ofta två gånger i ett samtal.
            guard !insikter.contains(where: { likartade($0.fråga, fråga) }) else { return }

            let insikt = Insikt(fråga: fråga, utdrag: String(stycke.suffix(200)))
            insikter.append(insikt)
            await svara(på: insikt.id, fråga: fråga)
        }
    }

    private func svara(på id: UUID, fråga: String) async {
        guard let kund, let bank else { return }
        let träffar = await bank.bästaSök(projekt.map { "\(fråga) \($0.namn)" } ?? fråga)
        do {
            let svar = try await chatt.fråga(fråga, om: kund.namn, projekt: projekt?.namn,
                                             träffar: träffar, historik: [])
            uppdatera(id) {
                $0.svar = svar.text
                $0.hänvisningar = svar.hänvisningar
            }
        } catch {
            uppdatera(id) { $0.fel = error.localizedDescription }
        }
    }

    private func uppdatera(_ id: UUID, _ ändra: (inout Insikt) -> Void) {
        guard let i = insikter.firstIndex(where: { $0.id == id }) else { return }
        ändra(&insikter[i])
    }

    /// Två frågor räknas som samma om de delar de flesta orden. Nog för att
    /// slippa se samma sak två gånger under ett möte.
    /// Orden kapas innan de jämförs, av samma skäl som i `Uppgift.liknar`:
    /// svenskan böjer, och samma fråga ställd två gånger formuleras sällan
    /// exakt lika.
    private func likartade(_ a: String, _ b: String) -> Bool {
        let x = Uppgift.stammar(a), y = Uppgift.stammar(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) > 0.6
    }
}
