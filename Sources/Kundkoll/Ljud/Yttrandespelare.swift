import Foundation
import AVFoundation

/// Spelar upp mötet och säger vilken rad som hörs.
///
/// Transkriptet är whispers ord; ljudet är facit. En rad i taget räckte
/// för att kolla ett ord, men för att följa ett resonemang vill man höra
/// mötet rulla och se raden flytta sig. Tvåspåriga inspelningar spelas
/// med båda spåren samtidigt, startade på samma klockslag så att de ligger
/// i takt; en importerad fil har allt i ett spår.
@MainActor
final class Yttrandespelare: ObservableObject {

    /// Raden som hörs just nu: den senast påbörjade vid uppspelningens tid.
    @Published private(set) var aktuell: UUID?
    @Published private(set) var tid: Double = 0
    @Published private(set) var igång = false
    @Published private(set) var längd: Double = 0

    var harLjud: Bool { !spelare.isEmpty }

    private var spelare: [AVAudioPlayer] = []
    private var yttranden: [Yttrande] = []
    private var klocka: Timer?
    private var startade = Date.distantPast

    /// Vilka spår ett möte har. Tvåspåriga inspelningar har mitt ljud för
    /// sig; i en importerad fil ligger alla röster i motpart.wav.
    static func spår(i mapp: URL, enspårig: Bool) -> [URL] {
        let namn = enspårig ? ["motpart.wav"] : ["jag.wav", "motpart.wav"]
        return namn.map { mapp.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Öppnar mötets spår. Anropas när vyn visas och när mötet byts.
    func ladda(mapp: URL, inspelning: Inspelning) {
        sluta()
        yttranden = inspelning.yttranden.sorted { $0.start < $1.start }
        spelare = Self.spår(i: mapp, enspårig: inspelning.enspårig)
            .compactMap { try? AVAudioPlayer(contentsOf: $0) }
        for p in spelare { p.prepareToPlay() }
        längd = spelare.map(\.duration).max() ?? 0
    }

    func växla() { igång ? pausa() : spela() }

    func spela() {
        guard !spelare.isEmpty else { return }
        if tid >= längd - 0.05 { tid = 0 }
        for p in spelare { p.currentTime = min(tid, max(0, p.duration - 0.01)) }
        // Samma starttid på ljudklockan: annars glider spåren isär med några
        // tiotal millisekunder, och ett svar hörs innan frågan är slut.
        let start = (spelare.first?.deviceCurrentTime ?? 0) + 0.05
        for p in spelare { p.play(atTime: start) }
        igång = true
        startade = Date()
        aktuell = Self.rad(vid: tid, i: yttranden)
        klocka?.invalidate()
        klocka = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pausa() {
        for p in spelare { p.pause() }
        klocka?.invalidate()
        klocka = nil
        igång = false
    }

    func hoppa(till sekunder: Double) {
        let varIgång = igång
        pausa()
        tid = max(0, min(längd, sekunder))
        aktuell = Self.rad(vid: tid, i: yttranden)
        if varIgång { spela() }
    }

    /// Spelar från radens början — eller pausar, om det är just den som hörs.
    func växla(_ y: Yttrande) {
        if aktuell == y.id && igång {
            pausa()
            return
        }
        pausa()
        tid = max(0, y.start)
        spela()
    }

    func sluta() {
        for p in spelare { p.stop() }
        klocka?.invalidate()
        klocka = nil
        spelare = []
        yttranden = []
        igång = false
        tid = 0
        aktuell = nil
        längd = 0
    }

    private func tick() {
        guard igång, let första = spelare.first else { return }
        // isPlaying faller när spåret tagit slut, och currentTime nollas.
        // Strax efter starten är spelaren ännu inte igång på riktigt.
        if !första.isPlaying, Date().timeIntervalSince(startade) > 0.3 {
            pausa()
            tid = längd
            aktuell = Self.rad(vid: tid, i: yttranden)
            return
        }
        tid = första.currentTime
        let ny = Self.rad(vid: tid, i: yttranden)
        if ny != aktuell { aktuell = ny }
    }

    /// Den senast påbörjade raden vid en viss tid. Mellan två rader hålls
    /// den förra kvar, så att markeringen inte blinkar i varje paus.
    static func rad(vid tid: Double, i yttranden: [Yttrande]) -> UUID? {
        var träff: UUID?
        for y in yttranden {
            if y.start <= tid + 0.05 { träff = y.id } else { break }
        }
        return träff
    }
}
