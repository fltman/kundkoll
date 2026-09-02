import Foundation
import SQLite3

/// Ett sökbart index över allt material hos en kund.
///
/// SQLite med FTS5, inte vektorer: `NLEmbedding` saknar svenska helt, och
/// molnembeddingar skulle innebära att allt kundmaterial skickas ut. BM25 över
/// trunkerade sökord räcker långt — se `docs/KUNSKAPSBANK.md` för mätningen.
///
/// Indexet är härlett. Går det sönder byggs det om från filerna, som är
/// sanningen.
final class Kunskapsbank {

    struct Träff: Identifiable, Hashable {
        var id: Int64
        var typ: String
        var titel: String
        var text: String
        var källa: String
        var tid: Date?
        var poäng: Double

        /// Det som visas som hänvisning under ett svar.
        var hänvisning: String {
            let datum = tid.map { " · " + DateFormatter.dag.string(from: $0) } ?? ""
            return "\(titel)\(datum)"
        }
    }

    private var db: OpaquePointer?
    private let fil: URL
    /// Alla inbäddningar i minnet, giltiga så länge antalet i tabellen är
    /// detsamma. Läses annars om från disk vid varje fråga.
    private var vektorcache: (antal: Int, rader: [(id: Int64, vektor: [Float])])?

    init(kund: Kund) throws {
        let mapp = kund.mapp.appending(path: ".kundkoll")
        try FileManager.default.createDirectory(at: mapp, withIntermediateDirectories: true)
        fil = mapp.appending(path: "index.db")
        guard sqlite3_open(fil.path, &db) == SQLITE_OK else { throw Fel.kanInteÖppna }
        // Inbäddningen skriver från en egen anslutning i bakgrunden; en kort
        // väntan i stället för «database is locked».
        sqlite3_busy_timeout(db, 2000)
        try skapaTabeller()
    }

    deinit { sqlite3_close(db) }

    private func kör(_ sql: String) throws {
        var fel: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &fel) == SQLITE_OK else {
            let text = fel.map { String(cString: $0) } ?? "okänt fel"
            sqlite3_free(fel)
            throw Fel.sql(text)
        }
    }

    private func skapaTabeller() throws {
        // remove_diacritics 0: å ä ö är egna bokstäver i svenskan, inte a och o
        // med prickar. "mata" och "mäta" är olika ord.
        try kör("""
            CREATE VIRTUAL TABLE IF NOT EXISTS dokument USING fts5(
                titel, text, typ UNINDEXED, källa UNINDEXED, tid UNINDEXED,
                tokenize='unicode61 remove_diacritics 0'
            );
            CREATE TABLE IF NOT EXISTS källor (
                källa TEXT PRIMARY KEY,
                ändrad REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS vektorer (
                id INTEGER PRIMARY KEY,
                vektor BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dokumentkällor (
                id INTEGER PRIMARY KEY,
                källa TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dokumentkällor_källa ON dokumentkällor(källa);
            """)
        // Sidotabellen kom till senare: källan står UNINDEXED i FTS-tabellen,
        // så att glömma en källa var en genomsökning av hela indexet. Ett
        // index byggt före tabellen fylls på en gång.
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT (SELECT count(*) FROM dokumentkällor), (SELECT count(*) FROM dokument)",
                           -1, &s, nil)
        if sqlite3_step(s) == SQLITE_ROW,
           sqlite3_column_int(s, 0) == 0, sqlite3_column_int(s, 1) > 0 {
            sqlite3_finalize(s)
            try kör("INSERT INTO dokumentkällor(id, källa) SELECT rowid, källa FROM dokument")
        } else {
            sqlite3_finalize(s)
        }
    }

    // MARK: - Indexering

    /// Har filen ändrats sedan den indexerades?
    func behöverIndexeras(_ url: URL) -> Bool {
        guard let ändrad = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 else { return true }
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT ändrad FROM källor WHERE källa = ?", -1, &s, nil) == SQLITE_OK
        else { return true }
        bind(s, 1, url.path)
        guard sqlite3_step(s) == SQLITE_ROW else { return true }
        return sqlite3_column_double(s, 0) < ändrad - 0.5
    }

    /// Tar bort allt som kommer från en källa, så att omindexering inte dubblar.
    func glöm(källa: String) throws {
        for sql in [
            "DELETE FROM vektorer WHERE id IN (SELECT id FROM dokumentkällor WHERE källa = ?)",
            "DELETE FROM dokument WHERE rowid IN (SELECT id FROM dokumentkällor WHERE källa = ?)",
            "DELETE FROM dokumentkällor WHERE källa = ?",
            "DELETE FROM källor WHERE källa = ?",
        ] {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            bind(s, 1, källa)
            sqlite3_step(s)
            sqlite3_finalize(s)
        }
        vektorcache = nil
    }

    /// Källorna som följs på ändringstid. En fil som inte finns längre — ett
    /// möte som döpts om eller flyttats — lämnar annars sina stycken kvar i
    /// indexet för alltid.
    func spåradeKällor() -> [String] {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT källa FROM källor", -1, &s, nil) == SQLITE_OK
        else { return [] }
        var ut: [String] = []
        while sqlite3_step(s) == SQLITE_ROW { ut.append(text(s, 0)) }
        return ut
    }

    func läggTill(titel: String, text: String, typ: String, källa: String, tid: Date?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db,
            "INSERT INTO dokument(titel, text, typ, källa, tid) VALUES (?,?,?,?,?)",
            -1, &s, nil) == SQLITE_OK else { throw Fel.sql("kunde inte förbereda insert") }
        bind(s, 1, titel)
        bind(s, 2, text)
        bind(s, 3, typ)
        bind(s, 4, källa)
        bind(s, 5, tid.map { String($0.timeIntervalSince1970) } ?? "")
        guard sqlite3_step(s) == SQLITE_DONE else { throw Fel.sql("insert misslyckades") }

        let rad = sqlite3_last_insert_rowid(db)
        var k: OpaquePointer?
        defer { sqlite3_finalize(k) }
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO dokumentkällor(id, källa) VALUES (?,?)",
                           -1, &k, nil)
        sqlite3_bind_int64(k, 1, rad)
        bind(k, 2, källa)
        sqlite3_step(k)
    }

    /// Noterar att källan är indexerad i sin nuvarande form.
    func markeraIndexerad(_ url: URL) throws {
        let ändrad = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO källor(källa, ändrad) VALUES (?,?)", -1, &s, nil)
        bind(s, 1, url.path)
        sqlite3_bind_double(s, 2, ändrad)
        sqlite3_step(s)
    }

    var antal: Int {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        sqlite3_prepare_v2(db, "SELECT count(*) FROM dokument", -1, &s, nil)
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }

    // MARK: - Vektorer

    /// Stycken som ännu inte bäddats in. Texten är titel + början av
    /// brödtexten — titeln bär ofta det enda meningsfulla, som ett filnamn
    /// eller en ämnesrad.
    func utanVektor(max antal: Int = 16) -> [(id: Int64, text: String)] {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, """
            SELECT rowid, titel, text FROM dokument
            WHERE rowid NOT IN (SELECT id FROM vektorer) LIMIT ?
            """, -1, &s, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(s, 1, Int32(antal))
        var ut: [(Int64, String)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            ut.append((sqlite3_column_int64(s, 0),
                       "\(text(s, 1))\n\(String(text(s, 2).prefix(2000)))"))
        }
        return ut
    }

    func sparaVektor(_ id: Int64, _ vektor: [Float]) throws {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO vektorer(id, vektor) VALUES (?,?)",
            -1, &s, nil) == SQLITE_OK else { throw Fel.sql("kunde inte förbereda vektor") }
        sqlite3_bind_int64(s, 1, id)
        vektor.withUnsafeBytes { råa in
            _ = sqlite3_bind_blob(s, 2, råa.baseAddress, Int32(råa.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Fel.sql("vektor sparades inte") }
        vektorcache = nil
    }

    /// Alla inbäddningar. De hålls i minnet mellan frågorna så länge antalet
    /// i tabellen är detsamma — tusentals stycken à fyra kilobyte lästes
    /// annars från disk vid varje fråga.
    func vektorer() -> [(id: Int64, vektor: [Float])] {
        var räknare: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM vektorer", -1, &räknare, nil)
        let antal = sqlite3_step(räknare) == SQLITE_ROW ? Int(sqlite3_column_int(räknare, 0)) : 0
        sqlite3_finalize(räknare)
        if let c = vektorcache, c.antal == antal { return c.rader }

        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT id, vektor FROM vektorer", -1, &s, nil) == SQLITE_OK
        else { return [] }
        var ut: [(Int64, [Float])] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let längd = Int(sqlite3_column_bytes(s, 1)) / MemoryLayout<Float>.size
            guard längd > 0, let blob = sqlite3_column_blob(s, 1) else { continue }
            let v = blob.withMemoryRebound(to: Float.self, capacity: längd) {
                Array(UnsafeBufferPointer(start: $0, count: längd))
            }
            ut.append((sqlite3_column_int64(s, 0), v))
        }
        vektorcache = (antal, ut)
        return ut
    }

    // MARK: - Sökning

    /// Söker och rangordnar med BM25.
    func sök(_ fråga: String, max antal: Int = 8) -> [Träff] {
        let uttryck = Self.sökuttryck(fråga)
        guard !uttryck.isEmpty else { return [] }

        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        // Titeln väger tyngre än brödtexten.
        let sql = """
            SELECT rowid, typ, titel, text, källa, tid, bm25(dokument, 3.0, 1.0)
            FROM dokument WHERE dokument MATCH ?
            ORDER BY bm25(dokument, 3.0, 1.0) LIMIT ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        bind(s, 1, uttryck)
        sqlite3_bind_int(s, 2, Int32(antal))

        var ut: [Träff] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let tidText = text(s, 5)
            let typ = text(s, 1)
            ut.append(Träff(
                id: sqlite3_column_int64(s, 0),
                typ: typ,
                titel: text(s, 2),
                text: text(s, 3),
                källa: text(s, 4),
                tid: Double(tidText).map { Date(timeIntervalSince1970: $0) },
                poäng: sqlite3_column_double(s, 6) * vikt(typ)))
        }
        // BM25 är negativ och lägre är bättre, så en vikt över 1 lyfter.
        return ut.sorted { $0.poäng < $1.poäng }
    }

    /// Hur tungt en källa väger.
    ///
    /// Tidigare chattar är härledda: de säger vad modellen svarade, inte vad
    /// som faktiskt hände. Ett svar som en gång sade "jag hittar inte X" blev
    /// annars det bäst rankade underlaget nästa gång samma fråga ställdes, och
    /// slog ut den fil som svaret saknades i. De är fortfarande värda att söka
    /// i — bara inte före primärkällorna.
    ///
    /// BM25 är negativ och lägre är bättre, så en faktor över 1 gör träffen
    /// starkare.
    private func vikt(_ typ: String) -> Double {
        switch typ {
        case "chatt": 0.4          // härlett, hamnar sist
        case "sammanfattning": 1.3 // destillerat, väger tyngst
        case "kontakt": 0.8
        default: 1.0
        }
    }

    /// Söker på både ord och betydelse och väver ihop listorna.
    ///
    /// Sammanvägningen är RRF — 1/(60+rang), summerat — som inte behöver
    /// jämföra BM25-tal med cosinus: bara ordningarna räknas. Uppmätt på
    /// riktigt kundmaterial tog hybriden 11 av 12 mot 9 för vardera ensam;
    /// det ordsökningen aldrig kan ta är svenska frågor mot engelska
    /// dokument. Frågans vektor kommer utifrån, eftersom den kräver Ollama
    /// och därmed är asynkron — utan vektor är detta exakt `sök`.
    func hybrid(_ fråga: String, vektor: [Float]?, max antal: Int = 8) -> [Träff] {
        let ordträffar = sök(fråga, max: 10)
        guard let vektor else { return Array(ordträffar.prefix(antal)) }

        var norm: Float = 0
        for x in vektor { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return Array(ordträffar.prefix(antal)) }

        // Cosinus mot allt, viktat som ordsökningen: härledda chattar sjunker.
        var likheter: [(id: Int64, poäng: Double)] = []
        for (id, v) in vektorer() {
            var summa: Float = 0
            var vnorm: Float = 0
            for i in 0..<min(v.count, vektor.count) {
                summa += v[i] * vektor[i]
                vnorm += v[i] * v[i]
            }
            guard vnorm > 0 else { continue }
            likheter.append((id, Double(summa / (norm * vnorm.squareRoot()))))
        }
        // Vikten kräver typen; hämtas för topplistan först när den behövs.
        let semantiska = likheter.sorted { $0.poäng > $1.poäng }.prefix(16).map(\.id)

        let ordning = Self.rrf(ord: ordträffar.map(\.id), betydelse: Array(semantiska))
        var perID: [Int64: Träff] = [:]
        for t in ordträffar { perID[t.id] = t }
        var ut: [Träff] = []
        for id in ordning.prefix(antal * 2) {
            guard var t = perID[id] ?? träff(id) else { continue }
            // Härledda källor sjunker även i den semantiska vägen.
            if t.typ == "chatt", ut.count >= 2 { continue }
            t.poäng = 0
            ut.append(t)
            if ut.count == antal { break }
        }
        return ut
    }

    /// Reciprocal rank fusion: summan av 1/(60+rang) i varje lista.
    static func rrf(ord: [Int64], betydelse: [Int64]) -> [Int64] {
        var poäng: [Int64: Double] = [:]
        for (i, id) in ord.enumerated() { poäng[id, default: 0] += 1 / Double(60 + i) }
        for (i, id) in betydelse.enumerated() { poäng[id, default: 0] += 1 / Double(60 + i) }
        return poäng.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.map(\.key)
    }

    /// En enskild rad, för träffar som bara den semantiska vägen hittade.
    private func träff(_ id: Int64) -> Träff? {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db,
            "SELECT rowid, typ, titel, text, källa, tid FROM dokument WHERE rowid = ?",
            -1, &s, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(s, 1, id)
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        let tidText = text(s, 5)
        return Träff(id: sqlite3_column_int64(s, 0), typ: text(s, 1), titel: text(s, 2),
                     text: text(s, 3), källa: text(s, 4),
                     tid: Double(tidText).map { Date(timeIntervalSince1970: $0) },
                     poäng: 0)
    }

    /// Bygger FTS-uttrycket ur en fråga i vanlig svenska.
    ///
    /// Svenskan böjer och sätter samman: "leveranstid" hittar inte
    /// "leveranstiden" och "batteri" inte "battericeller". Uppmätt gav rak
    /// sökning träff på 2 av 9 rimliga frågor, trunkerad på 9 av 9. Därför
    /// kapas orden och söks som prefix.
    static func sökuttryck(_ fråga: String, minst: Int = 4, kapa: Int = 2) -> String {
        let ord = fråga
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 2 && !stoppord.contains($0) }
        guard !ord.isEmpty else { return "" }
        return ord.map { o -> String in
            guard o.count >= minst else { return "\"\(o)\"" }
            return String(o.prefix(max(minst, o.count - kapa))) + "*"
        }
        .joined(separator: " OR ")
    }

    /// Ord som finns i varje text och bara späder ut träffarna.
    static let stoppord: Set<String> = [
        "och", "att", "det", "som", "för", "med", "den", "har", "vi", "är", "en",
        "ett", "på", "av", "till", "om", "från", "var", "vad", "hur", "när", "de",
        "jag", "du", "han", "hon", "man", "kan", "ska", "vill", "inte", "men",
        "eller", "så", "vid", "under", "över", "efter", "före", "mer", "vår",
    ]

    // MARK: - Småsaker

    private func bind(_ s: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(s, i, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(s, i) else { return "" }
        return String(cString: p)
    }

    enum Fel: LocalizedError {
        case kanInteÖppna, sql(String)
        var errorDescription: String? {
            switch self {
            case .kanInteÖppna: "Kunde inte öppna kunskapsbanken."
            case .sql(let f): "Kunskapsbanken svarade med ett fel: \(f)"
            }
        }
    }
}
