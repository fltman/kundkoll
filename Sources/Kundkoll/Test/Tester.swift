import Foundation
import AVFoundation
import AppKit

@MainActor
enum Tester {

    static func kör() -> Int32 {
        arkivet()
        robusthet()
        personfilter()
        tystnadsfiltret()
        ljud()
        whisper()
        liveinsikter()
        mötesuppgifter()
        lagring()
        mötesserier()
        uppföljning()
        minVecka()
        ström()
        palett()
        briefing()
        omindexering()
        betydelse()
        transkriberingsmotorer()
        möteskopplingar()
        lägesbilden()
        tid()
        kontaktbilder()
        röster()
        kontakterOchKalender()
        mailen()
        anteckningar()
        obsidian()
        kunskapsbanken()
        return Prov.sammanfatta()
    }

    // MARK: - Kunskapsbanken

    static func kunskapsbanken() {
        Prov.svit("Kunskapsbanken")

        do {   // sökuttryck
            let u = Kunskapsbank.sökuttryck("leveranstiden")
            Prov.kolla(u.contains("*"), "orden söks som prefix, så böjningar fångas (\(u))")
            Prov.kolla(!Kunskapsbank.sökuttryck("vad har vi sagt om priset").contains("\"vad\""),
                       "stoppord sållas bort")
            Prov.kolla(Kunskapsbank.sökuttryck("och att det som").isEmpty,
                       "en fråga med bara stoppord ger inget uttryck")
            Prov.kolla(Kunskapsbank.sökuttryck("").isEmpty, "tom fråga ger tomt uttryck")
            Prov.kolla(Kunskapsbank.sökuttryck("DNV").contains("dnv"),
                       "korta ord söks exakt, inte som prefix")
        }

        do {   // indexera och söka
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let bank = try! Kunskapsbank(kund: kund)

            try! bank.läggTill(titel: "Avstämning", text: "Bo undrade över leveranstiden till Göteborg",
                               typ: "transkript", källa: "/a", tid: Date())
            try! bank.läggTill(titel: "Prisdiskussion", text: "Vi gick igenom prisbilden på battericeller",
                               typ: "transkript", källa: "/b", tid: Date())
            Prov.lika(bank.antal, 2, "två stycken i banken")

            // Det böjningsproblem trunkeringen finns till för
            Prov.kolla(!bank.sök("leveranstid").isEmpty,
                       "«leveranstid» hittar «leveranstiden»")
            Prov.kolla(!bank.sök("batteri").isEmpty,
                       "«batteri» hittar «battericeller»")
            Prov.lika(bank.sök("leveranstid").first?.titel, "Avstämning",
                      "rätt stycke kommer först")
            Prov.kolla(bank.sök("segelbåtar").isEmpty, "det som inte finns ger inga träffar")

            try! bank.glöm(källa: "/a")
            Prov.lika(bank.antal, 1, "en källa går att glömma")
            Prov.kolla(bank.sök("leveranstid").isEmpty, "och försvinner ur sökningen")
        }

        do {   // källor väger olika
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let bank = try! Kunskapsbank(kund: kund)

            // Ett gammalt chattsvar som sade att uppgiften saknades, och
            // fakturan som faktiskt har den.
            try! bank.läggTill(titel: "vad var fakturan på?",
                               text: "Fråga: vad var fakturan på? Svar: Beloppet framgår inte.",
                               typ: "chatt", källa: "/c", tid: nil)
            try! bank.läggTill(titel: "1124 Acme AB.pdf",
                               text: "Faktura fakturanr 1124 belopp 62 500,00 SEK",
                               typ: "bilaga", källa: "/b", tid: nil)

            let träffar = bank.sök("vad var fakturan på")
            Prov.lika(träffar.first?.typ, "bilaga",
                      "primärkällan går före ett tidigare chattsvar")
            Prov.kolla(träffar.contains { $0.typ == "chatt" },
                       "chatten finns kvar bland träffarna, bara längre ner")
        }

        do {   // svenska tecken i sökningen
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Ängsö")
            let bank = try! Kunskapsbank(kund: kund)
            try! bank.läggTill(titel: "Möte", text: "Vi besökte ÄNGSÖ och såg på pallställen",
                               typ: "anteckning", källa: "/a", tid: nil)
            Prov.kolla(!bank.sök("ängsö").isEmpty, "å ä ö söks utan hänsyn till skiftläge")
            Prov.kolla(!bank.sök("pallställ").isEmpty, "och fungerar mitt i sammansatta ord")
        }

        do {   // styckning av transkript
            var rader: [Yttrande] = []
            for i in 0..<40 {
                rader.append(Yttrande(röst: i % 2 == 0 ? .jag : .motpart,
                                      text: String(repeating: "ord ", count: 12),
                                      start: Double(i) * 5, slut: Double(i) * 5 + 4))
            }
            let i = Inspelning(titel: "Långt möte", inledd: Date(), längd: 200,
                               kund: "Acme", projekt: nil, mikrofon: nil,
                               liveYttranden: rader, arkivYttranden: nil)
            let stycken = Indexering.stycken(av: i)
            Prov.kolla(stycken.count > 1, "ett långt transkript delas i flera stycken (\(stycken.count))")
            Prov.kolla(stycken.allSatisfy { $0.count < Indexering.styckestorlek + 200 },
                       "inget stycke blir orimligt långt")
            Prov.kolla(stycken.first?.contains("Jag:") == true,
                       "talaren följer med in i texten")
            Prov.kolla(stycken.first?.contains("[00:00]") == true,
                       "och tidsstämpeln också, så svaret kan peka på rätt ställe")
        }

        do {   // styckning av text
            let text = "Första stycket.\n\n" + String(repeating: "Fyllnad. ", count: 200)
                + "\n\nSista stycket."
            let delar = Indexering.dela(text, storlek: 400)
            Prov.kolla(delar.count >= 2, "lång text delas (\(delar.count) delar)")
            Prov.kolla(delar.first?.hasPrefix("Första stycket.") == true,
                       "delningen sker vid styckegränser")
            Prov.lika(Indexering.dela("", storlek: 400).count, 0, "tom text ger inga delar")
        }

        do {   // hänvisningar i svaret
            func träff(_ titel: String) -> Kunskapsbank.Träff {
                Kunskapsbank.Träff(id: 1, typ: "transkript", titel: titel, text: "",
                                   källa: "", tid: nil, poäng: 0)
            }
            let träffar = [träff("Avstämning"), träff("Prisdiskussion"), träff("Uppstart")]
            let använda = Chatt.använda(i: "Priset diskuterades [2] och nämndes igen [2].", av: träffar)
            Prov.lika(använda.map(\.titel), ["Prisdiskussion"], "bara det svaret hänvisade till räknas")
            Prov.lika(använda.first?.nummer, 2, "numret följer med, så det går att para ihop med texten")
            Prov.lika(Chatt.använda(i: "Jag hittar inget om det.", av: träffar).count, 0,
                      "ett svar utan hänvisningar ger inga källor")
        }

        do {   // leverantörer
            for l in Leverantör.allCases {
                Prov.kolla(URL(string: l.standardadress) != nil,
                           "\(l.namn) har en giltig standardadress")
            }
            Prov.kolla(Leverantör.anthropic.talarAnthropic, "Anthropic har eget format")
            Prov.kolla(!Leverantör.openai.talarAnthropic, "OpenAI följer sitt eget")
            Prov.kolla(!Leverantör.openrouter.talarAnthropic,
                       "OpenRouter talar OpenAI-formatet även för Claude-modeller")
            Prov.kolla(!Leverantör.lokal.behöverNyckel, "en lokal modell behöver ingen nyckel")
            Prov.kolla(Leverantör.azure.behöverEgenAdress, "Azure kräver egen adress")

            var v = Modellval(leverantör: .lokal, modell: "llama3.1:8b", adress: "")
            Prov.kolla(v.färdig, "en lokal modell är färdig utan nyckel")
            Prov.lika(v.url?.host, "127.0.0.1", "och pekar på datorn")

            v = Modellval(leverantör: .azure, modell: "", adress: "")
            Prov.kolla(!v.färdig, "Azure utan adress är inte färdig")
        }

        do {   // svarsformat
            let openai = """
            {"choices":[{"message":{"role":"assistant","content":"Svaret är 42."}}]}
            """.data(using: .utf8)!
            Prov.lika(Chatt.läsOpenAI(openai), "Svaret är 42.", "OpenAI-svar tolkas")

            let anthropic = """
            {"content":[{"type":"thinking","text":"funderar"},{"type":"text","text":"Svaret är 42."}]}
            """.data(using: .utf8)!
            Prov.lika(Chatt.läsAnthropic(anthropic), "Svaret är 42.",
                      "Anthropic-svar tolkas och tankeblock hoppas över")

            Prov.kolla(Chatt.läsOpenAI(Data("{}".utf8)) == nil, "trasigt svar ger nil")
            Prov.kolla(Chatt.läsAnthropic(Data("{}".utf8)) == nil, "detsamma för Anthropic")
        }

        do {   // systemtexten
            let text = Chatt.systemtext(kund: "Acme", projekt: "Nytt lager", träffar: [])
            Prov.kolla(text.contains("Acme"), "kunden nämns")
            Prov.kolla(text.contains("Nytt lager"), "projektet nämns")
            Prov.kolla(text.contains("inget underlag"),
                       "utan underlag instrueras modellen att säga det")

            let träff = Kunskapsbank.Träff(id: 1, typ: "transkript", titel: "Möte",
                                           text: "Priset är 400 000.", källa: "", tid: nil, poäng: 0)
            let med = Chatt.systemtext(kund: "Acme", projekt: nil, träffar: [träff])
            Prov.kolla(med.contains("[1] TRANSKRIPT"), "underlaget numreras")
            Prov.kolla(med.contains("400 000"), "och innehåller texten")
        }

        do {   // bilagor
            Prov.kolla(Bilagor.ärIntressant("Offert.pdf"), "en PDF är värd att spara")
            Prov.kolla(Bilagor.ärIntressant("Skärmbild 2026-07-09.png"), "en skärmbild också")
            Prov.kolla(!Bilagor.ärIntressant("Mail Attachment.ics"),
                       "kalenderfiler säger inget om kunden")
            Prov.kolla(!Bilagor.ärIntressant("image001.png"),
                       "inbäddade signaturbilder sorteras bort")
            Prov.kolla(Bilagor.ärIntressant("image001-ritning.png"),
                       "men en bild med riktigt namn behålls")
            Prov.kolla(!Bilagor.ärIntressant("smime.p7s"), "signaturfiler sorteras bort")

            let d = "\u{1F}"
            let rader = [
                "Offert våren\(d)Offert.pdf\(d)/tmp/Offert.pdf\(d)102400",
                "Möte\(d)Mail Attachment.ics\(d)/tmp/x.ics\(d)4198",
                "Ritningar\(d)plan.png\(d)/tmp/plan.png\(d)51200",
            ].joined(separator: "\n")
            let b = Bilagor.tolka(rader)
            Prov.lika(b.count, 2, "ointressanta bilagor faller bort vid tolkningen")
            Prov.lika(b.first?.namn, "Offert.pdf", "namnet kommer med")
            Prov.lika(b.first?.storlek, 102400, "storleken tolkas")
            Prov.lika(b.first?.ändelse, "pdf", "ändelsen plockas ur namnet")

            Prov.lika(Bilagor.tolka("").count, 0, "tomt svar ger inga bilagor")
        }

        do {   // text ur kontorsfiler
            let xml = "<w:p><w:r><w:t>Offerten g&amp;auml;ller</w:t></w:r><w:t>400 &lt;pallplatser&gt;</w:t></w:p>"
            let text = Bilagor.strippaTaggar(xml)
            Prov.kolla(text.contains("Offerten"), "texten mellan taggarna kommer med")
            Prov.kolla(text.contains("400"), "och nästa stycke också")
            Prov.kolla(!text.contains("<w:"), "taggarna följer inte med")
            Prov.kolla(!text.contains("&lt;"), "XML-entiteter översätts")

            // Bara filerna som bär text. Utan det kom rader som "Microsoft
            // Office Word 0 406 248" med mitt i innehållet.
            func url(_ v: String) -> URL { URL(fileURLWithPath: v) }
            Prov.kolla(Bilagor.ärInnehåll(url("/t/word/document.xml")), "word/document.xml läses")
            Prov.kolla(Bilagor.ärInnehåll(url("/t/ppt/slides/slide1.xml")), "presentationsbilder läses")
            Prov.kolla(Bilagor.ärInnehåll(url("/t/xl/sharedStrings.xml")), "kalkylbladets texter läses")
            Prov.kolla(!Bilagor.ärInnehåll(url("/t/docProps/app.xml")), "dokumentegenskaper hoppas över")
            Prov.kolla(!Bilagor.ärInnehåll(url("/t/word/theme/theme1.xml")), "teman hoppas över")
            Prov.kolla(!Bilagor.ärInnehåll(url("/t/word/settings.xml")), "inställningar hoppas över")
        }

        do {   // ofullständiga inspelningar
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let fm = FileManager.default

            // En mapp med ljud men utan möte.json, som en avbruten import
            let halv = try! arkiv.nyInspelningsmapp(placering: .kund(kund),
                                                    titel: "Avbruten", datum: Date())
            fm.createFile(atPath: halv.appending(path: "motpart.wav").path,
                          contents: Data(count: 5000))
            // Och en tom mapp, som inte är värd att visa
            let tom = try! arkiv.nyInspelningsmapp(placering: .kund(kund),
                                                   titel: "Tom", datum: Date())
            _ = tom

            let ofullständiga = arkiv.ofullständiga(för: kund)
            Prov.lika(ofullständiga.count, 1, "bara mappen med ljud räknas som påbörjad")
            Prov.lika(ofullständiga.first?.storlek, 5000, "storleken räknas")
            Prov.lika(arkiv.inspelningar(för: kund).count, 0,
                      "den syns inte bland de färdiga")

            // När den blir klar ska den försvinna ur listan
            let i = Inspelning(titel: "Avbruten", inledd: Date(), längd: 1,
                               kund: "Acme", projekt: nil, mikrofon: nil,
                               liveYttranden: [], arkivYttranden: nil)
            try! arkiv.spara(i, i: halv)
            Prov.lika(arkiv.ofullständiga(för: kund).count, 0,
                      "en färdigställd inspelning räknas inte längre som påbörjad")
        }

        do {   // kopplade mappar
            Prov.kolla(Kopplademappar.hoppaÖver.contains("node_modules"),
                       "node_modules läses inte igenom")
            Prov.kolla(Kopplademappar.hoppaÖver.contains(".git"), "inte heller .git")
            Prov.kolla(Kopplademappar.standardändelser.contains("swift"), "kodfiler tas med")
            Prov.kolla(Kopplademappar.standardändelser.contains("pdf"), "och PDF")
            Prov.kolla(!Kopplademappar.standardändelser.contains("png"),
                       "bilder i en kodmapp är sällan innehåll")

            let ä = Kopplademappar.standardändelser
            Prov.kolla(Kopplademappar.ärIntressant(URL(fileURLWithPath: "/a/main.swift"), ändelser: ä),
                       "en källfil är intressant")
            Prov.kolla(!Kopplademappar.ärIntressant(URL(fileURLWithPath: "/a/.env"), ändelser: ä),
                       "dolda filer hoppas över")
            Prov.kolla(!Kopplademappar.ärIntressant(URL(fileURLWithPath: "/a/bild.png"), ändelser: ä),
                       "bilder hoppas över")

            let k = Kopplad(väg: "/tmp/kod")
            Prov.lika(k.visatNamn, "kod", "mappens eget namn används när inget angetts")
            Prov.lika(Kopplad(väg: "/tmp/kod", namn: "Källkod").visatNamn, "Källkod",
                      "ett eget namn går före")
        }

        do {   // koppling sparas på projektet
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let projekt = try! arkiv.skapaProjekt(namn: "Nytt lager", hos: kund)

            let mapp = rot.appending(path: "extern-kod")
            try! FileManager.default.createDirectory(at: mapp, withIntermediateDirectories: true)
            try! arkiv.koppla(mapp, till: projekt)
            Prov.lika(arkiv.kopplade(för: projekt).count, 1, "mappen kopplas till projektet")

            try! arkiv.koppla(mapp, till: projekt)
            Prov.lika(arkiv.kopplade(för: projekt).count, 1, "samma mapp två gånger ger ingen dubblett")

            let k = arkiv.kopplade(för: projekt).first!
            Prov.kolla(k.finns, "kopplingen ser att mappen finns")
            try! arkiv.koppla(bort: k, från: projekt)
            Prov.lika(arkiv.kopplade(för: projekt).count, 0, "den går att koppla bort")
            Prov.kolla(FileManager.default.fileExists(atPath: mapp.path),
                       "och mappen ligger kvar på disk — bara kopplingen försvann")
        }

        do {   // genomgång av en mapp
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let fm = FileManager.default
            for väg in ["src", "node_modules/paket", ".git"] {
                try! fm.createDirectory(at: rot.appending(path: väg), withIntermediateDirectories: true)
            }
            fm.createFile(atPath: rot.appending(path: "src/main.swift").path, contents: Data("kod".utf8))
            fm.createFile(atPath: rot.appending(path: "README.md").path, contents: Data("text".utf8))
            fm.createFile(atPath: rot.appending(path: "logo.png").path, contents: Data([0x89]))
            fm.createFile(atPath: rot.appending(path: "node_modules/paket/index.js").path,
                          contents: Data("skräp".utf8))
            fm.createFile(atPath: rot.appending(path: ".git/config").path, contents: Data("x".utf8))

            let filer = Kopplademappar.filer(i: Kopplad(väg: rot.path))
            let namn = Set(filer.map(\.lastPathComponent))
            Prov.kolla(namn.contains("main.swift"), "källfiler hittas i undermappar")
            Prov.kolla(namn.contains("README.md"), "och dokument")
            Prov.kolla(!namn.contains("logo.png"), "bilder hoppas över")
            Prov.kolla(!namn.contains("index.js"),
                       "node_modules gås inte igenom (\(namn.count) filer totalt)")
            Prov.kolla(!namn.contains("config"), ".git gås inte igenom")
        }

        do {   // samtal
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let projekt = try! arkiv.skapaProjekt(namn: "Nytt lager", hos: kund)

            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 0, "inga samtal från början")

            var ett = Samtal(projekt: nil, meddelanden: [
                .init(roll: .människa, text: "Vad kostade battericellerna?"),
                .init(roll: .assistent, text: "2 400 kr per enhet."),
            ])
            try! arkiv.spara(ett, för: kund)
            let sparade = arkiv.samtal(för: kund, projekt: nil)
            Prov.lika(sparade.count, 1, "samtalet sparas")
            Prov.lika(sparade.first?.titel, "Vad kostade battericellerna?",
                      "titeln härleds ur första frågan")

            // Ett andra samtal, och ett i projektet
            let två = Samtal(meddelanden: [.init(roll: .människa, text: "Vem är kontaktperson?")])
            try! arkiv.spara(två, för: kund)
            try! arkiv.spara(Samtal(projekt: "Nytt lager",
                                    meddelanden: [.init(roll: .människa, text: "Hur går bygget?")]),
                             för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 2,
                      "kundens samtal är två")
            Prov.lika(arkiv.samtal(för: kund, projekt: "Nytt lager").count, 1,
                      "projektet ser bara sitt eget")
            _ = projekt

            // Nyast först, så att man landar i det man höll på med
            let ordning = arkiv.samtal(för: kund, projekt: nil)
            Prov.kolla((ordning.first?.ändrad ?? .distantPast) >= (ordning.last?.ändrad ?? .distantFuture),
                       "nyast först")

            ett.meddelanden.append(.init(roll: .människa, text: "Och volymrabatten?"))
            try! arkiv.spara(ett, för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 2,
                      "att spara om ett samtal skapar inte ett nytt")
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).first?.id, ett.id,
                      "det senast ändrade ligger överst")

            try! arkiv.taBort(två, för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 1, "samtal går att ta bort")

            // Ett samtal om ett enskilt möte hör hemma i transkriptvyn och
            // ska inte dyka upp i kundens allmänna chatt.
            let mötesid = UUID().uuidString
            var omMötet = Samtal(möte: mötesid)
            omMötet.meddelanden = [.init(roll: .människa, text: "Vad sa vi om priset?")]
            try! arkiv.spara(omMötet, för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 1,
                      "ett mötessamtal syns inte i kundens chatt")
            Prov.lika(arkiv.samtal(för: kund, projekt: nil, möte: mötesid).count, 1,
                      "men i mötets egen")
            Prov.lika(arkiv.samtal(för: kund, projekt: nil, möte: UUID().uuidString).count, 0,
                      "och inte i ett annat mötes")

            Prov.lika(Samtal.titel(ur: []), "Nytt samtal", "ett tomt samtal får ett namn ändå")
            let lång = String(repeating: "ord ", count: 40)
            Prov.kolla(Samtal.titel(ur: [.init(roll: .människa, text: lång)]).count <= 53,
                       "en lång fråga kapas till en läsbar titel")
        }

        do {   // en chatt från tiden före samtalen
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")

            // Så såg det ut när varje kund hade exakt en chatt
            let gammal = kund.mapp.appending(path: ".kundkoll/chatt.json")
            try! FileManager.default.createDirectory(
                at: gammal.deletingLastPathComponent(), withIntermediateDirectories: true)
            let meddelanden: [Chatt.Meddelande] = [
                .init(roll: .människa, text: "Vad sa vi om leveranstiden?"),
                .init(roll: .assistent, text: "Sex veckor."),
            ]
            try! JSONEncoder.kundkoll.encode(meddelanden).write(to: gammal)

            let samtal = arkiv.samtal(för: kund, projekt: nil)
            Prov.lika(samtal.count, 1, "den gamla chatten blir ett samtal")
            Prov.lika(samtal.first?.titel, "Vad sa vi om leveranstiden?", "med titel ur frågan")
            Prov.lika(samtal.first?.meddelanden.count, 2, "och alla meddelanden kvar")
            Prov.kolla(!FileManager.default.fileExists(atPath: gammal.path),
                       "den gamla filen städas bort efter flytten")
        }

        do {   // uppgifter
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")

            try! arkiv.läggTill([Uppgift(vad: "Skicka offert på pallställ", vem: "Anders",
                                         när: "före fredag", ursprung: .möte,
                                         källtitel: "Avstämning")], för: kund)
            Prov.lika(arkiv.uppgifter(för: kund).count, 1, "uppgiften sparas")

            // Samma sak nämns ofta i både ett möte och ett mejl
            try! arkiv.läggTill([Uppgift(vad: "Skicka offerten på pallställen",
                                         ursprung: .mejl)], för: kund)
            Prov.lika(arkiv.uppgifter(för: kund).count, 1,
                      "samma åtagande från två håll blir inte två kort")

            try! arkiv.läggTill([Uppgift(vad: "Boka möte om certifieringen")], för: kund)
            Prov.lika(arkiv.uppgifter(för: kund).count, 2, "något annat blir ett eget kort")

            var u = arkiv.uppgifter(för: kund).first!
            u.läge = .pågår
            try! arkiv.uppdatera(u, för: kund)
            Prov.lika(arkiv.uppgifter(för: kund).first?.läge, .pågår, "läget går att ändra")

            let not = try! String(contentsOf: kund.mapp.appending(path: "Att göra.md"),
                                  encoding: .utf8)
            Prov.kolla(not.contains("## Pågår"), "tavlan skrivs som markdown")
            Prov.kolla(not.contains("**Anders**"), "med vem som ska göra det")
            Prov.kolla(not.contains("*(före fredag)*"), "och när")

            try! arkiv.taBort(u, för: kund)
            Prov.lika(arkiv.uppgifter(för: kund).count, 1, "uppgifter går att ta bort")
        }

        do {   // likhet mellan uppgifter
            let a = Uppgift(vad: "Skicka offert på pallställ före fredag")
            Prov.kolla(a.liknar(Uppgift(vad: "Skicka offerten på pallställen på fredag")),
                       "samma sak i annan formulering känns igen")
            Prov.kolla(!a.liknar(Uppgift(vad: "Boka möte om certifieringen")),
                       "olika saker hålls isär")
            Prov.kolla(!a.liknar(Uppgift(vad: "")), "tom uppgift liknar inget")
        }

        do {   // samtal
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let projekt = try! arkiv.skapaProjekt(namn: "Nytt lager", hos: kund)

            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 0, "inga samtal från början")

            var ett = Samtal(projekt: nil, meddelanden: [
                .init(roll: .människa, text: "Vad kostade battericellerna?"),
                .init(roll: .assistent, text: "2 400 kr per enhet."),
            ])
            try! arkiv.spara(ett, för: kund)
            let sparade = arkiv.samtal(för: kund, projekt: nil)
            Prov.lika(sparade.count, 1, "samtalet sparas")
            Prov.lika(sparade.first?.titel, "Vad kostade battericellerna?",
                      "titeln härleds ur första frågan")

            // Ett andra samtal, och ett i projektet
            let två = Samtal(meddelanden: [.init(roll: .människa, text: "Vem är kontaktperson?")])
            try! arkiv.spara(två, för: kund)
            try! arkiv.spara(Samtal(projekt: "Nytt lager",
                                    meddelanden: [.init(roll: .människa, text: "Hur går bygget?")]),
                             för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 2,
                      "kundens samtal är två")
            Prov.lika(arkiv.samtal(för: kund, projekt: "Nytt lager").count, 1,
                      "projektet ser bara sitt eget")
            _ = projekt

            // Nyast först, så att man landar i det man höll på med
            let ordning = arkiv.samtal(för: kund, projekt: nil)
            Prov.kolla((ordning.first?.ändrad ?? .distantPast) >= (ordning.last?.ändrad ?? .distantFuture),
                       "nyast först")

            ett.meddelanden.append(.init(roll: .människa, text: "Och volymrabatten?"))
            try! arkiv.spara(ett, för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 2,
                      "att spara om ett samtal skapar inte ett nytt")
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).first?.id, ett.id,
                      "det senast ändrade ligger överst")

            try! arkiv.taBort(två, för: kund)
            Prov.lika(arkiv.samtal(för: kund, projekt: nil).count, 1, "samtal går att ta bort")

            Prov.lika(Samtal.titel(ur: []), "Nytt samtal", "ett tomt samtal får ett namn ändå")
            let lång = String(repeating: "ord ", count: 40)
            Prov.kolla(Samtal.titel(ur: [.init(roll: .människa, text: lång)]).count <= 53,
                       "en lång fråga kapas till en läsbar titel")
        }

        do {   // en chatt från tiden före samtalen
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")

            // Så såg det ut när varje kund hade exakt en chatt
            let gammal = kund.mapp.appending(path: ".kundkoll/chatt.json")
            try! FileManager.default.createDirectory(
                at: gammal.deletingLastPathComponent(), withIntermediateDirectories: true)
            let meddelanden: [Chatt.Meddelande] = [
                .init(roll: .människa, text: "Vad sa vi om leveranstiden?"),
                .init(roll: .assistent, text: "Sex veckor."),
            ]
            try! JSONEncoder.kundkoll.encode(meddelanden).write(to: gammal)

            let samtal = arkiv.samtal(för: kund, projekt: nil)
            Prov.lika(samtal.count, 1, "den gamla chatten blir ett samtal")
            Prov.lika(samtal.first?.titel, "Vad sa vi om leveranstiden?", "med titel ur frågan")
            Prov.lika(samtal.first?.meddelanden.count, 2, "och alla meddelanden kvar")
            Prov.kolla(!FileManager.default.fileExists(atPath: gammal.path),
                       "den gamla filen städas bort efter flytten")
        }

        do {   // uppgifter ur modellens JSON
            let json = """
            {"uppgifter": [
              {"vad": "Skicka ritningar", "vem": "Anders", "när": "på måndag"},
              {"vad": "Kolla priset", "vem": null, "när": null},
              {"vad": "kort", "vem": null, "när": null}
            ]}
            """
            let u = Uppgiftsletare.tolka(json)
            Prov.lika(u.count, 2, "för korta rader sorteras bort")
            Prov.lika(u.first?.vem, "Anders", "vem tolkas")
            Prov.kolla(u.last?.vem == nil, "null blir nil")
            Prov.lika(Uppgiftsletare.tolka("inget här").count, 0, "text utan JSON ger inga uppgifter")

            let ikodruta = "Här kommer de:\n```json\n" + json + "\n```"
            Prov.lika(Uppgiftsletare.tolka(ikodruta).count, 2, "JSON i kodruta tolkas")
        }

        do {   // gamla filer utan nya fält
            // Det här var en verklig bugg: fältet "text" lades till på Mejl,
            // och då slutade alla tidigare sparade mail.json gå att läsa —
            // tyst, eftersom felet bara syntes som att ingenting hände.
            let gammalt = """
            {"hämtad": "2026-08-31T19:43:13Z",
             "mejl": [{"datumText": "Monday, 3 August 2026 at 09:00:00",
                       "avsändare": "Anna <anna@acme.se>", "ämne": "Offert",
                       "meddelandeID": "<a@x>", "konto": "k", "låda": "INBOX",
                       "riktning": "fran"}]}
            """
            let cache = try? JSONDecoder.kundkoll.decode(
                Arkivet.Mailcache.self, from: Data(gammalt.utf8))
            Prov.kolla(cache != nil, "en mailcache utan bilagor och brödtext går att läsa")
            Prov.kolla(cache?.hämtad != nil, "datum utan sekundbråk går fortfarande att läsa")
            Prov.lika(cache?.mejl.count, 1, "mejlen kommer med")
            Prov.lika(cache?.mejl.first?.text, "", "brödtexten blir tom i stället för att fälla")
            Prov.lika(cache?.bilagor.count, 0, "bilagorna blir en tom lista")

            let gammalInspelning = """
            {"titel": "Avstämning", "inledd": "2026-08-31T19:43:13Z", "längd": 120,
             "kund": "Acme", "liveYttranden": []}
            """
            let i = try? JSONDecoder.kundkoll.decode(
                Inspelning.self, from: Data(gammalInspelning.utf8))
            Prov.kolla(i != nil, "en inspelning utan de senaste fälten går att läsa")
            Prov.lika(i?.titel, "Avstämning", "titeln kommer med")
            Prov.lika(i?.enspårig, false, "enspårig får sitt standardvärde")
            Prov.lika(i?.kallade.count, 0, "kallade blir tom")
            Prov.kolla(i?.sammanfattning == nil, "sammanfattningen blir nil")

            let gammalKontakt = """
            {"namn": "Anna Svensson"}
            """
            let k = try? JSONDecoder.kundkoll.decode(Kontakt.self, from: Data(gammalKontakt.utf8))
            Prov.lika(k?.namn, "Anna Svensson", "en kontakt med bara namn går att läsa")
            Prov.lika(k?.epost.count, 0, "adresserna blir en tom lista")
        }

        do {   // brödtext ur mejl
            let d = "\u{1F}"
            let rad = "Monday, 3 August 2026 at 09:00:00\(d)Anna <anna@acme.se>\(d)Offert\(d)<a@x>\(d)konto\(d)INBOX\(d)fran\(d)Hej! Här kommer offerten på pallställ."
            let m = Mailen.tolka(rad).first
            Prov.lika(m?.text, "Hej! Här kommer offerten på pallställ.",
                      "brödtexten kommer med")

            // Citerade svar och signaturer klipps: de finns redan indexerade
            // var för sig och skulle bara fylla banken.
            Prov.lika(Mailen.städaBrödtext("Nytt svar här.\n\nFrån: Anna\nGammalt svar"),
                      "Nytt svar här.", "citat klipps bort")
            Prov.lika(Mailen.städaBrödtext("Kort svar.\nSkickat från min iPhone"),
                      "Kort svar.", "signaturer klipps bort")
            Prov.lika(Mailen.städaBrödtext("  Bara text.  "), "Bara text.",
                      "blanksteg trimmas")

            let utan = "Monday, 3 August 2026 at 09:00:00\(d)A <a@x.se>\(d)Ämne\(d)<b@x>\(d)konto\(d)INBOX\(d)fran"
            Prov.lika(Mailen.tolka(utan).first?.text, "",
                      "äldre rader utan brödtext tolkas ändå")
        }

        do {   // sammanfattningens JSON
            let json = """
            {"kärna": "Genomgång av lagerprojektet.",
             "beslut": ["Offert före fredag"],
             "åtaganden": [{"vad": "Skicka ritningar", "vem": "Anders", "när": "på måndag"},
                           {"vad": "Kolla pris", "vem": null, "när": null}],
             "öppet": ["Vem betalar frakten?"]}
            """
            let s = Sammanfattare.tolka(json)
            Prov.lika(s?.kärna, "Genomgång av lagerprojektet.", "kärnan tolkas")
            Prov.lika(s?.beslut.count, 1, "beslut tolkas")
            Prov.lika(s?.åtaganden.count, 2, "åtaganden tolkas")
            Prov.lika(s?.åtaganden.first?.vem, "Anders", "vem som ska göra det")
            Prov.lika(s?.åtaganden.first?.när, "på måndag", "och när")
            Prov.kolla(s?.åtaganden.last?.vem == nil, "null blir nil, inte strängen null")
            Prov.lika(s?.öppet.count, 1, "öppna frågor tolkas")
            Prov.kolla(!(s?.tom ?? true), "en ifylld sammanfattning är inte tom")

            // Modeller lägger gärna JSON i en kodruta och skriver en rad före
            let ikodruta = "Här är sammanfattningen:\n\n```json\n" + json + "\n```"
            Prov.kolla(Sammanfattare.tolka(ikodruta) != nil, "JSON i kodruta tolkas")
            Prov.lika(Sammanfattare.tolka(ikodruta)?.beslut.count, 1, "och innehållet kommer med")

            Prov.kolla(Sammanfattare.tolka("inget här") == nil, "text utan JSON ger nil")
            let tom = Sammanfattare.tolka("""
            {"kärna": "", "beslut": [], "åtaganden": [], "öppet": []}
            """)
            Prov.kolla(tom?.tom == true, "en sammanfattning utan innehåll räknas som tom")
        }

        do {   // markdown i svaren
            let block = Markdowntext.tolka("""
            Här är vad som sades:

            - Cell Sourcing Platform beskrivs som en av punkterna [4]
            - Man får tillbaka inspect sheets

            1. Tidsfönstret
            2. Gruppstorlek

            # Sammanfattning

            Sista stycket.
            """)
            Prov.kolla(block.contains(.punkt("Cell Sourcing Platform beskrivs som en av punkterna [4]", nivå: 0)),
                       "bindestreckslistor blir punkter")
            Prov.kolla(block.contains(.numrerad(1, "Tidsfönstret", nivå: 0)),
                       "numrerade listor behåller sina nummer")
            Prov.kolla(block.contains(.rubrik("Sammanfattning")), "rubriker känns igen")
            Prov.kolla(block.contains(.stycke("Sista stycket.")), "vanliga stycken kommer med")

            // Rader i samma stycke slås ihop, tomrad bryter
            let ihop = Markdowntext.tolka("En rad\noch en till\n\nNytt stycke")
            Prov.lika(ihop, [.stycke("En rad och en till"), .stycke("Nytt stycke")],
                      "radbrytning inom ett stycke blir mellanslag")

            Prov.lika(Markdowntext.tolka("").count, 0, "tom text ger inga block")
            Prov.lika(Markdowntext.tolka("bara text"), [.stycke("bara text")],
                      "text utan markdown blir ett stycke")

            // Ett indraget listelement hamnar en nivå in
            let indrag = Markdowntext.tolka("- överst\n  - inunder")
            Prov.kolla(indrag.contains(.punkt("inunder", nivå: 1)), "indrag ger en nivå")
        }

        do {   // nyckelringen
            let konto = "kundkoll-prov-\(UUID().uuidString)"
            defer { Nyckelring.spara("", som: konto) }
            Prov.kolla(Nyckelring.hämta(konto) == nil, "ingen nyckel från början")
            Prov.kolla(Nyckelring.spara("hemlig-nyckel", som: konto), "nyckeln går att spara")
            Prov.lika(Nyckelring.hämta(konto), "hemlig-nyckel", "och att läsa tillbaka")
            Prov.kolla(Nyckelring.spara("", som: konto), "en tom nyckel tar bort posten")
            Prov.kolla(Nyckelring.hämta(konto) == nil, "och då finns den inte längre")
        }
    }

    // MARK: - Obsidian

    static func obsidian() {
        Prov.svit("Obsidian")
        // Sökvägar med å ä ö och mellanslag måste överleva kodningen
        let c = CharacterSet.urlQueryValueAllowed
        Prov.kolla(!c.contains(Unicode.Scalar("/")), "snedstreck kodas i sökvägen")
        Prov.kolla(!c.contains(Unicode.Scalar("&")), "och-tecken kodas")
        let kodad = "/Users/a/Documents/Kunder/Ängsö Trä/Anteckningar/Möte.md"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
        Prov.kolla(kodad != nil, "sökvägen går att koda")
        Prov.kolla(kodad?.contains("%2F") == true, "snedstrecken är kodade")
        Prov.kolla(URL(string: "obsidian://open?path=\(kodad ?? "")") != nil,
                   "resultatet blir en giltig URL")
    }

    // MARK: - Anteckningar

    static func anteckningar() {
        Prov.svit("Anteckningar")
        let fm = FileManager.default

        do {
            let rot = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let projekt = try! arkiv.skapaProjekt(namn: "Nytt lager", hos: kund)
            let mapp = projekt.anteckningsmapp

            let a = try! arkiv.nyAnteckning(i: mapp, titel: "Möte om layout")
            Prov.kolla(fm.fileExists(atPath: a.fil.path), "anteckningen blir en markdownfil")
            Prov.lika(a.fil.pathExtension, "md", "med rätt filändelse")
            Prov.lika(arkiv.anteckningar(i: mapp).count, 1, "och hittas i mappen")

            // Samma rubrik två gånger ska inte skriva över
            let b = try! arkiv.nyAnteckning(i: mapp, titel: "Möte om layout")
            Prov.kolla(a.fil != b.fil, "samma rubrik ger inte samma fil")
            Prov.lika(arkiv.anteckningar(i: mapp).count, 2, "båda finns kvar")

            var c = a
            c.text = "# Möte om layout\n\nLagret ska rymma 400 pallplatser.\n"
            try! arkiv.spara(c)
            let läst = arkiv.anteckningar(i: mapp).first { $0.titel == a.titel }
            Prov.kolla(läst?.text.contains("400 pallplatser") == true, "texten sparas")
            Prov.lika(läst?.utdrag, "Lagret ska rymma 400 pallplatser.",
                      "utdraget hoppar över rubriken")

            let omdöpt = try! arkiv.döpOm(c, till: "Layoutmöte 12 sep")
            Prov.lika(omdöpt.titel, "Layoutmöte 12 sep", "anteckningen går att döpa om")
            Prov.kolla(!fm.fileExists(atPath: a.fil.path), "den gamla filen lämnas inte kvar")
            Prov.kolla(fm.fileExists(atPath: omdöpt.fil.path), "den nya filen finns")

            try! arkiv.taBort(omdöpt)
            Prov.lika(arkiv.anteckningar(i: mapp).count, 1, "anteckningar går att ta bort")
        }

        do {   // bilder
            let rot = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let mapp = kund.anteckningsmapp

            let namn = try! arkiv.sparaBild(Data([0x89, 0x50, 0x4E, 0x47]), ändelse: "png", i: mapp)
            Prov.kolla(namn.hasPrefix("bilder/"), "bilden hamnar i en egen mapp (\(namn))")
            Prov.kolla(fm.fileExists(atPath: mapp.appending(path: namn).path),
                       "filen finns på disk")

            var a = try! arkiv.nyAnteckning(i: mapp, titel: "Skisser")
            a.text = "# Skisser\n\n![[\(namn)]]\n\nText emellan\n\n![[bilder/annan.png]]\n"
            Prov.lika(a.bilder.count, 2, "båda bilderna hittas i texten")
            Prov.lika(a.bilder.first, namn, "i den ordning de förekommer")

            a.text = "# Utan bilder\n\nSe [[En annan anteckning]] för mer.\n"
            Prov.lika(a.bilder.count, 0,
                      "vanliga wikilänkar räknas inte som bilder")
        }

        do {   // filnamn
            let rot = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let a = try! arkiv.nyAnteckning(i: kund.anteckningsmapp, titel: "Före/efter: ändringar")
            Prov.kolla(!a.titel.contains("/"),
                       "snedstreck i rubriken skapar inte oavsiktliga undermappar")
            Prov.kolla(fm.fileExists(atPath: a.fil.path), "anteckningen skapas ändå")

            let tom = try! arkiv.nyAnteckning(i: kund.anteckningsmapp, titel: "")
            Prov.lika(tom.titel, "Anteckning", "en anteckning utan rubrik får ett namn ändå")
        }
    }

    // MARK: - Kontakter och kalender

    static func kontakterOchKalender() {
        Prov.svit("Kontakter och kalender")

        do {   // e-postmatchning
            let k = Kontakt(namn: "Anna", epost: ["Anna@Acme.se"])
            Prov.kolla(k.matchar(epost: "anna@acme.se"), "matchning bryr sig inte om skiftläge")
            Prov.kolla(k.matchar(epost: "Anna Svensson <anna@acme.se>"),
                       "adressen hittas även inbäddad i ett namn")
            Prov.kolla(!k.matchar(epost: "anna@annat.se"), "fel domän matchar inte")
        }

        do {   // domäner, med allmänna leverantörer bortsorterade
            let d = Kalendern.domäner(hos: [
                Kontakt(namn: "A", epost: ["a@acme.se"]),
                Kontakt(namn: "B", epost: ["b@gmail.com"]),
                Kontakt(namn: "C", epost: ["c@acme.se", "privat@hotmail.com"]),
            ])
            Prov.lika(d, ["acme.se"],
                      "gmail och hotmail räknas inte som kundens domän, annars matchar varje möte")
        }

        do {   // mötesmatchning
            let kund = Kund(namn: "Acme AB", mapp: URL(fileURLWithPath: "/tmp/Acme AB"))
            let kontakter = [Kontakt(namn: "Anna Svensson", epost: ["anna@acme.se"])]
            func möte(_ titel: String, _ deltagare: [(String, String?)]) -> Kalendern.Möte {
                Kalendern.Möte(id: UUID().uuidString, titel: titel, start: Date(),
                               slut: Date().addingTimeInterval(3600),
                               deltagare: deltagare.map {
                                   Kalendern.Deltagare(namn: $0.0, epost: $0.1, ärJag: false) },
                               plats: nil, möteslänk: nil)
            }
            Prov.kolla(Kalendern.hör(möte("Avstämning", [("Anna Svensson", "anna@acme.se")]),
                                     till: kund, kontakter: kontakter),
                       "möte med en känd kontakt hör till kunden")
            Prov.kolla(Kalendern.hör(möte("Uppstart", [("Bo Ek", "bo@acme.se")]),
                                     till: kund, kontakter: kontakter),
                       "okänd person på kundens domän räknas också")
            Prov.kolla(Kalendern.hör(möte("Möte med Acme AB", [("Cecilia", "c@annat.se")]),
                                     till: kund, kontakter: kontakter),
                       "kundnamnet i titeln räcker när adresser saknas")
            Prov.kolla(!Kalendern.hör(möte("Tandläkare", [("Tandvården", "info@tandlakaren.se")]),
                                      till: kund, kontakter: kontakter),
                       "ovidkommande möten sorteras bort")
        }

        do {   // deltagare som visas
            func möte(_ deltagare: [(String, Bool)]) -> Kalendern.Möte {
                Kalendern.Möte(id: "1", titel: "T", start: Date(), slut: Date(),
                               deltagare: deltagare.map {
                                   Kalendern.Deltagare(namn: $0.0, epost: nil, ärJag: $0.1) },
                               plats: nil, möteslänk: nil)
            }
            let m = möte([("Anders Bjarby", true), ("Kristin Sand Bakken", false)])
            Prov.lika(m.deltagare.filter { !$0.ärJag }.map(\.namn), ["Kristin Sand Bakken"],
                      "jag själv räknas inte som motpart i deltagarlistan")
        }

        do {   // kontakter sparas per kund och slås ihop
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")

            try! arkiv.läggTill(Kontakt(namn: "Anna Svensson", epost: ["anna@acme.se"]), hos: kund)
            Prov.lika(arkiv.kontakter(för: kund).count, 1, "kontakten sparas")

            // Samma person igen, från ett annat håll och med mer uppgifter
            try! arkiv.läggTill(Kontakt(namn: "Anna Svensson", roll: "VD",
                                        epost: ["anna.svensson@acme.se"],
                                        telefon: ["070-1234567"]), hos: kund)
            let alla = arkiv.kontakter(för: kund)
            Prov.lika(alla.count, 1, "samma namn ger inte en dubblett")
            Prov.lika(alla.first?.epost.count, 2, "adresserna slås ihop")
            Prov.lika(alla.first?.roll, "VD", "uppgifter som saknades fylls i")

            Prov.kolla(FileManager.default.fileExists(
                atPath: kund.kontaktmapp.appending(path: "Anna Svensson.md").path),
                       "kontakten får en not i vaultet")

            try! arkiv.taBort(alla.first!, hos: kund)
            Prov.lika(arkiv.kontakter(för: kund).count, 0, "kontakten går att ta bort")
        }

        do {   // redigering
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            try! arkiv.läggTill(Kontakt(namn: "Bo Ek"), hos: kund)

            var bo = arkiv.kontakter(för: kund).first!
            bo.roll = "Inköpschef"
            bo.epost = ["bo@acme.se", "bo.ek@acme.se"]
            bo.telefon = ["070-1234567"]
            try! arkiv.uppdatera(bo, hos: kund)

            let sparad = arkiv.kontakter(för: kund).first
            Prov.lika(sparad?.roll, "Inköpschef", "rollen sparas")
            Prov.lika(sparad?.epost.count, 2, "flera adresser sparas")
            Prov.lika(sparad?.telefon.first, "070-1234567", "telefonnumret sparas")

            let not = try! String(contentsOf: kund.kontaktmapp.appending(path: "Bo Ek.md"),
                                  encoding: .utf8)
            Prov.kolla(not.contains("roll: \"Inköpschef\""), "uppgifterna hamnar i frontmatter")
            Prov.kolla(not.contains("  - bo@acme.se"), "adresserna listas i frontmatter")
        }

        do {   // egna anteckningar i noten överlever en uppdatering
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            try! arkiv.läggTill(Kontakt(namn: "Cecilia Nord"), hos: kund)

            let not = kund.kontaktmapp.appending(path: "Cecilia Nord.md")
            var text = try! String(contentsOf: not, encoding: .utf8)
            text += "\nGillar att prata om segling. Ringer helst på förmiddagen.\n"
            try! text.write(to: not, atomically: true, encoding: .utf8)

            var c = arkiv.kontakter(för: kund).first!
            c.epost = ["cecilia@acme.se"]
            try! arkiv.uppdatera(c, hos: kund)

            let efter = try! String(contentsOf: not, encoding: .utf8)
            Prov.kolla(efter.contains("Gillar att prata om segling"),
                       "egna anteckningar skrivs inte över när uppgifter uppdateras")
            Prov.kolla(efter.contains("cecilia@acme.se"), "och de nya uppgifterna kommer med")
        }

        do {   // namnbyte
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            try! arkiv.läggTill(Kontakt(namn: "Eva Berg"), hos: kund)

            var eva = arkiv.kontakter(för: kund).first!
            eva.namn = "Eva Berg-Lund"
            try! arkiv.uppdatera(eva, hos: kund)

            let fm = FileManager.default
            Prov.kolla(fm.fileExists(atPath: kund.kontaktmapp.appending(path: "Eva Berg-Lund.md").path),
                       "noten följer med vid namnbyte")
            Prov.kolla(!fm.fileExists(atPath: kund.kontaktmapp.appending(path: "Eva Berg.md").path),
                       "den gamla noten lämnas inte kvar föräldralös")
            Prov.lika(arkiv.kontakter(för: kund).count, 1, "namnbyte skapar ingen dubblett")
        }

        do {   // frontmatter
            Prov.lika(Arkivet.utanFrontmatter("---\ntyp: kontakt\n---\n\n# Anna\n"),
                      "\n# Anna\n", "frontmatter skalas bort")
            Prov.lika(Arkivet.utanFrontmatter("# Anna\n"), "# Anna\n",
                      "filer utan frontmatter lämnas orörda")
            Prov.lika(Arkivet.utanFrontmatter("---\ntrasig utan slut\n"),
                      "---\ntrasig utan slut\n",
                      "en frontmatter utan avslutning rörs inte")
        }
    }

    // MARK: - Mail

    static func mailen() {
        Prov.svit("Mail")

        do {   // tolkning av svaret
            let d = "\u{1F}"
            let rader = [
                "Tuesday, 18 August 2026 at 00:49:37\(d)\"Acme AB\" <faktura@acme.se>\(d)Faktura 1234\(d)<abc@acme.se>\(d)anders@exempel.se\(d)INBOX\(d)från",
                "Monday, 17 August 2026 at 09:00:00\(d)Anna <anna@acme.se>\(d)Re: Offert | version 2\(d)<def@acme.se>\(d)anders@exempel.se\(d)INBOX\(d)från",
            ].joined(separator: "\n")
            let mejl = Mailen.tolka(rader)
            Prov.lika(mejl.count, 2, "båda raderna tolkas")
            Prov.kolla(!(mejl.first?.skickat ?? true), "mejl ur inkorgen räknas som mottagna")
            Prov.lika(mejl.first?.ämne, "Faktura 1234", "ämnet kommer med")
            Prov.lika(mejl.first?.avsändarnamn, "Acme AB", "namnet plockas ur avsändaren")
            Prov.lika(mejl.first?.avsändaradress, "faktura@acme.se", "adressen plockas ur avsändaren")
            Prov.kolla(mejl.contains { $0.ämne == "Re: Offert | version 2" },
                       "ämnen med rörtecken överlever, därav ASCII 31 som avgränsare")
            Prov.kolla((mejl.first?.datum ?? .distantPast) > (mejl.last?.datum ?? .distantFuture),
                       "nyaste mejlet först")
        }

        do {   // datumformatet Mail lämnar
            let d = Mailen.datum(ur: "Tuesday, 18 August 2026 at 00:49:37")
            Prov.kolla(d != nil, "Mails datumsträng går att tolka")
            if let d {
                let delar = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
                Prov.lika(delar.year, 2026, "rätt år")
                Prov.lika(delar.month, 8, "rätt månad")
                Prov.lika(delar.day, 18, "rätt dag")
            }
            Prov.kolla(Mailen.datum(ur: "skräp") == nil, "skräp ger nil i stället för fel datum")
        }

        do {   // riktning
            let d = "\u{1F}"
            let rader = [
                "Monday, 3 August 2026 at 09:00:00\(d)Anders <anders@exempel.se>\(d)Re: Offert\(d)<a@x>\(d)anders@exempel.se\(d)Sent Messages\(d)till",
                "Monday, 3 August 2026 at 08:00:00\(d)Anna <anna@acme.se>\(d)Offert\(d)<b@x>\(d)anders@exempel.se\(d)INBOX\(d)fran",
            ].joined(separator: "\n")
            let mejl = Mailen.tolka(rader)
            Prov.lika(mejl.count, 2, "både mottaget och skickat tolkas")
            Prov.kolla(mejl.first?.skickat == true, "det jag skickat känns igen som skickat")
            Prov.kolla(mejl.last?.skickat == false, "det jag fått räknas inte som skickat")
        }

        do {   // cache
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            Prov.kolla(arkiv.mailcache(för: kund) == nil, "ingen cache från början")

            let d = "\u{1F}"
            let mejl = Mailen.tolka(
                "Monday, 3 August 2026 at 09:00:00\(d)Anna <anna@acme.se>\(d)Offert\(d)<a@x>\(d)konto\(d)INBOX\(d)fran")
            try! arkiv.sparaMail(mejl, för: kund)

            let cache = arkiv.mailcache(för: kund)
            Prov.lika(cache?.mejl.count, 1, "mejlen finns kvar efter omstart")
            Prov.lika(cache?.mejl.first?.ämne, "Offert", "med ämnet i behåll")
            Prov.kolla(cache?.färsk == true, "en nyss hämtad cache räknas som färsk")

            let gammal = Arkivet.Mailcache(hämtad: Date().addingTimeInterval(-3600), mejl: mejl)
            Prov.kolla(!gammal.färsk, "en timme gammal cache hämtas om")

            let not = try! String(contentsOf: kund.mailmapp.appending(path: "Mail.md"),
                                  encoding: .utf8)
            Prov.kolla(not.contains("Offert"), "korrespondensen skrivs till Obsidian")
            Prov.kolla(not.contains("[[Acme]]"), "med länk till kunden")
        }

        do {   // trasiga rader
            Prov.lika(Mailen.tolka("").count, 0, "tomt svar ger inga mejl")
            Prov.lika(Mailen.tolka("bara en text utan fält").count, 0, "rader utan fält hoppas över")
            // Äldre rader utan riktningsfält ska inte falla
            let utanRiktning = "Monday, 3 August 2026 at 08:00:00\u{1F}A <a@x.se>\u{1F}Ämne\u{1F}<b@x>\u{1F}konto\u{1F}INBOX"
            Prov.lika(Mailen.tolka(utanRiktning).count, 1, "rader utan riktningsfält tolkas ändå")
        }
    }

    // MARK: - Röstanalys

    static func röster() {
        Prov.svit("Röstanalys")

        func y(_ start: Double, _ slut: Double, _ text: String = "text") -> Yttrande {
            Yttrande(röst: .motpart, text: text, start: start, slut: slut)
        }

        do {   // turbyggande
            let turer = Röstanalys.turer(av: [
                y(0, 3), y(3.2, 6),          // 0,2 s paus — samma tur
                y(9, 12), y(12.1, 15),       // 3 s paus bryter, sedan ihop igen
            ])
            Prov.lika(turer.count, 2, "korta pauser håller ihop turen, långa bryter")
            Prov.lika(turer.first?.start, 0, "turen börjar vid första yttrandet")
            Prov.lika(turer.first?.slut, 6, "och slutar vid det sista före pausen")
        }

        do {   // för korta turer sållas bort
            let turer = Röstanalys.turer(av: [y(0, 0.8), y(5, 9)])
            Prov.lika(turer.count, 1, "turer under \(Tröskel.minstaTurLängd) s kastas")
            Prov.lika(turer.first?.längd, 4, "den långa blir kvar")
        }

        do {   // taket bryter långa turer
            var rader: [Yttrande] = []
            for i in 0..<20 { rader.append(y(Double(i) * 2, Double(i) * 2 + 1.9)) }
            let turer = Röstanalys.turer(av: rader, tak: 12)
            Prov.kolla(turer.allSatisfy { $0.längd <= 13 },
                       "ingen tur blir längre än taket och hinner blanda in nästa person")
            Prov.kolla(turer.count > 1, "den långa monologen delas upp (\(turer.count) turer)")
        }

        do {   // trösklarna följer längden
            Prov.kolla(Tröskel.samma(sekunder: 2) < Tröskel.samma(sekunder: 10),
                       "kort ljud kräver lägre tröskel än långt")
            Prov.kolla(Tröskel.namnge(sekunder: 5) > Tröskel.samma(sekunder: 5),
                       "att sätta namn kräver mer säkerhet än att bunta ihop")
            Prov.kolla(Tröskel.sammaGrupp(sekunder: 30) > Tröskel.samma(sekunder: 30),
                       "andra rundan är strängare, annars slås lika röster ihop")
        }

        do {   // avtryck och likhet
            let a = Avtryck(vektor: [1, 0, 0], sekunder: 5)
            let b = Avtryck(vektor: [1, 0, 0], sekunder: 5)
            let c = Avtryck(vektor: [0, 1, 0], sekunder: 5)
            Prov.lika(a.likhet(b), 1.0, "identiska avtryck ger likhet 1")
            Prov.lika(a.likhet(c), 0.0, "vinkelräta avtryck ger 0")
            Prov.lika(a.likhet(Avtryck(vektor: [1, 0], sekunder: 5)), 0.0,
                      "olika längd ger 0 i stället för att krascha")
        }

        do {   // profiler
            var p = Röstprofil(namn: "Anna", avtryck: [Avtryck(vektor: [1, 0, 0], sekunder: 5)],
                               uppdaterad: Date(), samtal: 1)
            Prov.lika(p.likhet(Avtryck(vektor: [1, 0, 0], sekunder: 5)), 1.0, "profilen känner igen sig själv")
            p.lärDig(Avtryck(vektor: [0, 1, 0], sekunder: 9))
            Prov.lika(p.avtryck.count, 2, "profilen lär sig nya avtryck")
            Prov.lika(p.likhet(Avtryck(vektor: [0, 1, 0], sekunder: 5)), 1.0,
                      "bästa träffen räknas, inte medelvärdet")
            for i in 0..<12 { p.lärDig(Avtryck(vektor: [0, 0, 1], sekunder: Double(i))) }
            Prov.kolla(p.avtryck.count <= 8, "profilen växer inte i all oändlighet (\(p.avtryck.count))")
            Prov.kolla(p.avtryck.contains { $0.sekunder == 9 }, "de längsta avtrycken behålls vid gallring")
        }

        do {   // gruppering
            func a(_ v: [Float], _ s: Double) -> Avtryck { Avtryck(vektor: v, sekunder: s) }
            let t1 = Röstanalys.Tur(start: 0, slut: 8, text: "en")
            let t2 = Röstanalys.Tur(start: 10, slut: 18, text: "två")
            let t3 = Röstanalys.Tur(start: 20, slut: 28, text: "tre")
            // Två nästan identiska röster och en helt annan
            let nära1: [Float] = [1, 0, 0]
            let nära2: [Float] = [0.99, 0.14, 0]
            let annan: [Float] = [0, 0, 1]
            let grupper = Röstanalys.gruppera([(t1, a(nära1, 8)), (t2, a(nära2, 8)), (t3, a(annan, 8))])
            Prov.lika(grupper.count, 2, "lika röster buntas ihop, olika hålls isär")
            Prov.kolla(grupper.first?.turer.count == 2, "den största gruppen har de två lika")
        }

        do {   // var kedjan klipps
            // Likheten faller monotont när grupper slås ihop. Det största
            // fallet är övergången från samma person till olika.
            //            5      4      3      2      1
            let kedja = [0.82, 0.78, 0.73, 0.40, -Double.infinity]
            Prov.lika(Röstanalys.klippställe(kedja), 3,
                      "klipper där likheten faller mest")

            // Ett jämnt fall utan tydlig gräns
            Prov.kolla(Röstanalys.klippställe([0.8, 0.7, 0.6, 0.5, -Double.infinity]) >= 0,
                       "en jämn kedja ger ändå ett svar")
            Prov.lika(Röstanalys.klippställe([0.5]), 0, "en kedja med ett läge klipps först")
            Prov.lika(Röstanalys.klippställe([]), 0, "tom kedja kraschar inte")
        }

        do {   // långa turer blir kärnor
            func p(_ längd: Double, _ v: [Float]) -> (Röstanalys.Tur, Avtryck) {
                (Röstanalys.Tur(start: 0, slut: längd, text: ""),
                 Avtryck(vektor: v, sekunder: längd))
            }
            let (kärnor, korta) = Röstanalys.delaEfterLängd([
                p(20, [1, 0, 0]), p(18, [0, 1, 0]),      // långa
                p(2, [1, 0, 0]), p(3, [0, 1, 0]), p(2.5, [1, 0, 0]),   // korta
            ])
            Prov.kolla(kärnor.allSatisfy { $0.0.längd >= Tröskel.minstaKärnlängd },
                       "bara långa turer blir kärnor")
            Prov.kolla(korta.allSatisfy { $0.0.längd < 20 }, "de korta hamnar i resten")
            Prov.kolla(kärnor.count >= 1 && korta.count >= 3,
                       "uppdelningen ger både kärnor och rester (\(kärnor.count)/\(korta.count))")
        }

        do {   // korta turer hamnar hos rätt röst i stället för att bli egna
            func p(_ start: Double, _ längd: Double, _ v: [Float]) -> (Röstanalys.Tur, Avtryck) {
                (Röstanalys.Tur(start: start, slut: start + längd, text: ""),
                 Avtryck(vektor: v, sekunder: längd))
            }
            let a: [Float] = [1, 0, 0]
            let b: [Float] = [0, 1, 0]
            // Två tydliga röster i långa turer, plus fem korta inpass
            let grupper = Röstanalys.gruppera([
                p(0, 20, a), p(30, 18, b), p(60, 16, a), p(90, 15, b),
                p(120, 2, a), p(125, 3, b), p(130, 2, a), p(135, 2.5, b), p(140, 2, a),
            ], väntade: 2)
            Prov.lika(grupper.count, 2,
                      "korta inpass blir inte egna röster (\(grupper.count) grupper)")
            Prov.lika(grupper.reduce(0) { $0 + $1.turer.count }, 9,
                      "alla turer kommer med någonstans")
        }

        do {   // väntat antal styr
            func p(_ v: [Float]) -> (Röstanalys.Tur, Avtryck) {
                (Röstanalys.Tur(start: 0, slut: 12, text: ""), Avtryck(vektor: v, sekunder: 12))
            }
            let par = [p([1, 0, 0]), p([0.98, 0.2, 0]), p([0, 1, 0]), p([0, 0.98, 0.2]),
                       p([0, 0, 1]), p([0.2, 0, 0.98])]
            Prov.kolla(Röstanalys.gruppera(par, väntade: 3).count <= 3,
                       "ett väntat antal ger inte fler röster än så")
            Prov.kolla(Röstanalys.gruppera(par, väntade: 2).count <= 2,
                       "och håller ihop hårdare när färre väntas")
        }

        do {   // namngivning kräver säkerhet
            let t = Röstanalys.Tur(start: 0, slut: 10, text: "hej")
            let grupper = Röstanalys.gruppera([(t, Avtryck(vektor: [1, 0, 0], sekunder: 10))])
            let profil = Röstprofil(namn: "Anna", avtryck: [Avtryck(vektor: [1, 0, 0], sekunder: 10)],
                                    uppdaterad: Date(), samtal: 1)
            Prov.lika(Röstanalys.namnge(grupper, mot: [profil]).first?.namn, "Anna",
                      "en säker träff får namnet")

            let svag = Röstprofil(namn: "Berit", avtryck: [Avtryck(vektor: [0.5, 0.86, 0], sekunder: 10)],
                                  uppdaterad: Date(), samtal: 1)
            Prov.kolla(Röstanalys.namnge(grupper, mot: [svag]).first?.namn == nil,
                       "en osäker träff lämnas namnlös hellre än att gissa fel")
        }

        do {   // två grupper får inte samma namn
            let t1 = Röstanalys.Tur(start: 0, slut: 10, text: "en")
            let t2 = Röstanalys.Tur(start: 30, slut: 40, text: "två")
            let g = [Röstanalys.Röstgrupp(turer: [t1], avtryck: [Avtryck(vektor: [1, 0, 0], sekunder: 10)]),
                     Röstanalys.Röstgrupp(turer: [t2], avtryck: [Avtryck(vektor: [0.97, 0.24, 0], sekunder: 10)])]
            let profil = Röstprofil(namn: "Anna", avtryck: [Avtryck(vektor: [1, 0, 0], sekunder: 10)],
                                    uppdaterad: Date(), samtal: 1)
            let ut = Röstanalys.namnge(g, mot: [profil])
            Prov.lika(ut.filter { $0.namn == "Anna" }.count, 1,
                      "samma person sätts bara på en grupp")
        }

        do {   // tilldelning enligt diarisering
            func t(_ start: Double, _ slut: Double) -> Röstanalys.Tur {
                Röstanalys.Tur(start: start, slut: slut, text: "")
            }
            let turer = [t(0, 10), t(12, 20), t(25, 35), t(40, 45)]
            let segment = [
                Röstanalys.Talarsegment(start: 0, slut: 11, talare: "A"),
                Röstanalys.Talarsegment(start: 11, slut: 22, talare: "B"),
                Röstanalys.Talarsegment(start: 22, slut: 36, talare: "A"),
                Röstanalys.Talarsegment(start: 36, slut: 50, talare: "B"),
            ]
            let grupper = Röstanalys.gruppera(turer: turer, avtryck: [:], enligt: segment)
            Prov.lika(grupper.count, 2, "två talare ger två grupper")
            // A talar 0–10 och 25–35, alltså 20 s; B talar 12–20 och 40–45, 13 s
            Prov.lika(grupper.first?.turer.count, 2, "största gruppen har sina två turer")
            Prov.kolla(grupper.allSatisfy { $0.turer.count == 2 },
                       "turerna fördelas efter var de överlappar mest")

            // En tur som spänner över en talarväxling hamnar hos den som har mest
            let delad = Röstanalys.gruppera(
                turer: [t(8, 16)], avtryck: [:], enligt: segment)
            Prov.lika(delad.count, 1, "en tur hamnar hos en enda talare")
            Prov.lika(delad.first?.turer.count, 1, "och tas inte bort")

            Prov.lika(Röstanalys.gruppera(turer: turer, avtryck: [:], enligt: []).count, 0,
                      "utan segment blir det inga grupper")
        }

        do {   // etiketter och lagring
            var y1 = Yttrande(röst: .motpart, text: "hej", start: 0, slut: 2)
            y1.röstgrupp = 0
            Prov.lika(y1.etikett([:]), "Röst 1", "namnlös grupp visas med nummer")
            Prov.lika(y1.etikett([0: "Anna"]), "Anna", "namngiven grupp visar namnet")
            let mitt = Yttrande(röst: .jag, text: "hej", start: 0, slut: 2)
            Prov.lika(mitt.etikett([0: "Anna"]), "Jag", "mitt eget spår är alltid jag")
        }

        do {   // profiler sparas per kund
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let a = try! arkiv.skapaKund(namn: "Acme")
            let b = try! arkiv.skapaKund(namn: "Beta")
            try! arkiv.lärDigRöst(namn: "Anna", avtryck: Avtryck(vektor: [1, 0, 0], sekunder: 6), hos: a)
            Prov.lika(arkiv.röstprofiler(för: a).count, 1, "profilen sparas hos kunden")
            Prov.lika(arkiv.röstprofiler(för: b).count, 0, "och läcker inte till andra kunder")
            try! arkiv.lärDigRöst(namn: "Anna", avtryck: Avtryck(vektor: [0, 1, 0], sekunder: 7), hos: a)
            let p = arkiv.röstprofiler(för: a).first
            Prov.lika(p?.avtryck.count, 2, "ett andra samtal lägger till ett avtryck")
            Prov.lika(p?.samtal, 2, "antalet samtal räknas upp")
        }
    }

    // MARK: - Arkivet

    private static func tillfälligt() -> (Arkivet, URL) {
        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        return (Arkivet(rot: rot), rot)
    }

    static func arkivet() {
        Prov.svit("Arkivet")
        let fm = FileManager.default

        do {   // mappstruktur och vault
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Åkessons Bygg AB")
            Prov.kolla(fm.fileExists(atPath: kund.projektmapp.path), "kunden får mappen Projekt")
            Prov.kolla(fm.fileExists(atPath: kund.samtalsmapp.path), "kunden får mappen Samtal")
            Prov.kolla(fm.fileExists(atPath: kund.kontaktmapp.path), "kunden får mappen Kontakter")
            Prov.kolla(fm.fileExists(atPath: kund.mailmapp.path), "kunden får mappen Mail")
            Prov.kolla(fm.fileExists(atPath: kund.mapp.appending(path: ".obsidian/app.json").path),
                       "mappen blir en Obsidian-vault")
            Prov.kolla(fm.fileExists(atPath: kund.mapp.appending(path: "Åkessons Bygg AB.md").path),
                       "vaultet får en ingångsnot")
        }

        do {   // svenska tecken
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Ängsö Trä & Rör")
            arkiv.läsOm()
            Prov.kolla(arkiv.kunder.contains { $0.namn == "Ängsö Trä & Rör" },
                       "å ä ö överlever vägen till disk och tillbaka")
            let md = try! String(contentsOf: kund.mapp.appending(path: "Ängsö Trä & Rör.md"), encoding: .utf8)
            Prov.kolla(md.contains("Ängsö Trä & Rör"), "å ä ö överlever i markdown")
        }

        do {   // farliga tecken
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Före/Efter AB")
            Prov.kolla(!kund.namn.contains("/"), "snedstreck skapar inte oavsiktliga undermappar")
            Prov.kolla(fm.fileExists(atPath: kund.mapp.path), "kunden skapas ändå")
        }

        do {   // läser det som skapats för hand
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let förHand = rot.appending(path: "Handgjord AB/Projekt/Ombyggnad")
            try! fm.createDirectory(at: förHand, withIntermediateDirectories: true)
            arkiv.läsOm()
            let kund = arkiv.kunder.first { $0.namn == "Handgjord AB" }
            Prov.kolla(kund != nil, "kund skapad i Finder syns i appen")
            if let kund {
                Prov.lika(arkiv.projekt(för: kund).map(\.namn), ["Ombyggnad"],
                          "projekt skapat i Finder syns också")
            }
        }

        do {   // namnkollisioner
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let nu = Date()
            let a = try! arkiv.nyInspelningsmapp(placering: .kund(kund), titel: "Avstämning", datum: nu)
            let b = try! arkiv.nyInspelningsmapp(placering: .kund(kund), titel: "Avstämning", datum: nu)
            Prov.kolla(a != b, "två inspelningar samma minut skriver inte över varandra")
        }

        do {   // spara och läsa tillbaka
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Acme")
            _ = try! arkiv.skapaProjekt(namn: "Nytt lager", hos: kund)
            let mapp = try! arkiv.nyInspelningsmapp(placering: .kund(kund), titel: "Uppstart", datum: Date())
            let inspelning = Inspelning(
                titel: "Uppstart", inledd: Date(), längd: 92.5,
                kund: "Acme", projekt: "Nytt lager", mikrofon: "MacBook Pro-mikrofon",
                liveYttranden: [
                    Yttrande(röst: .jag, text: "Hej, hur går det med lagret?", start: 0, slut: 3),
                    Yttrande(röst: .motpart, text: "Det rullar på.", start: 3.2, slut: 5),
                ],
                arkivYttranden: nil)
            try! arkiv.spara(inspelning, i: mapp)

            let tillbaka = arkiv.inspelningar(för: kund)
            Prov.lika(tillbaka.count, 1, "sparad inspelning hittas igen")
            Prov.lika(tillbaka.first?.0.yttranden.count, 2, "alla rader kommer med")

            let md = try! String(contentsOf: mapp.appending(path: "Transkript.md"), encoding: .utf8)
            Prov.kolla(md.contains("[[Acme]]"), "markdown länkar till kunden")
            Prov.kolla(md.contains("[[Nytt lager]]"), "markdown länkar till projektet")
            Prov.kolla(md.contains("**Jag** `00:00`"), "rader får talare och tidsstämpel")
            Prov.kolla(md.contains("Det rullar på."), "texten finns i markdown")
        }

        do {   // kasta en inspelning
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let mapp = try! arkiv.nyInspelningsmapp(placering: .kund(kund),
                                                    titel: "Att kasta", datum: Date())
            let i = Inspelning(titel: "Att kasta", inledd: Date(), längd: 5,
                               kund: "Acme", projekt: nil, mikrofon: nil,
                               liveYttranden: [], arkivYttranden: nil)
            try! arkiv.spara(i, i: mapp)
            // Ljudfilerna ska följa med, inte lämnas kvar
            FileManager.default.createFile(atPath: mapp.appending(path: "jag.wav").path,
                                           contents: Data([1, 2, 3]))
            Prov.lika(arkiv.inspelningar(för: kund).count, 1, "inspelningen finns")

            try! arkiv.kastaInspelning(i: mapp)
            Prov.lika(arkiv.inspelningar(för: kund).count, 0, "den försvinner ur listan")
            Prov.kolla(!FileManager.default.fileExists(atPath: mapp.path),
                       "hela mappen är borta, med ljud och transkript")
        }

        do {   // arkiv går före live
            var i = Inspelning(titel: "T", inledd: Date(), längd: 10, kund: "K", projekt: nil, mikrofon: nil,
                               liveYttranden: [Yttrande(röst: .jag, text: "live", start: 0, slut: 1)],
                               arkivYttranden: nil)
            Prov.lika(i.yttranden.first?.text, "live", "live-transkriptet visas innan efterbearbetning")
            i.arkivYttranden = [Yttrande(röst: .jag, text: "arkiv", start: 0, slut: 1)]
            Prov.lika(i.yttranden.first?.text, "arkiv", "arkivtranskriptet tar över när det finns")
            Prov.kolla(i.efterbearbetad, "inspelningen räknas som efterbearbetad")
        }
    }

    // MARK: - Ljud

    static func ljud() {
        Prov.svit("Ljud")

        func u32(_ d: Data, _ o: Int) -> UInt32 { d[o..<o+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ d: Data, _ o: Int) -> UInt16 { d[o..<o+2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func i16(_ d: Data, _ o: Int) -> Int16 { d[o..<o+2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) } }

        do {   // WAV-huvud
            let d = Wav.data(av: [Float](repeating: 0.5, count: 16_000))
            Prov.lika(d.count, 44 + 32_000, "WAV får rätt total storlek")
            Prov.lika(String(data: d[0..<4], encoding: .ascii), "RIFF", "filen inleds med RIFF")
            Prov.lika(String(data: d[8..<12], encoding: .ascii), "WAVE", "formatet är WAVE")
            Prov.lika(u16(d, 20), 1, "kodningen är PCM")
            Prov.lika(u16(d, 22), 1, "ljudet är mono")
            Prov.lika(u32(d, 24), 16_000, "frekvensen är 16 kHz, som whisper vill ha")
            Prov.lika(u16(d, 34), 16, "provdjupet är 16 bitar")
            Prov.lika(u32(d, 40), 32_000, "datalängden stämmer")
        }

        do {   // klippning
            let d = Wav.data(av: [2.0, -2.0])
            Prov.lika(i16(d, 44), 32767, "för höga prov klipps i stället för att vika runt")
            Prov.lika(i16(d, 46), -32767, "detsamma åt andra hållet")
        }

        do {   // spårskrivaren
            let fil = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: fil) }
            let s = try! Spårskrivare(fil: fil)
            s.skriv([Float](repeating: 0.1, count: 8_000))
            s.skriv([Float](repeating: 0.1, count: 8_000))
            s.stäng()
            let d = try! Data(contentsOf: fil)
            Prov.lika(u32(d, 40), 32_000, "huvudets datalängd lagas när filen stängs")
            Prov.lika(u32(d, 4), UInt32(36 + 32_000), "RIFF-längden lagas också")
            let ljud = try! AVAudioFile(forReading: fil)
            Prov.lika(ljud.length, 16_000, "filen går att öppna som ljud, inte bara se rätt ut")
            Prov.lika(ljud.fileFormat.sampleRate, 16_000, "med rätt frekvens")
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        // Testljudet ska likna tal, inte en konstant nivå. Det var just en
        // konstant som förde kalibreringen vilse en gång: en syntetisk fil med
        // tal på RMS 0,2 gav trösklar som slängde allt den inbyggda
        // mikrofonen spelade in, där tal ligger på 0,005–0,016.
        var frö: UInt64 = 12345
        func slump() -> Float {
            frö = frö &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: frö >> 33)) / Float(Int32.max)
        }
        /// En bit ljud på ungefär `nivå` i RMS ovanpå en bakgrund. Ljudet
        /// pulserar i stavelsetakt, som tal gör: det är i pauserna mellan
        /// orden bakgrunden går att se.
        var stavelse = 0
        func ram(_ nivå: Float, _ sekunder: Double, _ tid: Double,
                 bakgrund: Float = 0.0003) -> Ljudram {
            let antal = AVAudioFrameCount(16_000 * sekunder)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: antal)!
            buf.frameLength = antal
            let period = 16_000 / 45 * 10          // ~4,5 stavelser i sekunden
            for i in 0..<Int(antal) {
                stavelse = (stavelse + 1) % period
                let ljudande = Double(stavelse) < Double(period) * 0.65
                let n = ljudande ? nivå * 1.25 : 0
                buf.floatChannelData![0][i] = slump() * (n * 1.7) + slump() * bakgrund * 1.7
            }
            return Ljudram(röst: .jag, buffert: buf, tid: tid)
        }
        func tystnad(_ sekunder: Double, _ tid: Double) -> Ljudram {
            ram(0, sekunder, tid, bakgrund: 0)
        }

        do {   // tystnad stänger fönstret
            let b = Ljudbuffring()
            Prov.kolla(b.mata(ram(0.05, 1.0, 0)).fönster == nil, "tal håller fönstret öppet")
            Prov.kolla(b.mata(ram(0.05, 1.0, 1)).fönster == nil, "fortsatt tal håller det öppet")
            let f = b.mata(tystnad(0.8, 2)).fönster
            Prov.kolla(f != nil, "tystnad längre än 0,6 s stänger fönstret")
            if let f {
                Prov.lika(f.prov.count, 16_000 * 28 / 10, "fönstret innehåller allt ljud fram till tystnaden")
                Prov.lika(f.start, 0, "fönstret börjar där talet började")
            }
        }

        do {   // ett köat pass utgår från mötet som det ligger på disk
            // Uppmätt: en import och en «Transkribera om» på samma mapp låg i
            // kön samtidigt. Omkörningen bar med sig stillbilden från köandet
            // — mötet innan importen skrivit något — och skrev över det
            // färdiga transkriptet redan på sin första rad.
            let mapp = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: mapp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: mapp) }
            func skriv(_ i: Inspelning) {
                try! JSONEncoder.kundkoll.encode(i).write(to: mapp.appending(path: "möte.json"))
            }
            let id = UUID()
            let tomt = Inspelning(id: id, titel: "ai", inledd: Date(), längd: 60,
                                  kund: "parti", projekt: nil, mikrofon: nil,
                                  liveYttranden: [], arkivYttranden: nil)

            Prov.lika(Efterbearbetning.utgångspunkt(tomt, mapp: mapp).id, tomt.id,
                      "utan möte.json gäller den som skickades med")

            var färdigt = tomt
            färdigt.arkivYttranden = [Yttrande(röst: .motpart, text: "Det här är Ekot",
                                               start: 0, slut: 2)]
            skriv(färdigt)
            Prov.lika(Efterbearbetning.utgångspunkt(tomt, mapp: mapp).arkivYttranden?.count, 1,
                      "det som hunnit skrivas på disk vinner över stillbilden")

            let annat = Inspelning(id: UUID(), titel: "annat möte", inledd: Date(), längd: 60,
                                   kund: "parti", projekt: nil, mikrofon: nil,
                                   liveYttranden: [], arkivYttranden: nil)
            Prov.lika(Efterbearbetning.utgångspunkt(annat, mapp: mapp).id, annat.id,
                      "men bara när det är samma möte")
        }

        do {   // ett nytt möte börjar om från noll
            // Buffringen lever lika länge som inspelningssessionen, alltså
            // hela appstarten, och tiderna räknas ur antalet matade prov.
            // Uppmätt: ett möte som spelades in efter ett annat på 1782
            // sekunder fick alla sina livetider 1782 sekunder för sent —
            // bortom slutet på sitt eget ljud.
            let b = Ljudbuffring()
            _ = b.mata(ram(0.05, 1.0, 0))
            _ = b.mata(ram(0.05, 1.0, 1))
            _ = b.mata(tystnad(0.8, 2))
            _ = b.spola()

            _ = b.mata(ram(0.05, 1.0, 0))
            _ = b.mata(ram(0.05, 1.0, 1))
            let utan = b.mata(tystnad(0.8, 2)).fönster
            Prov.kolla((utan?.start ?? 0) > 2,
                       "utan nollställning fortsätter räkningen från förra mötet")

            b.nollställ()
            _ = b.mata(ram(0.05, 1.0, 0))
            _ = b.mata(ram(0.05, 1.0, 1))
            let efter = b.mata(tystnad(0.8, 2)).fönster
            Prov.kolla(efter != nil, "fönstret stängs som vanligt efter nollställningen")
            Prov.lika(efter?.start ?? -1, 0, "och det nya mötet börjar på noll")
        }

        do {   // maxlängd
            let b = Ljudbuffring()
            var fönster: Ljudbuffring.Fönster?
            for i in 0..<20 where fönster == nil {
                fönster = b.mata(ram(0.05, 1.0, Double(i))).fönster
            }
            Prov.kolla(fönster != nil, "den som talar oavbrutet får ändå text")
            if let f = fönster {
                Prov.lika(f.prov.count, 16_000 * 15, "senast efter 15 sekunder")
            }
        }

        do {   // tysta fönster skickas inte vidare
            let b = Ljudbuffring()
            // Ett helt tyst fönster: whisper skulle hitta på text ur det
            var fönster: Ljudbuffring.Fönster?
            for i in 0..<20 where fönster == nil {
                fönster = b.mata(tystnad(1.0, Double(i))).fönster
            }
            Prov.kolla(fönster == nil, "ett tyst fönster skickas aldrig till whisper")

            // Svagt jämnt brus — nivån är mätt ur kalibreringsfilen — ska
            // inte heller nå fram.
            let c = Ljudbuffring()
            var brusfönster: Ljudbuffring.Fönster?
            for i in 0..<20 where brusfönster == nil {
                brusfönster = c.mata(ram(0, 1.0, Double(i), bakgrund: 0.0017)).fönster
            }
            Prov.kolla(brusfönster == nil, "svagt brus räknas inte som tal")

            // Ett rum som brusar starkt ska inte heller göra bruset till tal.
            let e = Ljudbuffring()
            var rumsfönster: Ljudbuffring.Fönster?
            for i in 0..<30 where rumsfönster == nil {
                rumsfönster = e.mata(ram(0, 1.0, Double(i), bakgrund: 0.02)).fönster
            }
            Prov.kolla(rumsfönster == nil, "ett brusigt rum räknas inte heller som tal")
        }

        do {   // samma tal, olika inspelningsnivåer
            // Det här är felet som fanns: mikrofonspåret låg på RMS 0,006 och
            // en fast tröskel slängde varenda fönster, medan datorljudet på
            // 0,2 gick igenom. Detekteringen ska klara hela spannet.
            for nivå in [Float(0.004), 0.006, 0.02, 0.06, 0.2] {
                let b = Ljudbuffring()
                var f: Ljudbuffring.Fönster?
                for i in 0..<4 where f == nil {
                    f = b.mata(ram(nivå, 1.0, Double(i))).fönster
                }
                if f == nil { f = b.mata(tystnad(0.8, 4)).fönster }
                Prov.kolla(f != nil, "tal på RMS \(nivå) släpps igenom")
            }
        }

        do {   // mätaren
            let b = Ljudbuffring()
            _ = b.mata(ram(0.012, 0.5, 0))
            Prov.kolla(b.senasteNivå > 0.3,
                       "mätaren rör sig på tal från den inbyggda mikrofonen (\(b.senasteNivå))")
            let c = Ljudbuffring()
            _ = c.mata(tystnad(0.5, 0))
            Prov.kolla(c.senasteNivå < 0.1, "men ligger stilla vid tystnad (\(c.senasteNivå))")
        }

        do {   // spelaren: spåren och raden som hörs
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            try! FileManager.default.createDirectory(at: rot, withIntermediateDirectories: true)
            try! Wav.data(av: []).write(to: rot.appending(path: "jag.wav"))
            try! Wav.data(av: []).write(to: rot.appending(path: "motpart.wav"))
            Prov.lika(Yttrandespelare.spår(i: rot, enspårig: false).map(\.lastPathComponent),
                      ["jag.wav", "motpart.wav"], "en tvåspårig inspelning spelar båda spåren")
            Prov.lika(Yttrandespelare.spår(i: rot, enspårig: true).map(\.lastPathComponent),
                      ["motpart.wav"], "i en importerad fil ligger allt i motpart.wav")

            let a = Yttrande(röst: .jag, text: "a", start: 0, slut: 2)
            let b = Yttrande(röst: .motpart, text: "b", start: 2.5, slut: 5)
            let c = Yttrande(röst: .jag, text: "c", start: 7, slut: 9)
            let rader = [a, b, c]
            Prov.lika(Yttrandespelare.rad(vid: 1, i: rader), a.id, "raden som pågår hörs")
            Prov.lika(Yttrandespelare.rad(vid: 2.2, i: rader), a.id,
                      "i pausen mellan två rader hålls den förra kvar")
            Prov.lika(Yttrandespelare.rad(vid: 6, i: rader), b.id, "och den senast påbörjade vinner")
            Prov.lika(Yttrandespelare.rad(vid: 8, i: rader), c.id, "fram till nästa")
            Prov.kolla(Yttrandespelare.rad(vid: -1, i: rader) == nil, "före första raden hörs ingen")
        }

        do {   // nedräkning
            // Omräknaren har en intern fördröjning och håller tillbaka en bit
            // av första bufferten. Det som spelar roll är att inget försvinner
            // över tid, så mät summan över flera bitar i stället för en enda.
            let b = Ljudbuffring()
            let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            var summa = 0
            for s in 0..<5 {
                let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 48_000)!
                buf.frameLength = 48_000
                for k in 0..<2 { for i in 0..<48_000 { buf.floatChannelData![k][i] = 0.2 } }
                let (mono, _) = b.mata(Ljudram(röst: .motpart, buffert: buf, tid: Double(s)))
                summa += mono.count
            }
            // Fem sekunder in ska ge fem sekunder ut, på en bråkdel av en sekund när.
            Prov.kolla(abs(summa - 5 * 16_000) < 1_100,
                       "48 kHz stereo blir 16 kHz mono utan att ljud tappas (\(summa) av 80 000 prov)")
        }
    }

    // MARK: - Mötesserier

    static func mötesserier() {
        Prov.svit("Mötesserier")

        Prov.lika(Mötesserie.nyckel("magnus 1on1 20260901"), "magnus on",
                  "siffror och datum plockas bort ur nyckeln")
        Prov.lika(Mötesserie.nyckel("Magnus 1on1 20261001"), "magnus on",
                  "så att nästa möte i serien får samma")
        Prov.lika(Mötesserie.nyckel("Avstämning – vecka 36"), "avstämning vecka",
                  "skiljetecken spelar ingen roll")
        Prov.lika(Mötesserie.nyckel("20260901"), "", "bara siffror ger ingen nyckel")

        func möte(_ titel: String, _ dag: String) -> (Inspelning, URL) {
            (Inspelning(titel: titel, inledd: Uppgift.dag(dag)!, längd: 60, kund: "Acme",
                        projekt: nil, mikrofon: nil, liveYttranden: [], arkivYttranden: nil),
             URL(fileURLWithPath: "/x/\(titel)"))
        }
        let a = möte("magnus 1on1 20260801", "2026-08-01")
        let b = möte("magnus 1on1 20260901", "2026-09-01")
        let c = möte("Styrgrupp", "2026-08-15")
        let d = möte("magnus 1on1 20260701", "2026-07-01")
        let alla = [a, b, c, d]

        Prov.lika(Mötesserie.föregående(b.0, bland: alla)?.0.id, a.0.id,
                  "närmast föregående i serien hittas")
        Prov.lika(Mötesserie.föregående(a.0, bland: alla)?.0.id, d.0.id,
                  "och kedjan fortsätter bakåt")
        Prov.lika(Mötesserie.föregående(d.0, bland: alla)?.0.id, nil,
                  "det första mötet har inget före sig")
        Prov.lika(Mötesserie.föregående(c.0, bland: alla)?.0.id, nil,
                  "ett möte utanför serien hör inte hit")

        let siffror = möte("20260901", "2026-09-01")
        Prov.lika(Mötesserie.föregående(siffror.0, bland: alla + [möte("20260801", "2026-08-01")])?.0.id,
                  nil, "titlar av bara siffror kedjas aldrig")
    }

    // MARK: - Kontaktbilder

    static func kontaktbilder() {
        Prov.svit("Kontaktbilder")
        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        let kund = try! arkiv.skapaKund(namn: "Acme")
        var k = Kontakt(namn: "Anna Svensson", epost: ["anna@acme.se"])
        try! arkiv.läggTill(k, hos: kund)

        // En liten riktig bild: 4×4 röda pixlar som png.
        let bild = NSImage(size: NSSize(width: 4, height: 4))
        bild.lockFocus(); NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill(); bild.unlockFocus()
        let png = NSBitmapImageRep(data: bild.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!

        try! arkiv.sparaKontaktbild(png, för: &k, hos: kund)
        Prov.kolla(k.bild != nil, "bilden sparas och kontakten pekar på den")
        Prov.kolla(arkiv.kontaktbild(för: k, hos: kund) != nil, "och filen finns")
        Prov.lika(arkiv.kontakter(för: kund).first?.bild, k.bild,
                  "pekaren överlever omläsning")

        try! arkiv.taBortKontaktbild(för: &k, hos: kund)
        Prov.lika(k.bild, nil, "bilden går att ta bort")
        Prov.lika(arkiv.kontaktbild(för: k, hos: kund), nil, "och filen är borta")

        Prov.lika(Bildverktyg.jpegSigill(Data("smör".utf8), sida: 64), nil,
                  "det som inte är en bild ger inget sigill")
        let gammal = try? JSONDecoder.kundkoll.decode(
            Kontakt.self, from: Data(#"{"namn":"Bo Ek"}"#.utf8))
        Prov.lika(gammal?.bild, nil, "kontakter utan bildfält går att läsa")
    }

    // MARK: - Tidsloggen

    static func tid() {
        Prov.svit("Tidsloggen")

        // Längdtolkningen följer hur man faktiskt skriver.
        Prov.lika(Tidspost.tolkaLängd("1:30"), 5400, "kolon är timmar och minuter")
        Prov.lika(Tidspost.tolkaLängd("0:45"), 2700, "även under en timme")
        Prov.lika(Tidspost.tolkaLängd("1,5"), 5400, "decimaler är timmar")
        Prov.lika(Tidspost.tolkaLängd("1.5"), 5400, "med punkt också")
        Prov.lika(Tidspost.tolkaLängd("90"), 5400, "ett naket tal är minuter")
        Prov.lika(Tidspost.tolkaLängd("1:75"), nil, "75 minuter i minutfältet är fel")
        Prov.lika(Tidspost.tolkaLängd("smör"), nil, "text är inte tid")
        Prov.lika(Tidspost.tolkaLängd(""), nil, "tomt är inte tid")

        Prov.lika(Tidspost.längdtext(5400), "1:30", "och skrivs ut på samma form")
        Prov.lika(Tidspost.längdtext(89), "0:01", "korta pass rundas till minuter")

        // Uret: räknar när det går, står stilla pausat, och sovtid räknas bort.
        var p = Tidur.Pågående(kund: "Acme", projekt: "Nytt lager", vad: "Bygger",
                               start: Uppgift.dag("2026-09-02")!)
        let start = p.start
        Prov.lika(p.gången(nu: start.addingTimeInterval(600)), 600,
                  "uret räknar väggtid")
        // Datorn somnar efter 10 minuter: frys där.
        p.ackumulerat += 600
        p.pausad = true
        Prov.lika(p.gången(nu: start.addingTimeInterval(4000)), 600,
                  "pausat ur står stilla hur länge datorn än sover")
        // Vaknar och fortsätter: sovtiden är borta.
        p.senasteStart = start.addingTimeInterval(4000)
        p.pausad = false
        Prov.lika(p.gången(nu: start.addingTimeInterval(4300)), 900,
                  "fortsättningen räknar från uppvaknandet, inte insomningen")

        // Lagringen.
        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        let kund = try! arkiv.skapaKund(namn: "Acme")
        try! arkiv.läggTill(Tidspost(vad: "Byggde hyllor", projekt: "Nytt lager",
                                     sekunder: 5400), för: kund)
        try! arkiv.läggTill(Tidspost(vad: "Möte", projekt: nil, sekunder: 1800), för: kund)
        Prov.lika(arkiv.tidsposter(för: kund).count, 2, "poster går att logga och läsa")
        let md = (try? String(contentsOf: kund.mapp.appending(path: "Tid.md"),
                              encoding: .utf8)) ?? ""
        Prov.kolla(md.contains("Nytt lager · 1:30"), "markdown-loggen summerar per projekt")
        Prov.kolla(md.contains("Byggde hyllor"), "och raderna står där")
        try! arkiv.taBort(arkiv.tidsposter(för: kund).first!, för: kund)
        Prov.lika(arkiv.tidsposter(för: kund).count, 1, "en post går att ta bort")

        // Gamla filer utan nya fält ska gå att läsa.
        let gammal = try? JSONDecoder.kundkoll.decode(
            Tidspost.self,
            from: Data(#"{"vad":"Möte","start":"2026-09-01T09:00:00Z","sekunder":600}"#.utf8))
        Prov.lika(gammal?.vad, "Möte", "en post utan id och projekt går att läsa")
    }

    // MARK: - Lägesbilden

    static func lägesbilden() {
        Prov.svit("Lägesbilden")

        func inspelning(_ titel: String, projekt: String?, dag: String,
                        kärna: String? = nil) -> Inspelning {
            var i = Inspelning(titel: titel, inledd: Uppgift.dag(dag)!, längd: 60,
                               kund: "Acme", projekt: projekt, mikrofon: nil,
                               liveYttranden: [], arkivYttranden: nil)
            if let kärna {
                i.sammanfattning = Mötessammanfattning(kärna: kärna, beslut: ["B"],
                                                       åtaganden: [], öppet: ["Ö"])
            }
            return i
        }
        let underlag = Läget.underlag(
            projekt: "Nytt lager",
            inspelningar: [inspelning("Avstämning", projekt: "Nytt lager",
                                      dag: "2026-08-28", kärna: "Vi kom igång."),
                           inspelning("Annat möte", projekt: nil,
                                      dag: "2026-08-29", kärna: "Hör inte hit.")],
            uppgifter: [Uppgift(vad: "Skicka offerten", senast: Uppgift.dag("2026-08-20"),
                                projekt: "Nytt lager"),
                        Uppgift(vad: "Beställ hyllor till Nytt lager", projekt: nil),
                        Uppgift(vad: "Annan kunds sak", projekt: nil)],
            mejl: [Mailen.Mejl(datum: Uppgift.dag("2026-08-30"), datumText: "",
                               avsändare: "Anna <anna@acme.se>", ämne: "Offert",
                               meddelandeID: "a", konto: "k", låda: "INBOX",
                               riktning: "från", text: "Hur går det med offerten?")],
            anteckningar: [])

        Prov.kolla(underlag.contains { $0.titel.contains("Avstämning") },
                   "projektets möte är med i underlaget")
        Prov.kolla(!underlag.contains { $0.titel.contains("Annat möte") },
                   "men inte möten utanför projektet")
        let tavlan = underlag.first { $0.titel == "Uppgifterna på tavlan" }
        Prov.kolla(tavlan?.text.contains("Skicka offerten") == true,
                   "projektets uppgifter är med")
        Prov.kolla(tavlan?.text.contains("FÖRSENAD") == true,
                   "och det försenade är utpekat")
        Prov.kolla(tavlan?.text.contains("Beställ hyllor") == true,
                   "liksom uppgifter som nämner projektet vid namn")
        Prov.kolla(tavlan?.text.contains("Annan kunds sak") == false,
                   "uppgifter utanför projektet är inte med")
        Prov.kolla(underlag.contains { $0.typ == "mejl" }, "mejlen följer med")

        Prov.lika(Läget.underlag(projekt: "Tomt", inspelningar: [], uppgifter: [],
                                 mejl: [], anteckningar: []).count, 0,
                  "utan underlag byggs ingenting")

        // Färskhet: en bild skriven före senaste materialet är gammal.
        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        let kund = try! arkiv.skapaKund(namn: "Acme")
        let projekt = try! arkiv.skapaProjekt(namn: "Nytt lager", hos: kund)
        try! arkiv.läggTill([Uppgift(vad: "Skicka offerten", projekt: "Nytt lager")],
                            för: kund)
        let gammalBild = Lägesbild(text: "x", skriven: Uppgift.dag("2026-01-01")!)
        Prov.kolla(Läget.gammal(gammalBild, kund: kund, projekt: projekt, arkiv: arkiv),
                   "en bild skriven före senaste materialet är gammal")
        let färsk = Lägesbild(text: "x", skriven: Date().addingTimeInterval(60))
        Prov.kolla(!Läget.gammal(färsk, kund: kund, projekt: projekt, arkiv: arkiv),
                   "en nyskriven är det inte")
    }

    // MARK: - Möteskopplingar

    static func möteskopplingar() {
        Prov.svit("Möteskopplingar")
        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        let kund = try! arkiv.skapaKund(namn: "Acme")

        Prov.lika(arkiv.möteskopplingar(för: kund).count, 0, "inga kopplingar från början")
        try! arkiv.kopplaMöte("m1", till: "Nytt lager", för: kund)
        Prov.lika(arkiv.möteskopplingar(för: kund)["m1"], "Nytt lager",
                  "ett möte kan kopplas till ett projekt")
        // Utan projekt är mötet ändå kundens — det är anspråket som räknas:
        // möten utan deltagarlista kan ingen regel känna igen.
        try! arkiv.kopplaMöte("m1", till: nil, för: kund)
        Prov.lika(arkiv.möteskopplingar(för: kund)["m1"], "",
                  "utan projekt hör mötet ändå till kunden")
        try! arkiv.taBortMöteskoppling("m1", för: kund)
        Prov.lika(arkiv.möteskopplingar(för: kund)["m1"], nil,
                  "och anspråket går att släppa")
    }

    // MARK: - Transkriberingsmotorer

    static func transkriberingsmotorer() {
        Prov.svit("Transkriberingsmotorer")

        // mlx_whispers JSON, som den såg ut i den uppmätta körningen.
        let mlx = #"{"language":"sv","text":"x","segments":[{"id":0,"start":0.0,"end":4.0,"text":" Okej, då spelar jag in ett möte."},{"id":1,"start":17.0,"end":21.0,"text":" Jag lyssnar."}]}"#
        let mlxRader = MlxWhisper.tolka(Data(mlx.utf8), röst: .motpart)
        Prov.lika(mlxRader.count, 2, "mlx-segmenten blir yttranden")
        Prov.lika(mlxRader.first?.text, "Okej, då spelar jag in ett möte.",
                  "texten trimmas")
        Prov.lika(mlxRader.first?.slut, 4.0, "tiderna är sekunder rakt av")

        let mlxTomt = #"{"segments":[{"start":0.0,"end":2.0,"text":" Tack."}]}"#
        Prov.lika(MlxWhisper.tolka(Data(mlxTomt.utf8), röst: .motpart).count, 0,
                  "påhittsfraserna filtreras även här")

        // OpenAIs verbose_json.
        let oa = #"{"task":"transcribe","segments":[{"start":0.0,"end":10.0,"text":" Okej, då spelar jag in ett möte."},{"start":30.0,"end":34.0,"text":" Vilka var de 20 uppgifterna?"}]}"#
        let oaRader = Molntranskribering.tolkaOpenAI(Data(oa.utf8), röst: .jag)
        Prov.lika(oaRader.count, 2, "OpenAI-segmenten blir yttranden")
        Prov.lika(oaRader.last?.start, 30.0, "med sina tider")

        // Scribes ord med tider — sys ihop vid pauserna.
        let scribe = #"{"language_code":"swe","text":"x","words":["#
            + #"{"text":"Okej,","start":2.0,"end":2.3,"type":"word"},"#
            + #"{"text":" ","start":2.3,"end":2.4,"type":"spacing"},"#
            + #"{"text":"då","start":2.4,"end":2.6,"type":"word"},"#
            + #"{"text":"(skratt)","start":2.6,"end":3.0,"type":"audio_event"},"#
            + #"{"text":"kör","start":2.7,"end":3.0,"type":"word"},"#
            + #"{"text":"Nästa","start":9.5,"end":9.9,"type":"word"},"#
            + #"{"text":"mening","start":10.0,"end":10.4,"type":"word"}]}"#
        let sc = Molntranskribering.tolkaScribe(Data(scribe.utf8), röst: .motpart)
        Prov.lika(sc.count, 2, "orden sys ihop till yttranden vid pauserna")
        Prov.lika(sc.first?.text, "Okej, då kör", "mellanslag och ljudhändelser hoppas över")
        Prov.lika(sc.first?.start, 2.0, "första ordets start är yttrandets")
        Prov.lika(sc.last?.text, "Nästa mening", "pausen på sex sekunder delar")

        Prov.lika(Molntranskribering.tolkaScribe(Data(#"{"detail":{"message":"fel"}}"#.utf8),
                                                 röst: .jag).count, 0,
                  "ett felsvar ger inga rader")

        // Inställningen överlever gamla filer utan nya fält.
        let gammal = try? JSONDecoder().decode(Transkriberingsval.self,
                                               from: Data(#"{"motor":"openai"}"#.utf8))
        Prov.lika(gammal?.motor, .openai, "sparade val utan alla fält går att läsa")
        Prov.lika(gammal?.arkivmodell, "whisper-1", "och tom modell betyder motorns standard")

        // Loopfiltret: 773 rader «Good afternoon.» i följd hände på riktigt.
        func y(_ t: String) -> Yttrande { Yttrande(röst: .motpart, text: t, start: 0, slut: 1) }
        let loop = [y("Hej")] + Array(repeating: y("Good afternoon."), count: 700) + [y("Slut")]
        let rensad = MlxWhisper.utanUpprepningar(loop)
        Prov.lika(rensad.map(\.text), ["Hej", "Good afternoon.", "Slut"],
                  "en loop kokas ner till sin första rad")
        let äkta = [y("Ja."), y("Ja."), y("Precis.")]
        Prov.lika(MlxWhisper.utanUpprepningar(äkta).count, 3,
                  "korta äkta upprepningar lämnas i fred")

        // Språkvägvalet: KB översätter allt till svenska — uppmätt blev
        // engelskt ljud svenska även med -l en — så andra språk routas bort.
        let kb = Arkivtranskribering.vägval(motor: .whisperCpp,
                                            modell: "kb_whisper_ggml_medium.bin", språk: "sv")
        Prov.lika(kb?.motor, .whisperCpp, "svenska stannar hos KB")
        let eng = Arkivtranskribering.vägval(motor: .whisperCpp,
                                             modell: "kb_whisper_ggml_medium.bin", språk: "en")
        Prov.lika(eng?.motor, .mlx, "engelska med KB-modell tar vägen via MLX")
        let auto = Arkivtranskribering.vägval(motor: .whisperCpp,
                                              modell: "kb_whisper_ggml_medium.bin", språk: nil)
        Prov.lika(auto?.motor, .mlx, "avgör-själv likaså — KB kan inte avgöra")
        let moln = Arkivtranskribering.vägval(motor: .elevenlabs,
                                              modell: "scribe_v2", språk: "en")
        Prov.lika(moln?.motor, .elevenlabs, "molnmotorer rör inte vägvalet")
        let annan = Arkivtranskribering.vägval(motor: .whisperCpp,
                                               modell: "ggml-large-v3.bin", språk: "en")
        Prov.lika(annan?.motor, .whisperCpp,
                  "en whisper.cpp-modell som inte är KB får köra engelska själv")

        // Språkgissningen: motorerna lyssnar bara på filens första halvminut,
        // och ett möte som spelats in innan någon talar har tystnad där.
        // Uppmätt blev en timme norska «English» på sin första halvminut.
        let block = Ljudbuffring.blocklängd
        let perSekund = Int(Ljudbuffring.målfrekvens) / block
        // Tolv sekunder tystnad, sedan fem sekunder tal.
        var rms = [Float](repeating: 0.0002, count: 12 * perSekund)
        rms += [Float](repeating: 0.05, count: 5 * perSekund)
        let start = Arkivtranskribering.förstaTalet(blockRMS: rms)
        Prov.kolla(start != nil, "talet hittas bortom tystnaden")
        Prov.kolla((start ?? 99) >= 2 && (start ?? 0) <= 13,
                   "och pekas ut strax före det, inte vid filens början — blev \(start ?? -1)")
        Prov.lika(Arkivtranskribering.förstaTalet(
                    blockRMS: [Float](repeating: 0.0002, count: 30 * perSekund)), nil,
                  "ren tystnad ger ingen gissningspunkt")
        // En dörr som slår igen är inte någon som talar.
        var knäpp = [Float](repeating: 0.0002, count: 20 * perSekund)
        for i in 0..<(perSekund / 4) { knäpp[10 * perSekund + i] = 0.05 }
        Prov.lika(Arkivtranskribering.förstaTalet(blockRMS: knäpp), nil,
                  "ett kort knäpp räknas inte som tal")

        Prov.kolla(Whisper.ärTomtLjud("Teksting av Nicolai Winther"),
                   "norsk textningssignatur räknas som tystnad")
        Prov.kolla(Whisper.ärTomtLjud("Takk."), "ensamt «Takk.» är påhitt")
        Prov.kolla(!Whisper.ärTomtLjud("Takk for at du tok deg tid"),
                   "men ett riktigt tack lämnas i fred")

        Prov.lika(MlxWhisper.kod("sv"), "sv", "språkkoden går rakt igenom")
        Prov.lika(MlxWhisper.kod("Swedish"), "sv", "och namnet översätts till kod")
        Prov.lika(MlxWhisper.kod("nb"), "no", "bokmål och nynorsk blir norska")
        Prov.lika(MlxWhisper.kod(""), nil, "tomt svar är ingen gissning")
        Prov.kolla(Mötesspråk.val.contains { $0.kod == "no" },
                   "norska går att välja — annars är «avgör själv» enda vägen")
        Prov.lika(Mötesspråk.namn(nil), "Avgör själv", "nil är «avgör själv»")

        Prov.kolla(!Transkriberingsval.lokalaModeller().isEmpty,
                   "modellistan hittar ggml-filerna")
        Prov.kolla(!Transkriberingsval.lokalaModeller().contains { $0.contains("silero") },
                   "men inte taldetektorn")
        Prov.kolla(!Transkriberingsval.lokalaModeller().contains { $0.hasPrefix("for-tests") },
                   "och inte testfixturerna")
    }

    // MARK: - Betydelsesökning

    static func betydelse() {
        Prov.svit("Betydelsesökning")

        // RRF: det som ligger högt i båda listorna vinner.
        Prov.lika(Kunskapsbank.rrf(ord: [1, 2, 3], betydelse: [3, 4, 1]).first, 1,
                  "hög placering i båda listorna vinner")
        Prov.lika(Kunskapsbank.rrf(ord: [1], betydelse: []), [1],
                  "en tom lista fäller ingenting")
        Prov.lika(Kunskapsbank.rrf(ord: [], betydelse: [7]), [7],
                  "och åt andra hållet")
        Prov.kolla(Kunskapsbank.rrf(ord: [1, 2], betydelse: [9, 8]).count == 4,
                   "alla kandidater finns kvar i ordningen")

        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        let kund = try! arkiv.skapaKund(namn: "Acme")
        let bank = try! Kunskapsbank(kund: kund)
        try! bank.läggTill(titel: "Avstämning", text: "Vi pratade om leveranstiden",
                           typ: "transkript", källa: "/a", tid: nil)
        try! bank.läggTill(titel: "Offert", text: "Pris per pallställ",
                           typ: "bilaga", källa: "/b", tid: nil)

        Prov.lika(bank.utanVektor().count, 2, "nya stycken saknar vektor")
        let rader = bank.utanVektor()
        try! bank.sparaVektor(rader[0].id, [1, 0, 0])
        try! bank.sparaVektor(rader[1].id, [0, 1, 0])
        Prov.lika(bank.utanVektor().count, 0, "inbäddade stycken frågas inte om")
        Prov.lika(bank.vektorer().count, 2, "vektorerna går att läsa tillbaka")
        Prov.lika(bank.vektorer().first(where: { $0.id == rader[0].id })?.vektor,
                  [1, 0, 0], "och innehållet är intakt")

        // Frågevektorn pekar mot offerten — den ska upp, trots att orden
        // i frågan inte finns i texten.
        let träffar = bank.hybrid("vad kostar det", vektor: [0, 1, 0])
        Prov.lika(träffar.first?.titel, "Offert",
                  "betydelsen hittar det orden missar")

        Prov.lika(bank.hybrid("leveranstid", vektor: nil).first?.titel, "Avstämning",
                  "utan vektor är hybriden vanlig ordsökning")

        try! bank.glöm(källa: "/b")
        Prov.lika(bank.vektorer().count, 1, "en glömd källa tar sina vektorer med sig")
    }

    // MARK: - Omindexering

    static func omindexering() {
        Prov.svit("Omindexering")
        let rot = FileManager.default.temporaryDirectory
            .appending(path: "kundkoll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rot) }
        let arkiv = Arkivet(rot: rot)
        let kund = try! arkiv.skapaKund(namn: "Acme")

        // Ett mejl med en bilaga som redan har utläst text.
        let mejl = Mailen.Mejl(datum: Date(), datumText: "", avsändare: "Anna <anna@acme.se>",
                               ämne: "Offert", meddelandeID: "id1", konto: "a",
                               låda: "INBOX", riktning: "från", text: "Här är offerten.")
        let bilagefil = kund.mailmapp.appending(path: "Bilagor/offert.pdf").path
        let bilaga = Bilagor.Bilaga(ämne: "Offert", namn: "offert.pdf", fil: bilagefil,
                                    storlek: 1000,
                                    text: "Offert på pallställ, 2 400 kr per enhet")
        try! arkiv.sparaMail([mejl], bilagor: [bilaga], för: kund)

        let bank = try! Kunskapsbank(kund: kund)
        _ = try! Indexering.kör(för: kund, bank: bank, arkiv: arkiv)
        let efterEn = bank.antal

        // Mailcachen skrivs om — som efter varje hämtning — och indexeras om.
        try! arkiv.sparaMail([mejl], bilagor: [bilaga], för: kund)
        _ = try! Indexering.kör(för: kund, bank: bank, arkiv: arkiv)
        _ = try! Indexering.kör(för: kund, bank: bank, arkiv: arkiv)

        Prov.lika(bank.antal, efterEn,
                  "att indexera om ger inga dubbletter (\(bank.antal) mot \(efterEn))")
        Prov.kolla(!bank.sök("pallställ").isEmpty, "och bilagan är fortfarande sökbar")
    }

    // MARK: - Briefing

    static func briefing() {
        Prov.svit("Briefing")

        func inspelning(_ titel: String, _ dag: String, öppet: [String] = []) -> (Inspelning, URL) {
            var i = Inspelning(titel: titel, inledd: Uppgift.dag(dag)!, längd: 60, kund: "Acme",
                               projekt: nil, mikrofon: nil, liveYttranden: [], arkivYttranden: nil)
            if !öppet.isEmpty {
                i.sammanfattning = Mötessammanfattning(kärna: "Kärnan i \(titel)", beslut: [],
                                                       åtaganden: [], öppet: öppet)
            }
            return (i, URL(fileURLWithPath: "/x/\(titel) \(dag)"))
        }
        func mejl(_ ämne: String, _ dag: String) -> Mailen.Mejl {
            Mailen.Mejl(datum: Uppgift.dag(dag), datumText: dag,
                        avsändare: "Anna <anna@acme.se>", ämne: ämne,
                        meddelandeID: ämne, konto: "a", låda: "INBOX",
                        riktning: "från")
        }
        let möte = Kalendern.Möte(id: "m1", titel: "magnus 1on1 20261001",
                                  start: Date().addingTimeInterval(3600),
                                  slut: Date().addingTimeInterval(7200),
                                  deltagare: [], plats: nil, möteslänk: nil)

        let senaste = inspelning("Styrgrupp", "2026-08-28")
        let iSerien = inspelning("magnus 1on1 20260901", "2026-09-01", öppet: ["Priset?"])
        let b = Briefing.bygg(kund: "Acme", möte: möte,
                              inspelningar: [senaste, iSerien],
                              uppgifter: [Uppgift(vad: "Skicka offerten"),
                                          Uppgift(vad: "Klar sak", läge: .klart)],
                              mejl: [mejl("Efter mötet", "2026-09-02"),
                                     mejl("Före mötet", "2026-08-15")])

        Prov.lika(b.senaste?.0.titel, "magnus 1on1 20260901",
                  "serien går före det allra senaste mötet")
        Prov.lika(b.öppnaFrågor, ["Priset?"], "de obesvarade frågorna följer med")
        Prov.lika(b.öppnaUppgifter.map(\.vad), ["Skicka offerten"],
                  "bara öppna uppgifter tas med")
        Prov.lika(b.mejlSedanSist.map(\.ämne), ["Efter mötet"],
                  "bara mejl efter senaste mötet räknas som nya")
        Prov.kolla(!b.tom, "briefen har innehåll")

        let utanMöte = Briefing.bygg(kund: "Acme", möte: nil,
                                     inspelningar: [senaste, iSerien],
                                     uppgifter: [], mejl: [])
        Prov.lika(utanMöte.senaste?.0.titel, "Styrgrupp",
                  "utan kalendermöte gäller det senaste mötet rakt av")

        let tom = Briefing.bygg(kund: "Acme", möte: nil, inspelningar: [],
                                uppgifter: [], mejl: [])
        Prov.kolla(tom.tom, "utan material är briefen tom och säger det")
    }

    // MARK: - Kommandopaletten

    static func palett() {
        Prov.svit("Kommandopaletten")

        func kund(_ namn: String) -> Kommandopalett.Träff {
            .init(slag: .kund(Kund(namn: namn, mapp: URL(fileURLWithPath: "/x/\(namn)"))))
        }
        func uppgift(_ vad: String) -> Kommandopalett.Träff {
            .init(slag: .uppgift(Uppgift(vad: vad),
                                 Kund(namn: "Acme", mapp: URL(fileURLWithPath: "/x/Acme"))))
        }
        let allt = [kund("Corvus"), kund("Acme"), uppgift("Skicka offerten till Corvus"),
                    Kommandopalett.Träff(slag: .minVecka)]

        Prov.lika(Kommandopalett.sök("cor", i: allt).first?.namn, "Corvus",
                  "prefix på kundnamnet vinner")
        Prov.lika(Kommandopalett.sök("corvus", i: allt).count, 2,
                  "uppgiften som nämner kunden finns också med")
        Prov.lika(Kommandopalett.sök("offerten", i: allt).first?.namn,
                  "Skicka offerten till Corvus", "ordprefix inne i en uppgift hittas")
        Prov.lika(Kommandopalett.sök("CORVUS", i: allt).first?.namn, "Corvus",
                  "skiftläge spelar ingen roll")
        Prov.kolla(Kommandopalett.sök("zzz", i: allt).isEmpty,
                   "det som inte finns ger ingenting")
        Prov.lika(Kommandopalett.sök("", i: allt).count, 3,
                  "tom sökning visar kunder och Min vecka, inte uppgifter")
    }

    // MARK: - Strömmande svar

    static func ström() {
        Prov.svit("Strömmande svar")

        let öppen = #"{"choices":[{"delta":{"content":"Hej "}}]}"#
        Prov.lika(Chatt.deltaOpenAI(Data(öppen.utf8)), "Hej ",
                  "OpenAI-dialektens textbit plockas ur delta")
        let roll = #"{"choices":[{"delta":{"role":"assistant"}}]}"#
        Prov.lika(Chatt.deltaOpenAI(Data(roll.utf8)), nil,
                  "rader utan text ger ingenting")
        let slut = #"{"choices":[]}"#
        Prov.lika(Chatt.deltaOpenAI(Data(slut.utf8)), nil, "tomma val ger ingenting")

        let antro = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hej"}}"#
        Prov.lika(Chatt.deltaAnthropic(Data(antro.utf8)), "Hej",
                  "Anthropics text_delta plockas ur content_block_delta")
        let start = #"{"type":"message_start","message":{}}"#
        Prov.lika(Chatt.deltaAnthropic(Data(start.utf8)), nil,
                  "andra händelser ger ingenting")
        let tank = #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}"#
        Prov.lika(Chatt.deltaAnthropic(Data(tank.utf8)), nil,
                  "tänkande läcker inte in i svaret")
    }

    // MARK: - Min vecka

    static func minVecka() {
        Prov.svit("Min vecka")
        let idag = Uppgift.dag("2026-09-02")!   // en onsdag

        func var_(_ dag: String?) -> String {
            Minveckavy.grupp(Uppgift(vad: "x", senast: dag.flatMap(Uppgift.dag)), idag: idag)
        }
        Prov.lika(var_("2026-09-01"), "Försenat", "gårdagen är försenad")
        Prov.lika(var_("2026-09-02"), "Denna vecka", "dagens dag hör till veckan")
        Prov.lika(var_("2026-09-06"), "Denna vecka", "söndagen med — veckan är mån–sön")
        Prov.lika(var_("2026-09-07"), "Senare", "måndagen därpå är senare")
        Prov.lika(var_(nil), "Utan datum", "utan datum är utan datum")
    }

    // MARK: - Uppföljningsmejl

    static func uppföljning() {
        Prov.svit("Uppföljningsmejl")

        var i = Inspelning(titel: "Avstämning", inledd: Date(), längd: 60, kund: "Acme",
                           projekt: nil, mikrofon: nil, liveYttranden: [], arkivYttranden: nil)
        i.sammanfattning = Mötessammanfattning(
            kärna: "Vi gick igenom offerten.",
            beslut: ["Offerten skickas i veckan"],
            åtaganden: [.init(vad: "Skicka offerten", vem: "Anders", när: "före fredag")],
            öppet: ["Priset på pallställ"])
        let text = Uppföljning.brödtext(för: i)
        Prov.kolla(text.contains("Offerten skickas i veckan"), "besluten kommer med")
        Prov.kolla(text.contains("Skicka offerten (Anders, före fredag)"),
                   "åtagandet med vem och när")
        Prov.kolla(text.contains("Priset på pallställ"), "öppna frågor kommer med")
        Prov.kolla(!text.contains("null"), "inget null läcker in i texten")

        var utan = i
        utan.sammanfattning = nil
        Prov.lika(Uppföljning.brödtext(för: utan), "", "utan sammanfattning finns inget mejl")

        i.röstnamn = [0: "Anna Svensson", 1: "Anders Bjarby"]
        let kontakter = [Kontakt(namn: "Anna Svensson", epost: ["anna@acme.se"]),
                         Kontakt(namn: "Bo Ek", epost: ["bo@acme.se"])]
        Prov.lika(Uppföljning.mottagare(för: i, kontakter: kontakter), ["anna@acme.se"],
                  "deltagarna blir mottagare, andra kontakter inte")
        Prov.lika(Uppföljning.mottagare(för: utan, kontakter: kontakter), [],
                  "utan namngivna röster förifylls ingen adress")

        Prov.lika(Uppföljning.fly(#"sa "hej" \ hejdå"#), #"sa \"hej\" \\ hejdå"#,
                  "citattecken och bakstreck flys åt AppleScript")
    }

    // MARK: - Lagring

    /// Att en fil som sparats en gång går att läsa igen nästa gång appen har
    /// blivit ett fält rikare.
    ///
    /// Swift använder inte standardvärden när en nyckel saknas. Ett nytt fält
    /// på en typ som ligger på disk gör därför alla tidigare filer oläsbara —
    /// och eftersom de läses med `try?` försvinner de utan ett ord. Det har
    /// hänt två gånger i det här projektet: mejlcachen tömdes, och en
    /// inspelning slutade synas i listan.
    ///
    /// Varje typ som skrivs till disk provas här mot den minsta JSON som en
    /// äldre version kan ha lämnat efter sig.
    static func lagring() {
        Prov.svit("Lagring")

        func läs<T: Decodable>(_ typ: T.Type, _ json: String, _ vad: String) -> T? {
            do {
                return try JSONDecoder.kundkoll.decode(typ, from: Data(json.utf8))
            } catch {
                Prov.kolla(false, "\(vad): \(error)")
                return nil
            }
        }

        // Sammanfattningen ligger inne i möte.json. Faller den, försvinner
        // hela inspelningen ur listan.
        let sam = läs(Mötessammanfattning.self,
                      #"{"kärna":"Vi gick igenom offerten","beslut":[],"åtaganden":[],"öppet":[]}"#,
                      "en sammanfattning utan skriven-datum går att läsa")
        Prov.lika(sam?.kärna, "Vi gick igenom offerten", "och innehållet kommer med")

        let åtagande = läs(Mötessammanfattning.self,
                           #"{"kärna":"","beslut":[],"öppet":[],"åtaganden":[{"vad":"Skicka offerten"}]}"#,
                           "ett åtagande utan id och klart går att läsa")
        Prov.lika(åtagande?.åtaganden.first?.vad, "Skicka offerten", "och texten kommer med")
        Prov.lika(åtagande?.åtaganden.first?.klart, false, "klart får sitt standardvärde")

        // Röstprofilerna byggs upp över månader. De får inte kunna gå förlorade.
        let profil = läs([Röstprofil].self,
                         #"[{"namn":"Anna","avtryck":[{"vektor":[0.1,0.2],"sekunder":6}],"uppdaterad":"2026-08-01T09:00:00Z","samtal":2}]"#,
                         "en röstprofil utan id går att läsa")
        Prov.lika(profil?.first?.namn, "Anna", "och namnet kommer med")
        Prov.lika(profil?.first?.avtryck.count, 1, "liksom avtrycket")

        let kopplad = läs([Kopplad].self, #"[{"väg":"/Users/a/kod"}]"#,
                          "en kopplad mapp med bara sin väg går att läsa")
        Prov.lika(kopplad?.first?.väg, "/Users/a/kod", "och vägen kommer med")
        Prov.lika(kopplad?.first?.ändelser.count, 0, "ändelserna får sitt standardvärde")

        // Chattarna ligger i samtalen. Ett nytt fält på ett meddelande skulle
        // annars ta hela samtalshistoriken med sig.
        let samtal = läs(Samtal.self,
                         #"{"titel":"Om offerten","meddelanden":[{"roll":"människa","text":"Vad kostar det?"}]}"#,
                         "ett meddelande utan id, tid och ursprung går att läsa")
        Prov.lika(samtal?.meddelanden.first?.text, "Vad kostar det?", "och frågan kommer med")
        Prov.lika(samtal?.meddelanden.first?.ursprung, .kunskapsbank, "ursprunget får sitt standardvärde")

        let hänvisning = läs(Chatt.Meddelande.self,
                             #"{"roll":"assistent","text":"Svar","hänvisningar":[{"nummer":1,"titel":"Möte","typ":"transkript","källa":"/a"}]}"#,
                             "en hänvisning utan datum går att läsa")
        Prov.lika(hänvisning?.hänvisningar.first?.titel, "Möte", "och titeln kommer med")

        let modell = läs(Modellval.self, #"{"leverantör":"openrouter"}"#,
                         "ett modellval utan modell och adress går att läsa")
        Prov.lika(modell?.leverantör, .openrouter, "och leverantören kommer med")
        Prov.kolla(!(modell?.modell.isEmpty ?? true), "modellen får sitt standardvärde")

        // Åt andra hållet: en fil skriven av en nyare version, med fält den
        // här inte känner till, ska också gå att läsa.
        let framtid = läs(Uppgift.self,
                          #"{"vad":"Skicka offerten","prioritet":"hög"}"#,
                          "ett okänt fält gör inte filen oläsbar")
        Prov.lika(framtid?.vad, "Skicka offerten", "och det kända kommer med")

        // Och skulle en möte.json ändå bli oläslig — en avbruten skrivning,
        // en trasig disk — ska inspelningen synas som påbörjad i stället för
        // att bara försvinna ur listan.
        do {
            let rot = FileManager.default.temporaryDirectory
                .appending(path: "kundkoll-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rot) }
            let arkiv = Arkivet(rot: rot)
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let mapp = try! arkiv.nyInspelningsmapp(placering: .kund(kund), titel: "Avstämning",
                                                    datum: Date())
            try! Data("x".utf8).write(to: mapp.appending(path: "motpart.wav"))
            let i = Inspelning(titel: "Avstämning", inledd: Date(), längd: 60, kund: "Acme",
                               projekt: nil, mikrofon: nil, liveYttranden: [], arkivYttranden: nil)
            try! arkiv.spara(i, i: mapp)
            Prov.lika(arkiv.inspelningar(för: kund).count, 1, "inspelningen syns i listan")
            Prov.lika(arkiv.ofullständiga(för: kund).count, 0, "och räknas inte som påbörjad")

            try! Data("{ trasig".utf8).write(to: mapp.appending(path: "möte.json"))
            Prov.lika(arkiv.inspelningar(för: kund).count, 0,
                      "en oläslig möte.json går inte att lista")
            Prov.lika(arkiv.ofullständiga(för: kund).count, 1,
                      "men mappen syns som påbörjad i stället för att försvinna")
        }
    }

    // MARK: - Uppgifter ur möten

    static func mötesuppgifter() {
        Prov.svit("Uppgifter ur möten")
        let mapp = URL(fileURLWithPath: "/Kunder/Acme/Samtal/2026-09-01 0900 Avstämning")
        let annan = URL(fileURLWithPath: "/Kunder/Acme/Samtal/2026-09-02 0900 Uppföljning")

        let ur = Uppgift(vad: "Skicka offerten", ursprung: .möte,
                         källa: mapp.path, källtitel: "Avstämning")
        Prov.kolla(Uppgiftssamling.hör(ur, till: mapp, titel: "Avstämning"),
                   "uppgiften hör till mötet den kom ur")
        Prov.kolla(!Uppgiftssamling.hör(ur, till: annan, titel: "Uppföljning"),
                   "men inte till ett annat möte")

        // Uppgifter som lades upp innan mappen började sparas har bara titeln.
        let gammal = Uppgift(vad: "Skicka offerten", ursprung: .möte, källtitel: "Avstämning")
        Prov.kolla(Uppgiftssamling.hör(gammal, till: mapp, titel: "Avstämning"),
                   "äldre uppgifter känns igen på titeln")

        let urMejl = Uppgift(vad: "Skicka offerten", ursprung: .mejl,
                             källa: mapp.path, källtitel: "Avstämning")
        Prov.kolla(!Uppgiftssamling.hör(urMejl, till: mapp, titel: "Avstämning"),
                   "en uppgift ur ett mejl hör inte till mötet")

        // Riktiga datum. "före fredag" är fritext; det tavlan sorterar och
        // rödmarkerar på är modellens uträknade ÅÅÅÅ-MM-DD.
        Prov.kolla(Uppgift.dag("2026-09-05") != nil, "ÅÅÅÅ-MM-DD blir ett datum")
        Prov.kolla(Uppgift.dag(" 2026-09-05 ") != nil, "även med luft omkring")
        Prov.lika(Uppgift.dag("före fredag"), nil, "fritext blir inget datum")
        Prov.lika(Uppgift.dag("null"), nil, "null blir inget datum")
        Prov.lika(Uppgift.dag(nil), nil, "ingenting blir ingenting")

        let igår = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let imorgon = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        Prov.kolla(Uppgift(vad: "x", senast: igår).försenad, "ett passerat datum är försenat")
        Prov.kolla(!Uppgift(vad: "x", senast: igår, läge: .klart).försenad,
                   "men inte när uppgiften är klar")
        Prov.kolla(!Uppgift(vad: "x", senast: imorgon).försenad, "morgondagen är inte försenad")
        Prov.kolla(!Uppgift(vad: "x", senast: Date()).försenad, "och inte dagens dag")
        Prov.kolla(!Uppgift(vad: "x").försenad, "utan datum finns inget att försena")

        let tolkade = Uppgiftsletare.tolka(
            #"{"uppgifter":[{"vad":"Skicka offerten","vem":"Anders","när":"före fredag","senast":"2026-09-04"}]}"#)
        Prov.lika(tolkade.first?.senast, Uppgift.dag("2026-09-04"),
                  "modellens uträknade datum följer med uppgiften")
        let utan = Uppgiftsletare.tolka(
            #"{"uppgifter":[{"vad":"Skicka offerten","vem":null,"när":null,"senast":null}]}"#)
        Prov.lika(utan.first?.senast, nil, "null blir inget datum även här")

        let sam = Sammanfattare.tolka(
            #"{"kärna":"k","beslut":[],"öppet":[],"åtaganden":[{"vad":"Boka möte","vem":null,"när":"nästa vecka","senast":"2026-09-08"}]}"#)
        Prov.lika(sam?.åtaganden.first?.senast, Uppgift.dag("2026-09-08"),
                  "sammanfattningens åtaganden får också sitt datum")
    }

    // MARK: - Liveinsikter

    static func liveinsikter() {
        Prov.svit("Liveinsikter")

        Prov.kolla(!Liveinsikter.dagsAttGranska(tecken: 40, väntat: 3),
                   "en enda mening granskas inte direkt")
        Prov.kolla(Liveinsikter.dagsAttGranska(tecken: 200, väntat: 3),
                   "ett stycke räcker för att granska")
        Prov.kolla(Liveinsikter.dagsAttGranska(tecken: 40, väntat: 30),
                   "i ett långsamt samtal granskas det lilla som sagts ändå")
        Prov.kolla(!Liveinsikter.dagsAttGranska(tecken: 0, väntat: 300),
                   "men tystnad granskas aldrig, hur länge den än varar")
    }

    // MARK: - Whisper

    static func whisper() {
        Prov.svit("Whisper")

        do {   // tolkning
            let json = """
            {"transcription":[
              {"text":" Hej allihopa.","offsets":{"from":0,"to":2400}},
              {"text":" Välkomna till mötet.","offsets":{"from":2400,"to":5100}}
            ]}
            """.data(using: .utf8)!
            let rader = Whisper.tolka(json, röst: .motpart, förskjutning: 10)
            Prov.lika(rader.count, 2, "båda raderna tolkas")
            Prov.lika(rader.first?.text, "Hej allihopa.", "inledande blanksteg tas bort")
            Prov.lika(rader.first?.start, 10, "millisekunder blir sekunder plus förskjutning")
            Prov.lika(rader.first?.slut, 12.4, "sluttiden räknas om likadant")
            Prov.kolla(rader.allSatisfy { $0.röst == .motpart }, "rösten följer med spåret")
        }

        do {   // tomt ljud
            for t in ["", "[Musik]", "(skratt)", ".", " ... "] {
                Prov.kolla(Whisper.ärTomtLjud(t), "«\(t)» sorteras bort som tystnad")
            }
            // Fraserna whisper hittar på ur tystnad
            for t in ["Tack.", "Tack för hjälpen.", "Tack så mycket", "Textning av",
                      "Thank you.", "Hej då"] {
                Prov.kolla(Whisper.ärTomtLjud(t), "påhittet «\(t)» sorteras bort")
            }
            for t in ["Tack för mötet.", "Ja.", "Tack för att du tog dig tid att titta på ritningen."] {
                Prov.kolla(!Whisper.ärTomtLjud(t), "«\(t)» behålls")
            }
            let json = """
            {"transcription":[
              {"text":" [Musik]","offsets":{"from":0,"to":1000}},
              {"text":" Riktig text.","offsets":{"from":1000,"to":2000}}
            ]}
            """.data(using: .utf8)!
            Prov.lika(Whisper.tolka(json, röst: .jag, förskjutning: 0).count, 1,
                      "påhittade rader tas bort redan vid tolkningen")
        }

        do {   // loopar
            Prov.kolla(Whisper.ärLoop("Ett stort stort stort stort stort stelt"),
                       "samma ord fyra gånger i rad är en modell som fastnat")
            Prov.kolla(Whisper.ärLoop("ja ja ja ja ja ja ja ja"),
                       "en lång ramsa av ett enda ord likaså")
            Prov.kolla(!Whisper.ärLoop("Ja, ja, det stämmer nog."),
                       "ett upprepat ord i normalt tal är inte en loop")
            Prov.kolla(!Whisper.ärLoop("Vi ska titta på lagret och sedan gå igenom offerten i lugn och ro."),
                       "vanliga meningar passerar")
            Prov.kolla(Whisper.ärTomtLjud("Ett stort stort stort stort stort stelt"),
                       "loopar sorteras bort som tomt ljud")
        }

        do {   // VAD-flaggor
            let flaggor = Whisper.vadflaggor(.standard)
            Prov.kolla(flaggor.contains("--vad"), "taldetektering slås på")
            Prov.kolla(flaggor.contains { $0.hasSuffix("ggml-silero-v5.1.2.bin") },
                       "Silero-modellen pekas ut")
        }

        do {   // framsteg ur whispers utskrift
            Prov.lika(Whisper.tid(ur: "00:01:30.080"), 90.08, "tidsstämpeln tolkas")
            Prov.lika(Whisper.tid(ur: "01:00:00.000"), 3600, "timmar räknas med")
            Prov.kolla(Whisper.tid(ur: "skräp") == nil, "skräp ger nil")

            var buffert = "[00:00:00.000 --> 00:00:04.500]  Hej allihopa.[00:00:04.500 --> 00:00:09.000]  Välkomna."
            let första = Whisper.nästaSegment(&buffert)
            Prov.lika(första?.slut, 4.5, "första segmentets sluttid")
            Prov.lika(första?.text, "Hej allihopa.", "och dess text")
            Prov.kolla(buffert.hasPrefix("[00:00:04.500"), "det lästa tas bort ur bufferten")

            // Ett halvt segment ska vänta på mer data i stället för att tolkas fel
            var halvt = "[00:00:09.000 --> 00:00:12.000]  Ofull"
            Prov.kolla(Whisper.nästaSegment(&halvt) == nil,
                       "ett ofullständigt segment lämnas kvar tills resten kommit")
            Prov.kolla(halvt.contains("Ofull"), "och texten går inte förlorad")

            var tom = ""
            Prov.kolla(Whisper.nästaSegment(&tom) == nil, "tom buffert kraschar inte")
        }

        do {   // ledig port
            let a = try! Whisper.ledigPort()
            Prov.kolla(a > 1024, "en ledig port hittas (\(a))")
            let s = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(s) }
            var adr = sockaddr_in()
            adr.sin_family = sa_family_t(AF_INET)
            adr.sin_port = UInt16(a).bigEndian
            adr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &adr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Prov.lika(r, 0, "porten går verkligen att binda")
        }

        do {   // brister upptäcks
            let trasig = Whisper.Sökvägar(rot: URL(fileURLWithPath: "/finns/inte"),
                                          livemodell: "a.bin", arkivmodell: "b.bin",
                                          vadmodell: "c.bin")
            Prov.lika(trasig.brister.count, 5, "saknade binärer och modeller upptäcks")
            let riktig = Whisper.Sökvägar.standard
            if FileManager.default.fileExists(atPath: riktig.rot.path) {
                Prov.kolla(riktig.brister.isEmpty,
                           "den riktiga whisper.cpp-uppsättningen är komplett\(riktig.brister.isEmpty ? "" : ": \(riktig.brister)")")
            }
        }
    }
}

// MARK: - Robusthet

extension Tester {

    /// Det som robusthetsgranskningen fann: wav-huvuden, cachen, namnbyten,
    /// mejlstämpeln, bilagornas sökvägar och underprocesserna.
    static func robusthet() {
        Prov.svit("Robusthet")
        let fm = FileManager.default

        func läs<T: Decodable>(_ typ: T.Type, _ json: String) -> T? {
            try? JSONDecoder.kundkoll.decode(typ, from: Data(json.utf8))
        }

        do {   // ett wav-huvud som lämnats med längden noll
            let fil = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString).wav")
            defer { try? fm.removeItem(at: fil) }
            let prov = [Float](repeating: 0.1, count: 16_000)      // en sekund
            var data = Wav.data(av: [])                              // huvud med längden noll
            data.append(Wav.data(av: prov).suffix(from: Wav.huvudlängd))
            try! data.write(to: fil)
            Prov.lika(Wav.längd(av: fil), 1.0, "längden räknas ur filens storlek, inte huvudet")
            Prov.kolla((try? Wav.rättaHuvud(i: fil)) == true, "ett huvud med längden noll rättas")
            let ljud = try? AVAudioFile(forReading: fil)
            Prov.lika(ljud.map { Int($0.length) }, 16_000, "och filen läses som en sekund ljud")
            Prov.kolla((try? Wav.rättaHuvud(i: fil)) == false, "ett riktigt huvud lämnas orört")
        }

        do {   // spårskrivaren skriver om huvudet under gång
            let fil = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString).wav")
            defer { try? fm.removeItem(at: fil) }
            let s = try! Spårskrivare(fil: fil)
            s.skriv([Float](repeating: 0.05, count: 16_000 * 6))
            // Utan stäng(): som efter en krasch mitt i mötet.
            let sekunder = (try? AVAudioFile(forReading: fil)).map { Double($0.length) / 16_000 } ?? 0
            Prov.kolla(sekunder >= 5, "ljudet är läsbart även om skrivaren aldrig stängts (\(sekunder) s)")
            s.stäng()
        }

        do {   // nya fält i möte.json
            let i = läs(Inspelning.self,
                        #"{"titel":"T","inledd":"2026-09-01T09:00:00Z","längd":5,"kund":"Acme","liveYttranden":[]}"#)
            Prov.lika(i?.bearbetas, false, "bearbetas får sitt standardvärde")
            Prov.kolla(i?.arkivfel == nil && i?.röstmetod == nil,
                       "felfälten saknas utan att fälla läsningen")
            let avbruten = läs(Inspelning.self,
                               #"{"titel":"T","inledd":"2026-09-01T09:00:00Z","längd":5,"kund":"Acme","liveYttranden":[],"bearbetas":true}"#)
            Prov.lika(avbruten?.avbruten, true, "ett pass som avbröts känns igen")
        }

        do {   // mejlstämpeln flyttas bara över det som gåtts igenom
            func mejl(_ d: String, _ t: String) -> Mailen.Mejl {
                Mailen.Mejl(datum: Uppgift.dag(d), datumText: d, avsändare: "a", ämne: t,
                            meddelandeID: t, konto: "k", låda: "INBOX", riktning: "från", text: "text")
            }
            let lista = [mejl("2026-09-03", "c"), mejl("2026-09-01", "a"), mejl("2026-09-02", "b")]
            let ut = Uppgiftssamling.attGåIgenom(lista, sedan: Uppgift.dag("2026-09-01")!)
            Prov.lika(ut.map(\.ämne), ["b", "c"], "bara mejl efter stämpeln, äldst först")
        }

        do {   // bilagor utanför mappen sorteras bort
            let mapp = URL(fileURLWithPath: "/tmp/kundkoll-bilagor")
            let rad = ["Offert", "x.pdf", "/tmp/kundkoll-bilagor/x.pdf", "10"].joined(separator: "\u{1F}")
            let elak = ["Offert", "y.pdf", "/tmp/kundkoll-bilagor/../../Library/y.pdf", "10"]
                .joined(separator: "\u{1F}")
            let ut = Bilagor.tolka(rad + "\n" + elak, inom: mapp)
            Prov.lika(ut.count, 1, "en sökväg som pekar ut ur mappen sorteras bort")
            Prov.lika(ut.first?.namn, "x.pdf", "den riktiga behålls")
        }

        do {   // cachen följer filens ändringstid
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let mapp = try! arkiv.nyInspelningsmapp(placering: .kund(kund), titel: "Möte", datum: Date())
            var i = Inspelning(titel: "Möte", inledd: Date(), längd: 5, kund: "Acme", projekt: nil,
                               mikrofon: nil, liveYttranden: [], arkivYttranden: nil)
            try! arkiv.spara(i, i: mapp)
            Prov.lika(arkiv.inspelningar(för: kund).first?.0.titel, "Möte", "inspelningen listas")
            Prov.lika(arkiv.inspelningar(för: kund).first?.0.titel, "Möte", "och en gång till, ur cachen")
            // Skriven utanför arkivet, som Obsidian eller Finder skulle göra.
            i.titel = "Nytt namn"
            try! JSONEncoder.kundkoll.encode(i).write(to: mapp.appending(path: "möte.json"), options: .atomic)
            Prov.lika(arkiv.inspelningar(för: kund).first?.0.titel, "Nytt namn",
                      "en fil som skrivits utanför appen läses om")
        }

        do {   // namnbyten och flyttar drar med sig allt som nycklas på namnet
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Acme")
            let p = try! arkiv.skapaProjekt(namn: "Lager", hos: kund)
            let mapp = try! arkiv.nyInspelningsmapp(placering: .projekt(p), titel: "Uppstart", datum: Date())
            let i = Inspelning(titel: "Uppstart", inledd: Date(), längd: 5, kund: "Acme", projekt: "Lager",
                               mikrofon: nil, liveYttranden: [], arkivYttranden: nil)
            try! arkiv.spara(i, i: mapp)
            try! arkiv.läggTill([Uppgift(vad: "Skicka offerten", ursprung: .möte, källa: mapp.path,
                                         källtitel: "Uppstart", projekt: "Lager")], för: kund)

            let ny = try! arkiv.döpOm(kund: kund, till: "Acme Industries")
            Prov.kolla(fm.fileExists(atPath: ny.mapp.path) && !fm.fileExists(atPath: kund.mapp.path),
                       "kundmappen döps om")
            Prov.lika(arkiv.inspelningar(för: ny).first?.0.kund, "Acme Industries",
                      "inspelningen bär det nya kundnamnet")
            Prov.kolla(arkiv.uppgifter(för: ny).first?.källa?.hasPrefix(ny.mapp.path) == true,
                       "uppgiftens källa pekar in i den nya mappen")
            Prov.kolla(fm.fileExists(atPath: ny.mapp.appending(path: "Acme Industries.md").path),
                       "ingångsnoten döps om")

            let nyttP = try! arkiv.döpOm(projekt: arkiv.projekt(för: ny).first!, hos: ny, till: "Nytt lager")
            Prov.lika(arkiv.inspelningar(för: ny).first?.0.projekt, "Nytt lager",
                      "inspelningen följer projektets nya namn")
            Prov.lika(arkiv.uppgifter(för: ny).first?.projekt, "Nytt lager", "uppgiften likaså")
            Prov.kolla(arkiv.uppgifter(för: ny).first?.källa?.hasPrefix(nyttP.mapp.path) == true,
                       "och dess källa pekar in i den nya projektmappen")

            let (gammal, gammalMapp) = arkiv.inspelningar(för: ny).first!
            let (omdöpt, nyMapp) = try! arkiv.döpOm(gammal, i: gammalMapp, till: "Kickoff", hos: ny)
            Prov.lika(omdöpt.titel, "Kickoff", "mötet får ny titel")
            Prov.kolla(nyMapp.lastPathComponent.hasSuffix("Kickoff"), "och mappen döps om")
            Prov.lika(omdöpt.id, gammal.id, "men behåller sitt id")
            Prov.lika(arkiv.uppgifter(för: ny).first?.källtitel, "Kickoff", "uppgiften följer mötets nya titel")
            Prov.lika(arkiv.uppgifter(för: ny).first?.källa, nyMapp.path, "och pekar på den nya mappen")

            let (flyttad, mapp2) = try! arkiv.flytta(omdöpt, från: nyMapp, till: .kund(ny), hos: ny)
            Prov.kolla(flyttad.projekt == nil && mapp2.path.hasPrefix(ny.samtalsmapp.path),
                       "mötet flyttas till kundnivån")
            Prov.lika(arkiv.uppgifter(för: ny).first?.projekt, nil, "uppgiften släpper projektet")
            Prov.lika(arkiv.inspelningar(för: ny).count, 1, "mötet listas en gång efter flytten")

            try! arkiv.taBort(projekt: nyttP, hos: ny)
            Prov.kolla(!fm.fileExists(atPath: nyttP.mapp.path), "projektet flyttas till papperskorgen")
            Prov.lika(arkiv.projekt(för: ny).count, 0, "och finns inte i listan")
        }

        do {   // ett namnbyte på kontakten följer med till röst, möten och tavla
            let (arkiv, rot) = tillfälligt()
            defer { try? fm.removeItem(at: rot) }
            let kund = try! arkiv.skapaKund(namn: "Acme")
            try! arkiv.läggTill(Kontakt(namn: "Kristin"), hos: kund)
            try! arkiv.lärDigRöst(namn: "Kristin", avtryck: Avtryck(vektor: [1, 0], sekunder: 6), hos: kund)
            try! arkiv.lärDigRöst(namn: "Kristin Sand Backen", avtryck: Avtryck(vektor: [0, 1], sekunder: 6), hos: kund)
            let mapp = try! arkiv.nyInspelningsmapp(placering: .kund(kund), titel: "Möte", datum: Date())
            try! arkiv.spara(Inspelning(titel: "Möte", inledd: Date(), längd: 5, kund: "Acme", projekt: nil,
                                        mikrofon: nil, liveYttranden: [], arkivYttranden: nil,
                                        röstnamn: [0: "Kristin", 1: "Greg"]), i: mapp)
            try! arkiv.läggTill([Uppgift(vad: "Skicka underlaget", vem: "kristin")], för: kund)

            var k = arkiv.kontakter(för: kund).first!
            k.namn = "Kristin Sand Backen"
            try! arkiv.uppdatera(k, hos: kund)

            let profiler = arkiv.egnaRöstprofiler(för: kund)
            Prov.lika(profiler.map(\.namn), ["Kristin Sand Backen"], "rösten byter namn och slås ihop med den som fanns")
            Prov.lika(profiler.first?.avtryck.count, 2, "avtrycken från båda följer med")
            Prov.lika(arkiv.inspelningar(för: kund).first?.0.röstnamn[0], "Kristin Sand Backen", "mötets röst byter namn")
            Prov.lika(arkiv.inspelningar(för: kund).first?.0.röstnamn[1], "Greg", "andra röster rörs inte")
            Prov.lika(arkiv.uppgifter(för: kund).first?.vem, "Kristin Sand Backen", "uppgiftens vem följer med, oavsett skiftläge")

            try! arkiv.taBortRöst(namn: "Kristin Sand Backen", hos: kund)
            Prov.lika(arkiv.egnaRöstprofiler(för: kund).count, 0, "en röst går att glömma")
        }

        do {   // underprocesser: utdata läses till slut, tidsgränsen håller
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ut = ""
            nonisolated(unsafe) var bröts = false
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/echo")
                p.arguments = ["hej"]
                ut = (try? await Underprocess.kör(p, tidsgräns: 10))?.uttext
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let s = Process()
                s.executableURL = URL(fileURLWithPath: "/bin/sleep")
                s.arguments = ["5"]
                do { _ = try await Underprocess.kör(s, tidsgräns: 0.3) }
                catch is Underprocess.Fel { bröts = true }
                catch {}
                sem.signal()
            }
            sem.wait()
            Prov.lika(ut, "hej", "utdata läses till slut")
            Prov.kolla(bröts, "en process som inte blir klar avslutas vid tidsgränsen")
        }
    }
}

// MARK: - Tavlans personfilter

extension Tester {

    static func personfilter() {
        Prov.svit("Tavlans personfilter")
        let kontakter = [Kontakt(namn: "Anders Bjarby"), Kontakt(namn: "Andreas Lund"),
                         Kontakt(namn: "Kristin Berg")]

        let röst = Personer.personer(i: "Röst 1 (Andreas)", kontakter: kontakter)
        Prov.lika(röst.map(\.namn), ["Andreas Lund"], "«Röst 1 (Andreas)» är kontakten Andreas Lund")

        let hel = Personer.personer(i: "anders bjarby", kontakter: kontakter)
        let kort = Personer.personer(i: "Anders", kontakter: kontakter)
        Prov.lika(hel.first?.nyckel, kort.first?.nyckel, "«Anders» och «anders bjarby» är samma person")
        Prov.lika(kort.first?.namn, "Anders Bjarby", "och visas med kontaktens namn")

        let två = Personer.personer(i: "Kristin och Anders", kontakter: kontakter)
        Prov.lika(två.map(\.namn), ["Kristin Berg", "Anders Bjarby"], "«Kristin och Anders» är två personer")

        Prov.lika(Personer.personer(i: nil, kontakter: kontakter).count, 0, "inget vem ger ingen person")
        Prov.lika(Personer.personer(i: "null", kontakter: kontakter).count, 0, "«null» ger ingen person")

        let tvetydiga = kontakter + [Kontakt(namn: "Anders Svensson")]
        let a = Personer.personer(i: "Anders", kontakter: tvetydiga)
        Prov.lika(a.first?.namn, "Anders", "två kontakter med samma förnamn slås inte ihop")

        let okänd = Personer.personer(i: "Greg", kontakter: kontakter)
        Prov.lika(okänd.first?.nyckel, "greg", "ett namn utan kontakt får sin egen nyckel")

        // Röstavtrycken: omdömet följer trösklarna, och en profil lär sig
        // inte samma avtryck två gånger.
        Prov.lika(Tröskel.omdöme(likhet: 0.90, sekunder: 10), .igenkänd, "över namntröskeln: igenkänd")
        Prov.lika(Tröskel.omdöme(likhet: 0.81, sekunder: 10), .trolig, "mellan trösklarna: trolig")
        Prov.lika(Tröskel.omdöme(likhet: 0.40, sekunder: 10), .svag, "under: svag")
        var profil = Röstprofil(namn: "Anna", avtryck: [Avtryck(vektor: [1, 0], sekunder: 6)])
        profil.lärDig(Avtryck(vektor: [1, 0], sekunder: 7))
        Prov.lika(profil.avtryck.count, 1, "samma avtryck igen tillför inget")
        profil.lärDig(Avtryck(vektor: [0, 1], sekunder: 5))
        Prov.lika(profil.avtryck.count, 2, "ett annat avtryck lärs in")
        let sparad = try? JSONDecoder.kundkoll.decode(Inspelning.self, from: Data(
            #"{"titel":"T","inledd":"2026-09-01T09:00:00Z","längd":5,"kund":"Acme","liveYttranden":[],"röstavtryck":{"0":{"vektor":[0.5,0.5],"sekunder":8}}}"#.utf8))
        Prov.lika(sparad?.röstavtryck[0]?.sekunder, 8, "avtrycket per grupp läses ur möte.json")

        // Sammanställningen räknar öppna kort per person, över flera kunder.
        let rader: [(uppgift: Uppgift, kontakter: [Kontakt])] = [
            (Uppgift(vad: "a", vem: "Anders"), kontakter),
            (Uppgift(vad: "b", vem: "Röst 2 (Anders)"), kontakter),
            (Uppgift(vad: "c", vem: "Kristin", läge: .klart), kontakter),
            (Uppgift(vad: "d"), kontakter),
            (Uppgift(vad: "e", vem: "Anders Bjarby"), []),
        ]
        let s = Personer.sammanställ(rader)
        Prov.lika(s.personer.map(\.namn), ["Anders Bjarby"], "klara kort räknas inte, och samma person slås ihop")
        Prov.lika(s.personer.first?.antal, 3, "tre öppna kort på Anders, även hos en kund utan kontakter")
        Prov.lika(s.utanPerson, 1, "ett kort saknar person")
        Prov.kolla(s.gäller("anders bjarby") && !s.gäller("greg"), "ett sparat val gäller bara den som har kort")
        Prov.kolla(Personer.matchar(rader[1].uppgift, kontakter: kontakter, person: "anders bjarby"),
                   "filtret träffar «Röst 2 (Anders)» via kontaktlistan")
        Prov.kolla(Personer.matchar(rader[3].uppgift, kontakter: kontakter, person: Personer.utanPerson),
                   "«Utan person» träffar kortet utan vem")
    }
}

// MARK: - Tystnadsfiltret

extension Tester {

    /// Rader utan tal bakom sig kastas; rader med tal behålls — mätt mot
    /// samma slags ljud som livebuffringen provas på.
    static func tystnadsfiltret() {
        Prov.svit("Tystnadsfiltret")
        let fm = FileManager.default
        let f = Ljudbuffring.målfrekvens

        // 30 s: tystnad med svagt brus 0–10, pulserande tal 10–20, tystnad 20–30.
        var prov = [Float](repeating: 0, count: Int(f) * 30)
        var slump = UInt32(12345)
        for i in prov.indices {
            slump = slump &* 1_664_525 &+ 1_013_904_223
            prov[i] = (Float(slump >> 8) / Float(1 << 24) - 0.5) * 0.001   // brusgolv
        }
        for i in (Int(f) * 10)..<(Int(f) * 20) {
            let t = Double(i) / f
            let stavelse = Int(t * 4) % 2 == 0          // fyra stavelser per sekund
            if stavelse { prov[i] += 0.05 * Float(sin(2 * .pi * 180 * t)) }
        }
        let fil = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: fil) }
        try! Wav.data(av: prov).write(to: fil)

        let rms = Tystnadsfilter.blockRMS(i: fil)
        Prov.lika(rms?.count, 1500, "en halv minut blir 1 500 block om 20 ms")

        let rader = [
            Yttrande(röst: .jag, text: "Tack till elever och personal vid Värmlande.", start: 2, slut: 4),
            Yttrande(röst: .jag, text: "Vi kör igång med lagret.", start: 11, slut: 14),
            Yttrande(röst: .jag, text: "Ja.", start: 17.5, slut: 18),
            Yttrande(röst: .jag, text: "Textning av Kundkoll.", start: 24, slut: 27),
        ]
        let kvar = Tystnadsfilter.rensa(rader, ljud: fil)
        Prov.lika(kvar.map(\.text), ["Vi kör igång med lagret.", "Ja."],
                  "raderna i tystnad kastas, raderna i tal behålls — även en kort")

        // Datorljud ligger tio till fyrtio gånger högre: samma prov, förstärkt.
        let starkt = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: starkt) }
        try! Wav.data(av: prov.map { $0 * 20 }).write(to: starkt)
        Prov.lika(Tystnadsfilter.rensa(rader, ljud: starkt).count, 2,
                  "måttet är relativt: samma utfall på ett tjugo gånger starkare spår")

        // En fil som inte går att läsa lämnar raderna orörda.
        let trasig = fm.temporaryDirectory.appending(path: "kundkoll-test-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: trasig) }
        try! Data("inte en wav".utf8).write(to: trasig)
        Prov.lika(Tystnadsfilter.rensa(rader, ljud: trasig).count, rader.count,
                  "ett oläsligt ljud kastar inget")

        // Fraserna whisper lärt sig ur textade filmer.
        for t in ["Tack till elever och personal vid Värmlande.", "Textning av Elin Andersson",
                  "Undertexter från Amara.org", "Tack för att ni tittade!"] {
            Prov.kolla(Whisper.ärTomtLjud(t), "«\(t)» sorteras bort som påhitt")
        }
        for t in ["Tack till er alla för insatsen i förra veckan, det gick bra.",
                  "Vi tackar för offerten och återkommer."] {
            Prov.kolla(!Whisper.ärTomtLjud(t), "«\(t)» behålls")
        }
    }
}
