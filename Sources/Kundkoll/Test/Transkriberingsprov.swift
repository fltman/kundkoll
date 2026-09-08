import Foundation

/// Kör en riktig ljudfil genom en vald arkivmotor.
///
///     Kundkoll --prov-transkribering <fil.wav> [motor] [modell] [språk]
///
/// Motor: whisperCpp, mlx, openai eller elevenlabs. Utan motor provas den
/// som är vald i inställningarna. Molnmotorerna kostar och skickar ljudet
/// till tjänsten — precis som i drift. Språk: "sv", "no", "da", "en" eller
/// "auto" för «avgör själv»; utan språk provas svenska.
enum Transkriberingsprov {

    static func kör(fil: String, motor: String?, modell: String?,
                    språk: String? = "sv") async -> Int32 {
        let url = URL(fileURLWithPath: fil)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Hittar inte \(fil)"); return 1
        }

        var val = Transkriberingsval.läs()
        if let motor {
            guard let m = Transkriberingsmotor(rawValue: motor) else {
                print("Okänd motor «\(motor)». Välj bland: "
                      + Transkriberingsmotor.allCases.map(\.rawValue).joined(separator: ", "))
                return 1
            }
            val.motor = m
            val.modell = modell ?? ""
        }
        // Provet ska inte röra appens sparade inställning — men kör-vägen
        // läser den, så den sparas undan och läggs tillbaka.
        let sparad = Transkriberingsval.läs()
        val.spara()
        defer { sparad.spara() }

        print("Motor:  \(val.motor.namn)")
        print("Modell: \(val.arkivmodell)")
        print("Språk:  \(Mötesspråk.namn(språk))")
        if let brist = Arkivtranskribering.brister(val).first {
            print("Kan inte köra: \(brist)")
            return 1
        }

        let t0 = Date()
        let rader: [Yttrande]
        do {
            rader = try await Arkivtranskribering.kör(fil: url, röst: .motpart,
                                                      språk: språk) { f in
                if !f.senasteRad.isEmpty {
                    print(String(format: "  [%3.0f %%] %@", f.andel * 100, f.senasteRad))
                }
            }
        } catch {
            print("Gick inte: \(error.localizedDescription)")
            Prov.svit("Transkribering — \(val.motor.namn)")
            Prov.kolla(false, "motorn svarade")
            return Prov.sammanfatta()
        }
        let tid = Date().timeIntervalSince(t0)

        print("")
        for y in rader {
            print(String(format: "  %6.1f–%6.1f  %@", y.start, y.slut, y.text))
        }
        let ord = rader.map(\.text).joined(separator: " ")
            .split(separator: " ").count
        print(String(format: "\n%d rader, %d ord, %.1f s", rader.count, ord, tid))

        Prov.svit("Transkribering — \(val.motor.namn)")
        Prov.kolla(!rader.isEmpty, "ljudet gav text")
        Prov.kolla(rader.allSatisfy { $0.slut > $0.start }, "tiderna går framåt")
        Prov.kolla(zip(rader, rader.dropFirst()).allSatisfy { $0.0.start <= $0.1.start },
                   "raderna kommer i ordning")
        return Prov.sammanfatta()
    }
}
