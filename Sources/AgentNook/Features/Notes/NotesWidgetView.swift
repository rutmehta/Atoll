import AppKit
import SwiftUI

/// Quick-notes pane for the open notch: note list on the left, editor on the
/// right. Designed for the dark notch background (~600×300, flexible).
struct NotesWidgetView: View {
    @ObservedObject private var store = NotesStore.shared

    @AppStorage("notes.fontSize") private var fontSize = 13.0
    @AppStorage("notes.sortOrder") private var sortOrderRaw = NotesSortOrder.recentlyEdited.rawValue
    @AppStorage("notes.selectedNoteID") private var selectedNoteIDRaw = ""

    @FocusState private var editorFocused: Bool
    @State private var hostWindow: NSWindow?
    @State private var justCopied = false

    private var sortOrder: NotesSortOrder {
        NotesSortOrder(rawValue: sortOrderRaw) ?? .recentlyEdited
    }

    private var sortedNotes: [NotesItem] {
        sortOrder.sorted(store.notes)
    }

    private var selectedID: UUID? {
        UUID(uuidString: selectedNoteIDRaw)
    }

    private var selectedNote: NotesItem? {
        store.note(id: selectedID)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { _ in
            HStack(spacing: 12) {
                sidebar
                    .frame(width: 185)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 2)
                editorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(NotesWindowAccessor { window in hostWindow = window })
        .onAppear { ensureSelection() }
        .onChange(of: store.notes) { _, _ in ensureSelection() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                if !store.notes.isEmpty {
                    Text("\(store.notes.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                Spacer()
                Button(action: newNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, 2)

            if store.notes.isEmpty {
                sidebarEmptyState
            } else {
                noteList
            }
        }
    }

    private var noteList: some View {
        List {
            ForEach(sortedNotes) { note in
                NotesRowView(note: note, isSelected: note.id == selectedID)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { select(note.id) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            duplicate(note)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button {
                            copyToPasteboard(note.text)
                        } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            delete(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 10)
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 22))
                .foregroundStyle(Color.white.opacity(0.3))
            Text("No notes yet")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Editor

    @ViewBuilder
    private var editorPane: some View {
        if let note = selectedNote {
            VStack(spacing: 6) {
                editorHeader(note)
                editor(note)
            }
        } else {
            editorEmptyState
        }
    }

    private func editorHeader(_ note: NotesItem) -> some View {
        HStack(spacing: 10) {
            Text("Edited \(NotesRelativeDate.string(from: note.updatedAt))")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
            Spacer()
            if !note.text.isEmpty {
                Text("\(note.text.count) characters")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            Button {
                copyToPasteboard(note.text)
                withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation(.easeIn(duration: 0.2)) { justCopied = false }
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(justCopied ? Color.green.opacity(0.9) : Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(note.text.isEmpty)
            .help("Copy note")
            Button {
                delete(note)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete note")
        }
        .padding(.horizontal, 4)
    }

    private func editor(_ note: NotesItem) -> some View {
        ZStack(alignment: .topLeading) {
            if note.text.isEmpty {
                Text("Start typing…")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.top, 6)
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
            }
            TextEditor(text: editorTextBinding)
                .font(.system(size: fontSize))
                .lineSpacing(2)
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(6)
                .onExitCommand {
                    // Esc leaves the editor without closing the notch; key
                    // status returns to normal notch behavior.
                    editorFocused = false
                    hostWindow?.makeFirstResponder(nil)
                }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .onChange(of: editorFocused) { _, focused in
            // The notch panel is non-activating; explicitly become key so
            // keystrokes reach the editor.
            if focused { hostWindow?.makeKey() }
        }
    }

    private var editorEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.3))
            Text(store.notes.isEmpty ? "Jot something down" : "No note selected")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
            Button(action: newNote) {
                Label("New Note", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private var editorTextBinding: Binding<String> {
        Binding(
            get: { store.note(id: selectedID)?.text ?? "" },
            set: { newValue in
                guard let id = selectedID else { return }
                store.updateText(newValue, for: id)
            }
        )
    }

    private func ensureSelection() {
        if store.note(id: selectedID) == nil {
            selectedNoteIDRaw = sortedNotes.first?.id.uuidString ?? ""
        }
    }

    private func select(_ id: UUID) {
        selectedNoteIDRaw = id.uuidString
    }

    private func newNote() {
        let note = store.createNote()
        select(note.id)
        focusEditor()
    }

    private func duplicate(_ note: NotesItem) {
        if let copy = store.duplicateNote(id: note.id) {
            select(copy.id)
        }
    }

    private func delete(_ note: NotesItem) {
        let wasSelected = note.id == selectedID
        let remaining = sortedNotes.filter { $0.id != note.id }
        store.deleteNote(id: note.id)
        if wasSelected {
            selectedNoteIDRaw = remaining.first?.id.uuidString ?? ""
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func focusEditor() {
        if let window = hostWindow, window.canBecomeKey {
            window.makeKey()
        }
        DispatchQueue.main.async {
            editorFocused = true
        }
    }
}

// MARK: - Row

private struct NotesRowView: View {
    let note: NotesItem
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.firstLinePreview)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(note.isEmpty ? Color.white.opacity(0.45) : .white)
                .lineLimit(1)
            Text(NotesRelativeDate.string(from: note.updatedAt))
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.14)
                        : hovering ? Color.white.opacity(0.06) : Color.clear
                )
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Relative date

private enum NotesRelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Window access

/// Invisible helper that reports the hosting NSWindow so the widget can make
/// the (non-activating) notch panel key when the editor takes focus.
private struct NotesWindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NotesWindowSpyView {
        let view = NotesWindowSpyView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ view: NotesWindowSpyView, context: Context) {
        view.onResolve = onResolve
    }
}

private final class NotesWindowSpyView: NSView {
    var onResolve: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = window
        DispatchQueue.main.async { [weak self] in
            self?.onResolve?(window)
        }
    }
}
