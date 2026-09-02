import Foundation

/// Kör en underprocess utan att låsa en tråd i väntan, med tidsgräns och
/// avbrott.
///
/// `waitUntilExit` inne i en async-funktion blockerar en av Swifts få
/// samarbetstrådar — i pyannotes fall i minuter — och ett hängt osascript
/// eller claude lämnade tidigare en snurra som aldrig tog slut. Här väntas
/// avslutet in med en continuation, rören töms på egna GCD-trådar så att ett
/// pratsamt program inte fyller sin buffert och stannar, och en tidsgräns
/// eller ett avbrutet Task avslutar processen.
enum Underprocess {

    struct Utfall {
        var kod: Int32
        var ut: Data
        var fel: Data
        var uttext: String { String(data: ut, encoding: .utf8) ?? "" }
        var feltext: String {
            (String(data: fel, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Slutet av felutskriften — det är där orsaken brukar stå.
        func felsvans(_ tecken: Int = 600) -> String {
            let t = feltext
            return t.count <= tecken ? t : "…" + String(t.suffix(tecken))
        }
    }

    enum Fel: LocalizedError {
        case tidsgräns(String, TimeInterval)
        var errorDescription: String? {
            switch self {
            case .tidsgräns(let namn, let s):
                "\(namn) svarade inte inom \(Int(s)) sekunder och avbröts."
            }
        }
    }

    /// Kör processen till slut och ger utdata, felutdata och avslutskod.
    /// - Parameter indata: skrivs till processens standard in, som sedan stängs.
    static func kör(_ p: Process, indata: Data? = nil,
                    tidsgräns: TimeInterval) async throws -> Utfall {
        let ut = Pipe(), fel = Pipe()
        p.standardOutput = ut
        p.standardError = fel
        let in_: Pipe? = indata == nil ? nil : Pipe()
        if let in_ { p.standardInput = in_ }

        // Rören läses från början, på egna trådar: annars kan ett program som
        // skriver mer än rörets buffert stanna i väntan på att någon läser.
        async let utData = läsAllt(ut.fileHandleForReading)
        async let felData = läsAllt(fel.fileHandleForReading)

        try await väntaIn(p, tidsgräns: tidsgräns) {
            guard let in_, let indata else { return }
            DispatchQueue.global(qos: .utility).async {
                in_.fileHandleForWriting.write(indata)
                try? in_.fileHandleForWriting.close()
            }
        }
        return Utfall(kod: p.terminationStatus, ut: await utData, fel: await felData)
    }

    /// Startar en färdigförberedd process och väntar in den.
    ///
    /// Går tidsgränsen ut avslutas processen och ett fel kastas. Avbryts
    /// det omgivande Task:et avslutas den också, och `CancellationError`
    /// kastas när den är borta.
    static func väntaIn(_ p: Process, namn: String? = nil, tidsgräns: TimeInterval,
                        efterStart: (() -> Void)? = nil) async throws {
        let namn = namn ?? p.executableURL?.lastPathComponent ?? "processen"
        let väktare = Väktare()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // Handtaget sätts före starten: en process som hinner avsluta
                // innan handtaget finns skulle annars aldrig väcka oss.
                p.terminationHandler = { _ in c.resume() }
                do {
                    try p.run()
                } catch {
                    p.terminationHandler = nil
                    c.resume(throwing: error)
                    return
                }
                efterStart?()
                väktare.starta(efter: tidsgräns) {
                    if p.isRunning { p.terminate() }
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        väktare.stoppa()
        if väktare.gickUt { throw Fel.tidsgräns(namn, tidsgräns) }
        try Task.checkCancellation()
    }

    /// Läser ett rör till slutet på en GCD-tråd, som inte tillhör Swifts
    /// samarbetspool.
    static func läsAllt(_ h: FileHandle) async -> Data {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async {
                c.resume(returning: h.readDataToEndOfFile())
            }
        }
    }

    /// Tidsgränsen: en väntande arbetsuppgift som antingen hinner gå eller
    /// avbokas.
    private final class Väktare: @unchecked Sendable {
        private let lås = NSLock()
        private var arbete: DispatchWorkItem?
        private var _gickUt = false

        var gickUt: Bool { lås.lock(); defer { lås.unlock() }; return _gickUt }

        func starta(efter sekunder: TimeInterval, _ handling: @escaping @Sendable () -> Void) {
            let a = DispatchWorkItem { [self] in
                lås.lock(); _gickUt = true; lås.unlock()
                handling()
            }
            lås.lock(); arbete = a; lås.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + sekunder, execute: a)
        }

        func stoppa() {
            lås.lock(); arbete?.cancel(); arbete = nil; lås.unlock()
        }
    }
}
