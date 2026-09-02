import SwiftUI

/// Ett litet blad för att döpa om något: en rad, Avbryt, Spara.
struct Namnblad: View {
    let rubrik: String
    let nuvarande: String
    var förklaring: String?
    var spara: (String) throws -> Void

    @Environment(\.dismiss) private var stäng
    @State private var namn = ""
    @State private var fel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rubrik).font(.headline)
            TextField("Namn", text: $namn)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit(genomför)
            if let förklaring {
                Text(förklaring)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 340, alignment: .leading)
            }
            if let fel {
                Text(fel).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 340, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Avbryt") { stäng() }
                Button("Spara", action: genomför)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rent.isEmpty || rent == nuvarande)
            }
        }
        .padding(20)
        .onAppear { namn = nuvarande }
    }

    private var rent: String { namn.trimmingCharacters(in: .whitespaces) }

    private func genomför() {
        guard !rent.isEmpty, rent != nuvarande else { return }
        do {
            try spara(rent)
            stäng()
        } catch {
            fel = error.localizedDescription
        }
    }
}
