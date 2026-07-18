import SwiftUI

/// The To-dos widget for the open notch (Tools tab): quick-add field,
/// favorite/complete/delete rows, and a collapsible archive section.
/// Designed for the dark notch background — white text, subtle opacity layers.
struct TodosWidgetView: View {
    @ObservedObject private var store = TodosStore.shared
    @AppStorage("todos.showArchived") private var showArchived = true

    @State private var draft = ""
    @State private var archiveExpanded = false
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            addField
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.todos.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.sortedTodos) { todo in
                            TodoRowView(todo: todo)
                        }
                    }
                    if showArchived && !store.archived.isEmpty {
                        archiveHeader
                        if archiveExpanded {
                            ForEach(store.sortedArchived) { todo in
                                ArchivedTodoRowView(todo: todo)
                            }
                        }
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.todos)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.archived)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Label("To-dos", systemImage: "checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }
        }
    }

    private var summary: String {
        guard !store.todos.isEmpty else { return "" }
        var parts = ["\(store.openCount) open"]
        if store.doneCount > 0 { parts.append("\(store.doneCount) done") }
        return parts.joined(separator: " · ")
    }

    // MARK: Quick add

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.35))
            TextField("Add a to-do…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .focused($addFieldFocused)
                .onSubmit(submitDraft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(addFieldFocused ? 0.10 : 0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture { addFieldFocused = true }
    }

    private func submitDraft() {
        store.add(draft)
        draft = ""
        // Keep focus so several to-dos can be entered in a row.
        addFieldFocused = true
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.25))
            Text("All clear")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("Press Return to add a to-do")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: Archive section

    private var archiveHeader: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                archiveExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(archiveExpanded ? 90 : 0))
                Text("Archived")
                    .font(.system(size: 11, weight: .medium))
                Text("\(store.archived.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

// MARK: - Active row

private struct TodoRowView: View {
    let todo: TodoItem
    @ObservedObject private var store = TodosStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggleDone(todo.id)
            } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(todo.done ? Color.green.opacity(0.85) : Color.white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(todo.done ? "Mark as open" : "Mark as done")

            Text(todo.title)
                .font(.system(size: 12.5))
                .strikethrough(todo.done, color: .white.opacity(0.4))
                .foregroundStyle(todo.done ? Color.white.opacity(0.38) : Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if todo.favorite || hovering {
                Button {
                    store.toggleFavorite(todo.id)
                } label: {
                    Image(systemName: todo.favorite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(todo.favorite ? Color.yellow.opacity(0.9) : Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help(todo.favorite ? "Remove from favorites" : "Pin to top")
                .transition(.opacity)
            }

            if hovering {
                Button {
                    store.delete(todo.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("Delete")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu {
            Button(todo.done ? "Mark as Open" : "Mark as Done") { store.toggleDone(todo.id) }
            Button(todo.favorite ? "Remove Favorite" : "Favorite") { store.toggleFavorite(todo.id) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(todo.id) }
        }
    }
}

// MARK: - Archived row

private struct ArchivedTodoRowView: View {
    let todo: TodoItem
    @ObservedObject private var store = TodosStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.22))

            Text(todo.title)
                .font(.system(size: 12))
                .strikethrough(true, color: .white.opacity(0.25))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if hovering {
                Button {
                    store.restore(todo.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Restore")

                Button {
                    store.deleteArchived(todo.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("Delete permanently")
            } else if let label = completedLabel {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu {
            Button("Restore") { store.restore(todo.id) }
            Button("Delete", role: .destructive) { store.deleteArchived(todo.id) }
        }
    }

    private var completedLabel: String? {
        guard let date = todo.completedAt else { return nil }
        return date.formatted(.relative(presentation: .named))
    }
}
