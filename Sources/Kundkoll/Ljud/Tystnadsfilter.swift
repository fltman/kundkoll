import Foundation

/// Kastar rader som ligger i tystnad.
///
/// Whisper hittar på text ur tystnad — «Tack till elever och personal vid
/// Värmlande», «Textning av …» — och mest på det egna spåret, där man själv
/// är tyst större delen av mötet. Silero-VAD i whisper.cpp tar det mesta,
/// men MLX och molnen har ingen taldetektering alls, och dit går engelska
/// möten och «avgör själv». Det här är ett fjärde lager som gäller alla
/// motorer: varje rad mäts mot ljudet, och en rad vars tidsrymd inte
/// innehåller tal kan ingen ha sagt.
///
/// Måttet är livebuffringens: ett block om 20 ms är tal när det ligger fyra
/// gånger över rummets bakgrund, skattad som tionde percentilen av blocken
/// i en tjugosekundersbit. Relativt, inte en konstant — den inbyggda
/// mikrofonen ger tal på RMS 0,005 medan datorljud ligger tio till fyrtio
/// gånger högre.
enum Tystnadsfilter {

    /// Rensar raderna mot ljudfilen. En fil som inte går att läsa lämnar
    /// raderna orörda: filtret får aldrig kasta ett helt transkript.
    static func rensa(_ rader: [Yttrande], ljud fil: URL) -> [Yttrande] {
        guard !rader.isEmpty, let rms = blockRMS(i: fil) else { return rader }
        return rensa(rader, blockRMS: rms)
    }

    /// Rensar mot färdiga blockvärden. Utbruten för att kunna provas.
    ///
    /// - Parameter marginal: så mycket förlängs radens tidsrymd åt båda håll
    ///   innan den mäts — whispers tider kan ligga en bit fel.
    static func rensa(_ rader: [Yttrande], blockRMS rms: [Float],
                      marginal: Double = 0.3) -> [Yttrande] {
        guard !rms.isEmpty else { return rader }
        let tal = talblock(rms)
        let blockSekunder = Double(Ljudbuffring.blocklängd) / Ljudbuffring.målfrekvens
        return rader.filter { y in
            let från = max(0, Int((y.start - marginal) / blockSekunder))
            let till = min(tal.count, Int((y.slut + marginal) / blockSekunder) + 1)
            guard från < till else { return false }
            var antal = 0
            for i in från..<till where tal[i] { antal += 1 }
            let talSekunder = Double(antal) * blockSekunder
            // Lika strängt som live för långa rader; en kort rad behöver
            // bara en bråkdel av sin längd.
            let krav = min(Ljudbuffring.minstaTal, max(0.1, (y.slut - y.start) * 0.15))
            return talSekunder >= krav
        }
    }

    /// Vilka block som är tal, mätt mot bakgrunden i sin tjugosekundersbit.
    static func talblock(_ rms: [Float]) -> [Bool] {
        let perBit = max(1, Int(Ljudbuffring.golvfönster * Ljudbuffring.målfrekvens)
                         / Ljudbuffring.blocklängd)
        var ut = [Bool](repeating: false, count: rms.count)
        var i = 0
        while i < rms.count {
            let slut = min(rms.count, i + perBit)
            let sorterad = rms[i..<slut].sorted()
            let p = min(sorterad.count - 1, Int(Double(sorterad.count) * Ljudbuffring.golvpercentil))
            let golv = max(Ljudbuffring.lägstaGolv, sorterad[p])
            for k in i..<slut { ut[k] = rms[k] >= golv * Ljudbuffring.talfaktor }
            i = slut
        }
        return ut
    }

    /// RMS per 20 ms-block ur en 16 kHz mono 16-bitars WAV — formatet
    /// spårskrivaren skriver. Läses i bitar, så att en två timmar lång fil
    /// inte behöver ligga i minnet. Annat format ger nil.
    static func blockRMS(i fil: URL) -> [Float]? {
        guard let handtag = try? FileHandle(forReadingFrom: fil) else { return nil }
        defer { try? handtag.close() }
        guard let huvud = try? handtag.read(upToCount: Wav.huvudlängd), huvud.count == Wav.huvudlängd,
              huvud[0..<4] == Data("RIFF".utf8), huvud[36..<40] == Data("data".utf8) else { return nil }
        func u16(_ o: Int) -> UInt16 { huvud[o..<o+2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func u32(_ o: Int) -> UInt32 { huvud[o..<o+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard u16(20) == 1, u16(22) == 1, u16(34) == 16,
              Double(u32(24)) == Ljudbuffring.målfrekvens else { return nil }

        let block = Ljudbuffring.blocklängd
        var ut: [Float] = []
        var rest = Data()
        while let bit = try? handtag.read(upToCount: 1 << 20), !bit.isEmpty {
            rest.append(bit)
            let hela = rest.count / (block * 2) * (block * 2)
            rest.withUnsafeBytes { råa in
                let prov = råa.bindMemory(to: Int16.self)
                var i = 0
                while i + block <= hela / 2 {
                    var summa: Float = 0
                    for k in i..<(i + block) {
                        let v = Float(Int16(littleEndian: prov[k])) / 32767
                        summa += v * v
                    }
                    ut.append((summa / Float(block)).squareRoot())
                    i += block
                }
            }
            rest = Data(rest.suffix(rest.count - hela))
        }
        return ut
    }
}
