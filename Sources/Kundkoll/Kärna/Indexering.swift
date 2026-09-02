import Foundation

/// Går igenom en kunds material och fyller kunskapsbanken.
///
/// Bara det som ändrats sedan sist indexeras om, så att en kund med hundratals
/// timmar transkript inte behöver läsas från början varje gång chatten öppnas.
///
/// Inte bunden till huvudaktören: arkivets läsningar är rena filläsningar,
/// och det här körs i bakgrunden. Bundet dit låg hela indexbygget — alla
/// möte.json med sina transkript — på huvudtråden när chatten öppnades, när
/// en kund visades och i samma ögonblick en inspelning startade.
enum Indexering {

    /// Ungefär så här långa stycken blir transkriptet. Kort nog att en träff
    /// pekar på rätt ställe i samtalet, långt nog att svaret får sammanhang.
    static let styckestorlek = 900

    struct Resultat {
        var indexerade = 0
        var stycken = 0
        var oförändrade = 0
    }

    @discardableResult
    static func kör(för kund: Kund, bank: Kunskapsbank, arkiv: Arkivet) throws -> Resultat {
        var r = Resultat()

        // Källor vars filer inte finns längre — ett möte som döpts om eller
        // flyttats — lämnade annars sina stycken kvar i indexet för alltid.
        for källa in bank.spåradeKällor() where !FileManager.default.fileExists(atPath: källa) {
            try bank.glöm(källa: källa)
        }

        // Transkript
        for (inspelning, mapp) in arkiv.inspelningar(för: kund) {
            let json = mapp.appending(path: "möte.json")
            guard bank.behöverIndexeras(json) else { r.oförändrade += 1; continue }
            try bank.glöm(källa: json.path)
            // Sammanfattningen först: den är det tätaste som finns om mötet.
            if let sam = inspelning.sammanfattning, !sam.tom {
                var text = sam.kärna
                if !sam.beslut.isEmpty {
                    text += "\n\nBeslut: " + sam.beslut.joined(separator: ". ")
                }
                if !sam.åtaganden.isEmpty {
                    text += "\n\nAtt göra: " + sam.åtaganden.map {
                        [$0.vem, $0.vad, $0.när].compactMap { $0 }.joined(separator: " ")
                    }.joined(separator: ". ")
                }
                if !sam.öppet.isEmpty {
                    text += "\n\nÖppna frågor: " + sam.öppet.joined(separator: ". ")
                }
                try bank.läggTill(titel: "\(inspelning.titel) — sammanfattning",
                                  text: text, typ: "sammanfattning",
                                  källa: json.path, tid: inspelning.inledd)
                r.stycken += 1
            }

            for (i, stycke) in stycken(av: inspelning).enumerated() {
                try bank.läggTill(
                    titel: "\(inspelning.titel) (\(i + 1))",
                    text: stycke,
                    typ: "transkript",
                    källa: json.path,
                    tid: inspelning.inledd)
                r.stycken += 1
            }
            try bank.markeraIndexerad(json)
            r.indexerade += 1
        }

        // Anteckningar, både kundens och projektens
        var anteckningsmappar = [kund.anteckningsmapp]
        anteckningsmappar += arkiv.projekt(för: kund).map(\.anteckningsmapp)
        for mapp in anteckningsmappar {
            for a in arkiv.anteckningar(i: mapp) {
                guard bank.behöverIndexeras(a.fil) else { r.oförändrade += 1; continue }
                try bank.glöm(källa: a.fil.path)
                for (i, stycke) in dela(a.text).enumerated() {
                    try bank.läggTill(
                        titel: i == 0 ? a.titel : "\(a.titel) (\(i + 1))",
                        text: stycke,
                        typ: "anteckning",
                        källa: a.fil.path,
                        tid: a.ändrad)
                    r.stycken += 1
                }
                try bank.markeraIndexerad(a.fil)
                r.indexerade += 1
            }
        }

        // Mejl: ämnesraderna. Brödtexten hämtas inte ur Mail, så det är vad
        // vi har — och ämnet räcker långt för att hitta rätt tråd.
        let mailfil = kund.mailmapp.appending(path: "mail.json")
        if FileManager.default.fileExists(atPath: mailfil.path), bank.behöverIndexeras(mailfil) {
            try bank.glöm(källa: mailfil.path)
            if let cache = arkiv.mailcache(för: kund) {
                for m in cache.mejl {
                    let huvud = "\(m.skickat ? "Skickat till" : "Från") \(m.avsändarnamn): \(m.ämne)"
                    // Brödtexten indexeras med, i stycken när den är lång.
                    let delar = m.text.isEmpty ? [""] : dela(m.text)
                    for (i, del) in delar.enumerated() {
                        try bank.läggTill(
                            titel: delar.count > 1 ? "\(m.ämne) (\(i + 1))" : m.ämne,
                            text: del.isEmpty ? huvud : "\(huvud)\n\n\(del)",
                            typ: "mejl",
                            källa: mailfil.path,
                            tid: m.datum)
                        r.stycken += 1
                    }
                }
                // Bilagornas innehåll är ofta det som betyder något: en offert
                // i en PDF eller en tabell i en skärmbild står sällan i mejlet.
                //
                // De ligger under sina egna källor och måste glömmas var för
                // sig. Nycklade på mail.json glömdes de aldrig, och varje
                // mailhämtning la på ett varv till — uppmätt låg en faktura
                // 28 gånger i indexet, och kopiorna fyllde topplistan.
                for källa in Set(cache.bilagor.map(\.fil)) {
                    try bank.glöm(källa: källa)
                }
                for b in cache.bilagor {
                    guard let text = b.text, !text.isEmpty else { continue }
                    for (i, stycke) in dela(text).enumerated() {
                        try bank.läggTill(
                            titel: i == 0 ? b.namn : "\(b.namn) (\(i + 1))",
                            text: stycke,
                            typ: "bilaga",
                            källa: b.fil,
                            tid: nil)
                        r.stycken += 1
                    }
                }
            }
            try bank.markeraIndexerad(mailfil)
            r.indexerade += 1
        }

        // Kopplade mappar indexeras med flit inte. En enda liten kodmapp gav
        // 481 stycken mot 70 för allt annat material om kunden tillsammans, och
        // kod är gammal i ett index nästan direkt. Frågor om dem besvaras i
        // stället av en agent som söker i mappen när frågan ställs — se
        // Kodagent.

        // Chattar. Det man frågat om och fått svar på är också något man kan
        // vilja hitta igen — särskilt slutsatser som inte skrivits ned någon
        // annanstans. De viktas ner vid sökning: de säger vad modellen
        // svarade, inte vad som faktiskt hände.
        let samtalsmapp = kund.mapp.appending(path: ".kundkoll/samtal")
        if let filer = try? FileManager.default.contentsOfDirectory(
            at: samtalsmapp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for fil in filer where fil.pathExtension == "json" {
                guard bank.behöverIndexeras(fil) else { r.oförändrade += 1; continue }
                try bank.glöm(källa: fil.path)
                guard let data = try? Data(contentsOf: fil),
                      let samtal = try? JSONDecoder.kundkoll.decode(Samtal.self, from: data)
                else { continue }
                // Fråga och svar hör ihop och indexeras som ett stycke.
                for (i, m) in samtal.meddelanden.enumerated() where m.roll == .människa {
                    let svar = i + 1 < samtal.meddelanden.count
                        && samtal.meddelanden[i + 1].roll == .assistent
                        ? samtal.meddelanden[i + 1].text : ""
                    guard !svar.isEmpty else { continue }
                    try bank.läggTill(
                        titel: String(m.text.prefix(60)),
                        text: "Fråga: \(m.text)\n\nSvar: \(svar)",
                        typ: "chatt",
                        källa: fil.path,
                        tid: m.tid)
                    r.stycken += 1
                }
                try bank.markeraIndexerad(fil)
                r.indexerade += 1
            }
        }

        // Kontakter
        let kontaktfil = kund.kontaktmapp.appending(path: "kontakter.json")
        if FileManager.default.fileExists(atPath: kontaktfil.path), bank.behöverIndexeras(kontaktfil) {
            try bank.glöm(källa: kontaktfil.path)
            for k in arkiv.kontakter(för: kund) {
                var rader = [k.namn]
                if let roll = k.roll { rader.append(roll) }
                rader += k.epost
                rader += k.telefon
                try bank.läggTill(titel: k.namn, text: rader.joined(separator: ", "),
                                  typ: "kontakt", källa: kontaktfil.path, tid: nil)
                r.stycken += 1
            }
            try bank.markeraIndexerad(kontaktfil)
            r.indexerade += 1
        }

        return r
    }

    /// Delar ett transkript i stycken med talare och tid kvar i texten, så att
    /// ett svar kan säga vem som sa vad och när.
    static func stycken(av inspelning: Inspelning) -> [String] {
        var ut: [String] = []
        var nuvarande = ""
        for y in inspelning.yttranden {
            let etikett = y.etikett(inspelning.röstnamn, enspårig: inspelning.enspårig)
            let rad = "[\(y.tidsstämpel)] \(etikett): \(y.text)\n"
            if nuvarande.count + rad.count > styckestorlek, !nuvarande.isEmpty {
                ut.append(nuvarande)
                nuvarande = ""
            }
            nuvarande += rad
        }
        if !nuvarande.isEmpty { ut.append(nuvarande) }
        return ut
    }

    /// Delar en text vid styckegränser, utan att kapa mitt i ett stycke.
    static func dela(_ text: String, storlek: Int = styckestorlek) -> [String] {
        let block = text.components(separatedBy: "\n\n")
        var ut: [String] = []
        var nuvarande = ""
        for b in block {
            let rent = b.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rent.isEmpty else { continue }
            if nuvarande.count + rent.count > storlek, !nuvarande.isEmpty {
                ut.append(nuvarande)
                nuvarande = ""
            }
            nuvarande += (nuvarande.isEmpty ? "" : "\n\n") + rent
        }
        if !nuvarande.isEmpty { ut.append(nuvarande) }
        return ut
    }
}
