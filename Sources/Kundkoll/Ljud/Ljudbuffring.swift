import Foundation
import AVFoundation

/// Samlar inkommande ljud för ett spår och lämnar ifrån sig färdiga
/// talfönster åt transkriberingen.
///
/// Fönstret stängs vid en tystnad hellre än på fast tid, så att whisper får
/// hela meningar i stället för ord kapade på mitten. Efter `maxLängd` stängs
/// det ändå, annars skulle någon som talar oavbrutet aldrig ge ifrån sig text.
///
/// Vad som är tal avgörs mot rummets egen bakgrund, inte mot en fast nivå.
/// Skälet är uppmätt: den inbyggda mikrofonen i en MacBook Pro ger tal på
/// RMS 0,005–0,016 medan datorljudet från ett videosamtal ligger tio till
/// fyrtio gånger högre. En konstant som passar det ena spåret slänger allt
/// på det andra.
final class Ljudbuffring {

    /// Vad whisper vill ha: 16 kHz, mono, 16-bitars.
    static let målfrekvens: Double = 16_000

    /// Ljudet vägs i block om 20 ms. Fast blockstorlek gör mätningen
    /// oberoende av hur stora bitar ScreenCaptureKit råkar leverera.
    private static let block = 320

    /// Hur många gånger starkare än bakgrunden ett block måste vara för att
    /// räknas som tal. Måtten delas med `Tystnadsfilter`, som mäter
    /// arkivpassets rader mot samma ljud.
    static let talfaktor: Float = 4
    /// Lägsta bakgrund som skattningen får landa på. Utan den skulle digital
    /// tystnad (bakgrund 0) göra minsta knäpp till tal.
    static let lägstaGolv: Float = 0.0005
    /// Så mycket tal måste ett fönster innehålla för att vara värt att skicka.
    /// Utan den här spärren får whisper rena tystnadsfönster och hittar på
    /// text — uppmätt blir fem sekunder tystnad "Tack."
    static let minstaTal: Double = 0.25
    /// Bakgrunden skattas som en låg percentil av de senaste sekunderna.
    /// Percentilen ligger lågt för att pauserna mellan orden, inte orden,
    /// ska bestämma nivån.
    static let golvfönster: Double = 20
    static let golvpercentil = 0.10
    /// Blocket som ljudet vägs i.
    static var blocklängd: Int { block }

    private let tystnadslängd: Double = 0.6       // s tystnad som stänger fönstret
    private let minLängd: Double = 1.2            // kortare fönster är inte värt att skicka
    private let maxLängd: Double = 15.0

    /// Fönstrets ljud.
    private var prov: [Float] = []
    /// Ljud som ännu inte fyllt ett helt block.
    private var väntande: [Float] = []
    /// RMS per block, de senaste `golvfönster` sekunderna.
    private var historik: [Float] = []

    private var nolltid: Double?
    /// Prov som har matats in respektive vägts, sedan strömmens början.
    private var matadeProv = 0
    private var vägdaProv = 0
    private var fönsterStartProv: Int?
    /// Prov i fönstret som klassats som tal.
    private var talProv = 0
    /// Där den pågående tystnaden började, som provindex.
    private var tystSedanProv: Int?

    private var konverterare: AVAudioConverter?
    private var källformat: AVAudioFormat?

    struct Fönster {
        let prov: [Float]
        let start: Double
        let slut: Double
    }

    /// Matar in en ljudbit. Ger tillbaka ljudet i 16 kHz mono — det som
    /// skrivs till arkivfilen — och ett fönster när det är dags att
    /// transkribera.
    func mata(_ ram: Ljudram) -> (mono: [Float], fönster: Fönster?) {
        guard let mono = tillMono16k(ram.buffert) else { return ([], nil) }
        if nolltid == nil { nolltid = ram.tid }
        if fönsterStartProv == nil { fönsterStartProv = matadeProv }

        prov.append(contentsOf: mono)
        matadeProv += mono.count
        väg(mono)

        let längd = Double(prov.count) / Self.målfrekvens
        let tystNog = tystSedanProv.map {
            Double(vägdaProv - $0) / Self.målfrekvens >= tystnadslängd
        } ?? false
        guard (tystNog && längd >= minLängd) || längd >= maxLängd else { return (mono, nil) }

        return (mono, stäng())
    }

    /// Glömmer allt och börjar om från noll.
    ///
    /// Buffringen lever lika länge som inspelningssessionen, alltså hela
    /// appstarten, medan tiderna räknas ur `matadeProv` — antalet prov sedan
    /// strömmens början. Utan den här nollställningen fortsatte räkningen
    /// mellan möten: uppmätt fick ett möte som spelades in efter ett annat
    /// på 1782 sekunder alla sina livetider 1782 sekunder för sent, bortom
    /// slutet på sitt eget ljud, och varje klick i livetranskriptet hamnade
    /// på fel ställe.
    func nollställ() {
        prov.removeAll()
        väntande.removeAll()
        historik.removeAll()
        nolltid = nil
        matadeProv = 0
        vägdaProv = 0
        fönsterStartProv = nil
        talProv = 0
        tystSedanProv = nil
        senasteNivå = 0
        konverterare = nil
        källformat = nil
    }

    /// Stänger det som ligger kvar när inspelningen slutar.
    func spola() -> Fönster? {
        guard Double(prov.count) / Self.målfrekvens >= 0.4 else {
            prov.removeAll(); fönsterStartProv = nil; talProv = 0; return nil
        }
        väg(väntande, sista: true)
        return stäng()
    }

    private func stäng() -> Fönster? {
        defer {
            prov.removeAll(keepingCapacity: true)
            fönsterStartProv = nil
            talProv = 0
            tystSedanProv = nil
        }
        guard let start = fönsterStartProv, !prov.isEmpty else { return nil }
        // Ett fönster utan tal är just det whisper hittar på text ur.
        guard Double(talProv) / Self.målfrekvens >= Self.minstaTal else { return nil }
        return Fönster(prov: prov, start: tid(start), slut: tid(start + prov.count))
    }

    private func tid(_ provindex: Int) -> Double {
        (nolltid ?? 0) + Double(provindex) / Self.målfrekvens
    }

    // MARK: - Tal eller inte

    /// Väger ljudet block för block och håller reda på hur mycket av det som
    /// är tal. `sista` tar med ett ofullständigt block när strömmen tar slut.
    private func väg(_ nytt: [Float], sista: Bool = false) {
        väntande.append(contentsOf: nytt)
        while väntande.count >= Self.block || (sista && !väntande.isEmpty) {
            let antal = min(Self.block, väntande.count)
            let block = Array(väntande.prefix(antal))
            väntande.removeFirst(antal)

            let nivå = rms(block)
            // Mätaren faller långsammare än den stiger, annars
            // blinkar den i stavelsetakt i stället för att visa en nivå.
            senasteNivå = max(mätarnivå(nivå), senasteNivå * 0.93)
            historik.append(nivå)
            let maxHistorik = Int(Self.golvfönster * Self.målfrekvens) / Self.block
            if historik.count > maxHistorik { historik.removeFirst() }

            vägdaProv += antal
            if nivå >= golv() * Self.talfaktor {
                talProv += antal
                tystSedanProv = nil
            } else if tystSedanProv == nil {
                tystSedanProv = vägdaProv - antal
            }
            if sista && väntande.isEmpty { break }
        }
    }

    /// Rummets egen bakgrund, skattad ur de senaste sekunderna. Med kort
    /// historik faller percentilen tillbaka på det tystaste blocket, vilket
    /// är precis vad man vill vid start: ett brusigt rum känns igen direkt,
    /// och en inspelning som börjar mitt i en mening hittar sitt golv i
    /// första pausen mellan orden.
    private func golv() -> Float {
        guard !historik.isEmpty else { return Self.lägstaGolv }
        let sorterad = historik.sorted()
        let i = min(sorterad.count - 1, Int(Double(sorterad.count) * Self.golvpercentil))
        return max(Self.lägstaGolv, sorterad[i])
    }

    /// Aktuell ljudnivå 0–1, för mätaren i gränssnittet.
    private(set) var senasteNivå: Float = 0

    /// Mätaren är logaritmisk. Linjärt skulle tal från den inbyggda
    /// mikrofonen — RMS omkring 0,01 — knappt synas alls.
    private func mätarnivå(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)                 // −∞ … 0
        return min(1, max(0, (db + 60) / 50))    // −60 dB … −10 dB
    }

    private func rms(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let summa = v.reduce(Float(0)) { $0 + $1 * $1 }
        return (summa / Float(v.count)).squareRoot()
    }

    /// Blandar ned till mono och räknar om till 16 kHz.
    private func tillMono16k(_ buffert: AVAudioPCMBuffer) -> [Float]? {
        let in_ = buffert.format
        if konverterare == nil || källformat != in_ {
            guard let ut = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.målfrekvens,
                                         channels: 1,
                                         interleaved: false),
                  let k = AVAudioConverter(from: in_, to: ut) else { return nil }
            konverterare = k
            källformat = in_
        }
        guard let k = konverterare else { return nil }

        let kvot = Self.målfrekvens / in_.sampleRate
        let kapacitet = AVAudioFrameCount(Double(buffert.frameLength) * kvot) + 1024
        guard let ut = AVAudioPCMBuffer(pcmFormat: k.outputFormat, frameCapacity: kapacitet) else { return nil }

        var fel: NSError?
        var levererad = false
        k.convert(to: ut, error: &fel) { _, status in
            if levererad { status.pointee = .noDataNow; return nil }
            levererad = true
            status.pointee = .haveData
            return buffert
        }
        if fel != nil { return nil }
        guard let kanal = ut.floatChannelData?[0], ut.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: kanal, count: Int(ut.frameLength)))
    }
}

// MARK: - WAV

enum Wav {
    /// Bygger en 16 kHz mono 16-bitars WAV i minnet, formatet whisper vill ha.
    static func data(av prov: [Float], frekvens: Double = Ljudbuffring.målfrekvens) -> Data {
        var d = Data()
        let byteTakt = UInt32(frekvens) * 2
        func skriv<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append("RIFF".data(using: .ascii)!)
        skriv(UInt32(36 + prov.count * 2))
        d.append("WAVEfmt ".data(using: .ascii)!)
        skriv(UInt32(16))            // fmt-chunkens längd
        skriv(UInt16(1))             // PCM
        skriv(UInt16(1))             // mono
        skriv(UInt32(frekvens))
        skriv(byteTakt)
        skriv(UInt16(2))             // blockjustering
        skriv(UInt16(16))            // bitar per prov
        d.append("data".data(using: .ascii)!)
        skriv(UInt32(prov.count * 2))
        for p in prov { skriv(Int16(max(-1, min(1, p)) * 32767)) }
        return d
    }

    /// Huvudet som `data(av:)` skriver är 44 byte: RIFF-längden står på
    /// plats 4 och datalängden på plats 40.
    static let huvudlängd = 44

    /// Ljudets längd i sekunder, räknat ur filens storlek. Huvudet får inte
    /// avgöra: en fil som lämnades med längden noll bär ändå sitt ljud.
    static func längd(av fil: URL, frekvens: Double = Ljudbuffring.målfrekvens) -> Double {
        guard let storlek = try? FileManager.default
            .attributesOfItem(atPath: fil.path)[.size] as? Int else { return 0 }
        return Double(max(0, storlek - huvudlängd)) / (frekvens * 2)
    }

    /// Ett stycke ur ljudet som flyttalsprov: från `från` sekunder och
    /// `sekunder` framåt. Tom lista om filen inte går att läsa eller stycket
    /// ligger bortom slutet.
    static func prov(ur fil: URL, från: Double, sekunder: Double,
                     frekvens: Double = Ljudbuffring.målfrekvens) -> [Float] {
        guard let handtag = try? FileHandle(forReadingFrom: fil) else { return [] }
        defer { try? handtag.close() }
        let start = UInt64(huvudlängd) + UInt64(max(0, från) * frekvens) * 2
        guard (try? handtag.seek(toOffset: start)) != nil,
              let data = try? handtag.read(upToCount: Int(max(0, sekunder) * frekvens) * 2),
              data.count >= 2
        else { return [] }
        return data.withUnsafeBytes { råa in
            råa.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
        }
    }

    /// Rättar längderna i huvudet så att de stämmer med filens storlek.
    ///
    /// Spårskrivaren fyller i längderna först när den stänger filen. Kraschar
    /// appen, eller stängs den mitt i ett möte, står det noll — och då läser
    /// whisper, AVAudioFile och spelaren filen som tom fast ljudet ligger
    /// där. Ger sant om något behövde rättas.
    @discardableResult
    static func rättaHuvud(i fil: URL) throws -> Bool {
        let handtag = try FileHandle(forUpdating: fil)
        defer { try? handtag.close() }
        let storlek = Int(try handtag.seekToEnd())
        guard storlek >= huvudlängd else { return false }
        try handtag.seek(toOffset: 0)
        guard let huvud = try handtag.read(upToCount: huvudlängd), huvud.count == huvudlängd,
              huvud[0..<4] == Data("RIFF".utf8), huvud[8..<12] == Data("WAVE".utf8),
              huvud[36..<40] == Data("data".utf8) else { return false }
        let data = UInt32(storlek - huvudlängd)
        let riff = UInt32(storlek - 8)
        let harData = huvud[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let harRiff = huvud[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard harData != data || harRiff != riff else { return false }
        func skriv(_ v: UInt32, vid offset: UInt64) throws {
            try handtag.seek(toOffset: offset)
            var le = v.littleEndian
            try handtag.write(contentsOf: Data(bytes: &le, count: 4))
        }
        try skriv(riff, vid: 4)
        try skriv(data, vid: 40)
        return true
    }
}
