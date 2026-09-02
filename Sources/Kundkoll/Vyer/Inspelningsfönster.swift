import SwiftUI
import AppKit

/// Inspelningen i ett eget fönster.
///
/// Ett möte varar i timmen, och under den tiden ska resten av appen gå att
/// använda — slå upp vad som sades förra gången, skriva en anteckning, fråga
/// chatten. Ett eget fönster går dessutom att lägga bredvid Teams eller på en
/// andra skärm.
///
/// SwiftUI:s fönsterhantering på macOS passar inte en vy som ska styras
/// utifrån och bära ett pågående tillstånd, så fönstret byggs med AppKit.
@MainActor
enum Inspelningsfönster {
    private static var fönster: NSWindow?
    private static let delegat = Delegat()

    static func öppna(kund: Kund, projekt: Projekt?, möte: Kalendern.Möte?) {
        let session = Inspelningssession.delad
        let upptaget = session.pågår || session.läge == .avslutar
        if let f = fönster {
            // Pågår en inspelning visas den som den är. Annars byggs innehållet
            // om för den kund som faktiskt bads om: fönstret kan ha stängts
            // med den röda knappen, och visade då förra kunden — och nästa
            // möte hamnade hos fel kund utan att någon märkte det.
            if !upptaget {
                f.contentView = NSHostingView(rootView: vy(kund: kund, projekt: projekt, möte: möte))
                f.title = möte?.titel ?? kund.namn
            }
            f.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let f = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        f.title = möte?.titel ?? kund.namn
        f.contentView = NSHostingView(rootView: vy(kund: kund, projekt: projekt, möte: möte))
        f.isReleasedWhenClosed = false
        f.delegate = delegat
        f.center()
        // Fönstret ska kunna ligga kvar synligt bredvid mötesverktyget.
        f.level = .normal
        f.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fönster = f
    }

    private static func vy(kund: Kund, projekt: Projekt?, möte: Kalendern.Möte?) -> some View {
        Inspelningsvy(kund: kund, projekt: projekt, möte: möte)
            .environmentObject(Arkivet.shared)
            .environmentObject(Inspelningssession.delad)
            .environmentObject(Adressboken.shared)
    }

    /// Lyfter fram fönstret — eller öppnar det igen om det stängts medan
    /// inspelningen fortsatte i bakgrunden.
    static func visa() {
        if let f = fönster {
            f.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let p = Inspelningssession.delad.placering else { return }
        switch p {
        case .kund(let k):
            öppna(kund: k, projekt: nil, möte: nil)
        case .projekt(let pr):
            guard let k = Arkivet.shared.kunder.first(where: { $0.namn == pr.kundnamn }) else { return }
            öppna(kund: k, projekt: pr, möte: nil)
        }
    }

    static func stäng() {
        fönster?.close()
        fönster = nil
    }

    static var öppet: Bool { fönster?.isVisible == true }

    /// Ser när fönstret stängs, oavsett hur det stängs.
    private final class Delegat: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            Inspelningsfönster.fönster = nil
            // Ett fel eller ett färdigt möte som lämnas kvar i sessionen
            // skulle annars låsa nästa «Spela in».
            Inspelningssession.delad.återställOmKlar()
        }
    }
}
