import SwiftUI
import AppKit

/// Om appen: vem som gjort den, var den bor, och hur man stöder den.
struct Omvy: View {
    @Environment(\.dismiss) private var stäng

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 3) {
                Text(Appnamn.visat).font(.title2.weight(.semibold))
                Text("Version \(Appnamn.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Möten, mejl och åtaganden per kund. Ljudet och transkriberingen "
                 + "stannar på din dator.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Link(destination: Appnamn.hemsida) {
                    Label("anders.bjarby.com", systemImage: "globe")
                }
                Link(destination: Appnamn.patreon) {
                    Label("Stöd projektet på Patreon", systemImage: "heart")
                }
            }
            .padding(.vertical, 4)

            Text("Av Anders Bjarby, Brattoo AB. Öppen källkod under MIT.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Stäng") { stäng() }
                .accessibilityIdentifier("om.stäng")
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 360)
    }
}
