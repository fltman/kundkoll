import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// En bit ljud från ett av de två spåren.
struct Ljudram {
    let röst: Röst
    let buffert: AVAudioPCMBuffer
    /// Sekunder från strömmens start.
    let tid: Double
}

/// Fångar vald mikrofon och datorljudet som två skilda spår.
///
/// ScreenCaptureKit lämnar dem separat (`.microphone` respektive `.audio`),
/// vilket är hela poängen: att de är åtskilda ger "vem sa vad" utan diarisering.
/// En SCStream måste ha ett innehållsfilter även när bara ljudet är intressant,
/// så vi fångar minsta möjliga bildyta och slänger rutorna.
@MainActor
final class Ljudinfångning: NSObject {

    /// Anropas för varje inkommande ljudbit, på en bakgrundskö.
    var vidRam: ((Ljudram) -> Void)?
    var vidFel: ((Error) -> Void)?

    private var ström: SCStream?
    private var nolltid: CMTime?
    private let kö = DispatchQueue(label: "kundkoll.ljud", qos: .userInitiated)

    static let samplingsfrekvens = 48_000

    // MARK: - Mikrofoner

    struct Mikrofon: Identifiable, Hashable {
        let id: String
        let namn: String
    }

    static func mikrofoner() -> [Mikrofon] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { Mikrofon(id: $0.uniqueID, namn: $0.localizedName) }
    }

    // MARK: - Behörigheter

    /// Skärminspelning krävs för datorljudet. Anropet väcker systemdialogen
    /// första gången och returnerar falskt tills användaren har godkänt.
    static func harSkärmbehörighet() async -> Bool {
        (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)) != nil
    }

    static func begärMikrofon() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Kör

    func starta(mikrofonID: String?) async throws {
        // Nolltiden hör till strömmen. Buffertar som redan låg i kön när
        // förra strömmen stoppades hinner sätta den efter `stoppa()`, och då
        // skulle nästa möte räkna sina tider från förra mötets slut.
        nolltid = nil
        let innehåll = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let skärm = innehåll.displays.first else { throw Fel.ingenSkärm }

        let konf = SCStreamConfiguration()
        // Minsta tillåtna bildyta, långsammast möjliga takt. Rutorna kastas.
        konf.width = 2
        konf.height = 2
        konf.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        konf.queueDepth = 5
        konf.showsCursor = false

        konf.capturesAudio = true
        konf.sampleRate = Self.samplingsfrekvens
        konf.channelCount = 2
        konf.excludesCurrentProcessAudio = true   // annars hör vi oss själva
        konf.captureMicrophone = true
        konf.microphoneCaptureDeviceID = mikrofonID

        let filter = SCContentFilter(display: skärm, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: konf, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: kö)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: kö)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: kö)
        try await s.startCapture()
        ström = s
    }

    func stoppa() async {
        guard let s = ström else { return }
        ström = nil
        nolltid = nil
        try? await s.stopCapture()
    }

    enum Fel: LocalizedError {
        case ingenSkärm
        var errorDescription: String? {
            switch self {
            case .ingenSkärm: "Hittade ingen skärm att fånga ljudet ifrån."
            }
        }
    }
}

extension Ljudinfångning: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.vidFel?(error) }
    }
}

extension Ljudinfångning: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        let röst: Röst
        switch type {
        case .audio: röst = .motpart
        case .microphone: röst = .jag
        default: return                       // bildrutorna är bara till för att strömmen ska få finnas
        }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let buffert = Self.pcm(ur: sampleBuffer) else { return }

        let pts = sampleBuffer.presentationTimeStamp
        Task { @MainActor in
            if self.nolltid == nil { self.nolltid = pts }
            let noll = self.nolltid ?? pts
            let tid = max(0, (pts - noll).seconds)
            self.vidRam?(Ljudram(röst: röst, buffert: buffert, tid: tid))
        }
    }

    /// Kopierar ljudet ur CMSampleBuffer. Kopian är nödvändig: bufferten från
    /// ScreenCaptureKit återanvänds så fort vi lämnat den här metoden.
    private nonisolated static func pcm(ur sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sample.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let ramar = AVAudioFrameCount(sample.numSamples)
        guard let mål = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: ramar) else { return nil }
        mål.frameLength = ramar

        do {
            try sample.withAudioBufferList { lista, _ in
                guard let källa = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: lista.unsafePointer)
                else { return }
                let bytes = min(källa.audioBufferList.pointee.mBuffers.mDataByteSize,
                                mål.audioBufferList.pointee.mBuffers.mDataByteSize)
                for i in 0..<Int(källa.audioBufferList.pointee.mNumberBuffers) {
                    let k = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: källa.audioBufferList))[i]
                    let m = UnsafeMutableAudioBufferListPointer(mål.mutableAudioBufferList)[i]
                    if let src = k.mData, let dst = m.mData {
                        memcpy(dst, src, Int(min(k.mDataByteSize, m.mDataByteSize)))
                    }
                }
                _ = bytes
            }
        } catch { return nil }
        return mål
    }
}
