import Foundation
import AVFoundation

/// Tar in en färdig ljud- eller videofil och gör den till en inspelning.
///
/// Teams och Zoom sparar möten som mp4, telefonen som m4a, diktafonen som wav.
/// AVFoundation läser dem alla, så filen behöver bara räknas om till det format
/// whisper vill ha. Resten — transkribering, röster, sammanfattning — är samma
/// arkivpass som efter ett möte, se `Efterbearbetning`.
///
/// Till skillnad från en inspelning gjord i appen finns ingen kanaluppdelning
/// här — allt ligger i ett spår. Röstanalysen får i stället dela upp det, och
/// då kan en av rösterna vara du själv.
actor Import {

    struct Läge {
        var steg: String
        /// 0–1 när det går att veta, annars nil.
        var andel: Double?
        /// Det senaste transkriberade, så att man ser att det rör sig.
        var senaste: String?
    }

    /// Format vi tar emot. Listan är bred med flit: hellre försöka och
    /// misslyckas tydligt än att stänga ute en fil som hade fungerat.
    static let format = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac",
                         "mp4", "mov", "m4v", "mpeg", "mpg", "wma", "ogg", "opus", "webm"]

    /// Läser filen och skriver 16 kHz mono, formatet whisper och röstanalysen
    /// båda vill ha.
    static func tillWhisperformat(_ källa: URL, mål: URL) async throws -> Double {
        let tillgång = AVURLAsset(url: källa)
        let spår = try await tillgång.loadTracks(withMediaType: .audio)
        guard let ljudspår = spår.first else { throw Fel.ingetLjud }

        let läsare = try AVAssetReader(asset: tillgång)
        let inställningar: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Ljudbuffring.målfrekvens,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let utgång = AVAssetReaderTrackOutput(track: ljudspår, outputSettings: inställningar)
        guard läsare.canAdd(utgång) else { throw Fel.kanInteLäsa }
        läsare.add(utgång)
        guard läsare.startReading() else { throw Fel.kanInteLäsa }

        let skrivare = try Spårskrivare(fil: mål)
        var antal = 0
        var sedanKoll = 0
        while let buffert = utgång.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffert) else { continue }
            var längd = 0
            var pekare: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &längd,
                                              dataPointerOut: &pekare) == noErr,
                  let pekare else { continue }
            let prov = pekare.withMemoryRebound(to: Float.self, capacity: längd / 4) {
                Array(UnsafeBufferPointer(start: $0, count: längd / 4))
            }
            skrivare.skriv(prov)
            antal += prov.count
            sedanKoll += prov.count
            CMSampleBufferInvalidate(buffert)
            // Ett avbrott ska märkas även under en lång omräkning.
            if sedanKoll > 160_000 {
                sedanKoll = 0
                if Task.isCancelled {
                    läsare.cancelReading()
                    skrivare.stäng()
                    throw CancellationError()
                }
            }
        }
        skrivare.stäng()

        if läsare.status == .failed { throw läsare.error ?? Fel.kanInteLäsa }
        guard antal > 0 else { throw Fel.tomtLjud }
        return Double(antal) / Ljudbuffring.målfrekvens
    }

    /// Hela vägen: fil in, färdig inspelning ut.
    func importera(_ källa: URL,
                   placering: Placering,
                   titel: String,
                   kund: Kund?,
                   profiler: [Röstprofil],
                   väntadeRöster: Int? = nil,
                   språk: String? = "sv",
                   vidMapp: (@Sendable (URL) -> Void)? = nil,
                   vidLäge: @Sendable @escaping (Läge) -> Void) async throws -> (Inspelning, URL) {

        await MainActor.run { vidLäge(Läge(steg: "Läser \(källa.lastPathComponent) …", andel: nil)) }

        // Filens egen tid är närmare sanningen än "nu" för ett möte som spelats
        // in tidigare.
        let inledd = (try? källa.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()

        let mapp = try await MainActor.run {
            try Arkivet.shared.nyInspelningsmapp(placering: placering, titel: titel, datum: inledd)
        }
        // Kön behöver mappen så snart den finns. Utan det här ser den inte
        // att inspelningen är upptagen förrän importen är klar, och samma
        // mapp går att köa en gång till medan den skapas.
        vidMapp?(mapp)
        // Faller omräkningen finns inget att behålla. Faller transkriberingen
        // däremot — fel språk, saknad motor — ligger det omräknade ljudet
        // kvar med felet i möte.json, så att det går att köra om i stället
        // för att importera från början. Ett avbrott städar bort allt.
        var behåll = false
        defer {
            if !behåll { try? FileManager.default.removeItem(at: mapp) }
        }

        let wav = mapp.appending(path: "motpart.wav")
        let längd = try await Self.tillWhisperformat(källa, mål: wav)
        behåll = true

        let stomme = Inspelning(
            titel: titel, inledd: inledd, längd: längd,
            kund: placering.kundnamn,
            projekt: { if case .projekt(let p) = placering { p.namn } else { nil } }(),
            mikrofon: nil,
            liveYttranden: [],
            arkivYttranden: nil,
            kallade: [],
            enspårig: true,
            källfil: källa.lastPathComponent,
            språk: språk)

        let klar: Inspelning
        do {
            klar = try await Efterbearbetning.kör(stomme, mapp: mapp, profiler: profiler,
                                                 språk: språk, väntadeRöster: väntadeRöster) { l in
                vidLäge(Läge(steg: l.steg, andel: l.andel, senaste: l.senaste))
            }
        } catch is CancellationError {
            behåll = false
            throw CancellationError()
        }
        await MainActor.run { Notiser.mötetKlart(klar, mapp: mapp) }
        return (klar, mapp)
    }

    /// Gör klart en inspelning vars ljud finns men vars metadata saknas.
    ///
    /// Ljudet är redan i rätt format. Ligger jag.wav bredvid motpart.wav är
    /// det en inspelning gjord i appen, och båda spåren tas med — tidigare
    /// lästes bara motparten, och ens egen halva av mötet försvann.
    func slutför(mapp: URL,
                 placering: Placering,
                 profiler: [Röstprofil],
                 titel angiven: String? = nil,
                 språk: String? = "sv",
                 vidLäge: @Sendable @escaping (Läge) -> Void) async throws -> Inspelning {
        let fm = FileManager.default
        let jag = mapp.appending(path: "jag.wav")
        let motpart = mapp.appending(path: "motpart.wav")
        guard fm.fileExists(atPath: motpart.path) || fm.fileExists(atPath: jag.path) else {
            throw Fel.ingetLjud
        }
        let tvåspårig = fm.fileExists(atPath: jag.path) && fm.fileExists(atPath: motpart.path)
        for f in [jag, motpart] where fm.fileExists(atPath: f.path) {
            _ = try? Wav.rättaHuvud(i: f)
        }
        let ljudfil = fm.fileExists(atPath: motpart.path) ? motpart : jag
        let längd = [jag, motpart].filter { fm.fileExists(atPath: $0.path) }
            .map { Wav.längd(av: $0) }.max() ?? 0
        let inledd = (try? ljudfil.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()

        // Titeln står i mappnamnet: "2026-08-31 1548 magnus 1on1".
        let namn = mapp.lastPathComponent
        let urMapp = namn.split(separator: " ").dropFirst(2).joined(separator: " ")
        let titel = angiven ?? (urMapp.isEmpty ? namn : urMapp)

        let stomme = Inspelning(
            titel: titel,
            inledd: inledd, längd: längd,
            kund: placering.kundnamn,
            projekt: { if case .projekt(let p) = placering { p.namn } else { nil } }(),
            mikrofon: nil,
            liveYttranden: [],
            arkivYttranden: nil,
            kallade: [],
            enspårig: !tvåspårig,
            källfil: nil,
            språk: språk)

        let klar = try await Efterbearbetning.kör(stomme, mapp: mapp, profiler: profiler,
                                                 språk: språk) { l in
            vidLäge(Läge(steg: l.steg, andel: l.andel, senaste: l.senaste))
        }
        await MainActor.run { Notiser.mötetKlart(klar, mapp: mapp) }
        return klar
    }

    enum Fel: LocalizedError {
        case ingetLjud, kanInteLäsa, tomtLjud
        var errorDescription: String? {
            switch self {
            case .ingetLjud: "Filen innehåller inget ljudspår."
            case .kanInteLäsa: "Filformatet gick inte att läsa."
            case .tomtLjud: "Ljudspåret är tomt."
            }
        }
    }
}
