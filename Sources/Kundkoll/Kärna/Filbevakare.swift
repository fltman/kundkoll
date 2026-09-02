import Foundation
import CoreServices

/// Ser när något ändras under kundmappen — i Finder, i Obsidian, från en
/// annan dator via en synkad mapp — och säger till arkivet.
///
/// FSEvents och inte en DispatchSource: den senare ser bara en mapp i taget,
/// och kundmappen är ett träd. Egna skrivningar hoppas över (IgnoreSelf):
/// arkivet räknar redan upp `sparningar` när det själv skriver, och
/// wav-filerna växer hela tiden under ett möte.
///
/// Utan det här syntes en kund som skapats i Finder först efter omstart,
/// och en anteckning som ändrats i Obsidian först när listan råkade läsas om.
final class Filbevakare {
    private var ström: FSEventStreamRef?
    private let kö = DispatchQueue(label: "kundkoll.filbevakning", qos: .utility)
    fileprivate let vidÄndring: @Sendable ([String]) -> Void

    init(rot: URL, vidÄndring: @escaping @Sendable ([String]) -> Void) {
        self.vidÄndring = vidÄndring
        var sammanhang = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flaggor = UInt32(kFSEventStreamCreateFlagUseCFTypes
                             | kFSEventStreamCreateFlagFileEvents
                             | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.tog, &sammanhang,
            [rot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,                                   // sammanslaget i sekunder
            flaggor)
        else { return }
        FSEventStreamSetDispatchQueue(s, kö)
        FSEventStreamStart(s)
        ström = s
    }

    deinit {
        if let s = ström {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    private static let tog: FSEventStreamCallback = { _, info, antal, vägar, _, _ in
        guard let info, antal > 0 else { return }
        let bevakare = Unmanaged<Filbevakare>.fromOpaque(info).takeUnretainedValue()
        let lista = unsafeBitCast(vägar, to: NSArray.self) as? [String] ?? []
        bevakare.vidÄndring(lista)
    }
}
