import SwiftUI

/// Settings pane for the Notes widget. Add to the settings window as a
/// "Notes" tab/section.
struct NotesSettingsView: View {
    @ObservedObject private var store = NotesStore.shared

    @AppStorage("notes.fontSize") private var fontSize = 13.0
    @AppStorage("notes.sortOrder") private var sortOrderRaw = NotesSortOrder.recentlyEdited.rawValue

    var body: some View {
        Form {
            Section("Editor") {
                HStack {
                    Text("Font size")
                    Slider(value: $fontSize, in: 11...18, step: 1)
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Section("Note list") {
                Picker("Sort notes by", selection: $sortOrderRaw) {
                    ForEach(NotesSortOrder.allCases) { order in
                        Text(order.label).tag(order.rawValue)
                    }
                }
            }
            Section("Storage") {
                LabeledContent("Notes", value: "\(store.notes.count)")
                Button("Reveal Notes File in Finder") {
                    store.revealInFinder()
                }
            }
        }
        .formStyle(.grouped)
    }
}
