import Foundation

/// Arkivpasset efter ett möte: den stora modellen på varje spår,
/// röstuppdelning och sammanfattning.
///
/// Samlat på ett ställe därför att fyra vägar behöver exakt samma sak:
/// direkt efter en inspelning, en importerad fil, en omkörning från
/// mötesvyn, och en bearbetning som avbröts när appen stängdes. Varje steg
/// sparas till disk så snart det är klart, och `bearbetas` i möte.json
/// säger om passet blev avbrutet — då erbjuds en omkörning i listan i
/// stället för att mötet står som «live» för alltid.
enum Efterbearbetning {

    enum Fas { case transkriberar, röster, sammanfattar }

    struct Läge: Sendable {
        var fas: Fas
        var steg: String
        /// 0–1 när det går att veta.
        var andel: Double?
        /// Det senast transkriberade, så att man ser att det rör sig.
        var senaste: String?
    }

    enum Fel: LocalizedError {
        case ingetLjud, ingetTal, spårFöll(String, String)
        var errorDescription: String? {
            switch self {
            case .ingetLjud: "Det finns inget ljud att bearbeta i mappen."
            case .ingetTal: "Hittade inget tal i inspelningen. Prova ett annat språk eller en annan motor."
            case .spårFöll(let spår, let orsak): "Spåret \(spår) gick inte att transkribera: \(orsak)"
            }
        }
    }

    /// Kör hela passet på en inspelning vars ljud ligger i `mapp`.
    ///
    /// Faller ett spår behålls det som fanns: ett arkivtranskript med bara
    /// ena parten vore en försämring förklädd till förbättring. Felet skrivs
    /// i möte.json så att det syns i listan, och kastas vidare.
    ///
    /// - Parameter språk: "sv", "en" eller nil för att låta motorn avgöra.
    /// - Parameter väntadeRöster: antal talare när det är känt; annars de
    ///   kallade ur kalendern, om några.
    static func kör(_ ursprunglig: Inspelning, mapp: URL, profiler: [Röstprofil],
                    språk: String?, väntadeRöster: Int? = nil,
                    vidLäge: @Sendable @escaping (Läge) -> Void) async throws -> Inspelning {
        let fm = FileManager.default
        let jag = mapp.appending(path: "jag.wav")
        let motpart = mapp.appending(path: "motpart.wav")
        var spår: [(Röst, URL)] = []
        if fm.fileExists(atPath: jag.path) { spår.append((.jag, jag)) }
        if fm.fileExists(atPath: motpart.path) { spår.append((.motpart, motpart)) }
        guard !spår.isEmpty else { throw Fel.ingetLjud }
        // En krasch mitt i en inspelning lämnar wav-huvudet med längden noll.
        for (_, url) in spår { _ = try? Wav.rättaHuvud(i: url) }

        var i = ursprunglig
        i.bearbetas = true
        i.arkivfel = nil
        i.sammanfattningsfel = nil
        i.språk = språk
        try await spara(i, i: mapp)

        do {
            var rader: [Yttrande] = []
            let längd = i.längd > 0 ? i.längd : spår.map { Wav.längd(av: $0.1) }.max() ?? 0
            for (n, (röst, url)) in spår.enumerated() {
                let bas = Double(n) / Double(spår.count)
                let del = 1.0 / Double(spår.count)
                let steg = "Transkriberar \(formateraLängd(längd))"
                vidLäge(Läge(fas: .transkriberar, steg: steg, andel: bas))
                do {
                    rader += try await Arkivtranskribering.kör(
                        fil: url, röst: röst, språk: i.språk ?? "sv", totalLängd: längd,
                        vidFramsteg: { f in
                            vidLäge(Läge(fas: .transkriberar, steg: steg,
                                         andel: bas + f.andel * del, senaste: f.senasteRad))
                        })
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Fel.spårFöll(url.lastPathComponent, error.localizedDescription)
                }
            }
            guard !rader.isEmpty else { throw Fel.ingetTal }
            rader.sort { $0.start < $1.start }
            i.arkivYttranden = rader
            i.längd = max(i.längd, längd)
            try await spara(i, i: mapp)

            vidLäge(Läge(fas: .röster, steg: "Delar upp rösterna", andel: nil))
            let uppdelning = await Röstanalys().delaUpp(
                fil: motpart, yttranden: rader,
                antal: väntadeRöster ?? (i.kallade.isEmpty ? nil : i.kallade.count),
                profiler: profiler,
                vidLäge: { steg in vidLäge(Läge(fas: .röster, steg: steg, andel: nil)) })
            try Task.checkCancellation()
            i.arkivYttranden = uppdelning.yttranden
            i.röstnamn = uppdelning.namn
            i.röstmetod = uppdelning.metod
            i.röstvarning = uppdelning.varning
            try await spara(i, i: mapp)
        } catch {
            i.bearbetas = false
            i.arkivfel = error is CancellationError ? "Avbrutet." : error.localizedDescription
            try? await spara(i, i: mapp)
            throw error
        }

        // Sammanfattningen är det man vill ha ur mötet, men den kräver en
        // modell och får inte fälla passet — transkriptet är redan i hamn.
        // Utan automatiska modellanrop väntar den på knappen i mötesvyn.
        if Inställningar.automatiskaModellanrop, Modellval.läs().färdig {
            vidLäge(Läge(fas: .sammanfattar, steg: "Sammanfattar mötet", andel: nil))
            do {
                i.sammanfattning = try await Sammanfattare().skriv(för: i, kund: i.kund)
            } catch {
                i.sammanfattningsfel = error.localizedDescription
            }
        } else if !Modellval.läs().färdig {
            i.sammanfattningsfel = "Ingen modell är färdigställd för chatten. Välj en under ⌘, "
                + "och tryck sedan «Sammanfatta mötet»."
        }
        i.bearbetas = false
        let klar = i
        try await MainActor.run {
            try Arkivet.shared.spara(klar, i: mapp)
            if let s = klar.sammanfattning {
                Uppgiftssamling.frånMöte(s, inspelning: klar, mapp: mapp)
            }
        }
        return klar
    }

    @MainActor
    private static func spara(_ i: Inspelning, i mapp: URL) throws {
        try Arkivet.shared.spara(i, i: mapp)
    }
}
