import SwiftUI

/// Settings pane for the To-dos widget; the integrator adds it as a
/// section/tab of the settings window. Uses standard system styling
/// (the settings window is a normal light/dark window, not the notch).
struct TodosSettingsView: View {
    @AppStorage("todos.autoArchiveHours") private var autoArchiveHours = 24.0
    @AppStorage("todos.showArchived") private var showArchived = true
    @ObservedObject private var store = TodosStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Auto-archive completed", selection: $autoArchiveHours) {
                    Text("After 1 hour").tag(1.0)
                    Text("After 6 hours").tag(6.0)
                    Text("After 12 hours").tag(12.0)
                    Text("After 24 hours").tag(24.0)
                    Text("After 2 days").tag(48.0)
                    Text("After 1 week").tag(168.0)
                    Text("Never").tag(0.0)
                }
                .onChange(of: autoArchiveHours) { _, _ in
                    store.archiveSweep()
                }
                Toggle("Show archived section in widget", isOn: $showArchived)
            } header: {
                Text("To-dos")
            } footer: {
                Text("Completed to-dos stay visible (struck through) until the auto-archive delay passes, then move to the archive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Archive") {
                LabeledContent("Archived items", value: "\(store.archived.count)")
                Button("Clear Archive", role: .destructive) {
                    store.clearArchive()
                }
                .disabled(store.archived.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}
