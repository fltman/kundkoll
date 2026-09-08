// Ett riktigt musklick på en skärmpunkt, via CGEvent. System Events «click at»
// når inte SwiftUI-vyer med onTapGesture (kort, rader), det här gör det.
//   swift scripts/hjalp/klick.swift X Y
import Cocoa
let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else {
    FileHandle.standardError.write("användning: klick.swift X Y\n".data(using: .utf8)!); exit(2)
}
let p = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
