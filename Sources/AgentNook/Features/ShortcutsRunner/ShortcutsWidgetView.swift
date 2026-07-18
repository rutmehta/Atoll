import SwiftUI

/// Grid of runnable shortcut chips for the open notch (Tools tab).
/// Dark-theme styling: white text on subtle translucent chips.
struct ShortcutsWidgetView: View {
    @ObservedObject private var manager = ShortcutsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { manager.refreshOnAppear() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Shortcuts", systemImage: "app.connected.to.app.below.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .layoutPriority(1)

            searchField

            Button {
                manager.refresh()
            } label: {
                Group {
                    if manager.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .disabled(manager.isLoading)
            .help("Refresh shortcut list")
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            TextField("Search", text: $manager.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            if !manager.searchText.isEmpty {
                Button {
                    manager.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        .frame(maxWidth: 220)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch manager.loadState {
        case .unavailable(let message):
            ShortcutsEmptyStateView(
                icon: "questionmark.app.dashed",
                title: "Shortcuts Unavailable",
                message: message,
                actionTitle: "Try Again",
                action: { manager.refresh() }
            )
        case .failed(let message):
            ShortcutsEmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't Load Shortcuts",
                message: message,
                actionTitle: "Retry",
                action: { manager.refresh() }
            )
        case .idle, .loading:
            if manager.allShortcuts.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Loading shortcuts…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        case .loaded:
            if manager.allShortcuts.isEmpty {
                ShortcutsEmptyStateView(
                    icon: "app.connected.to.app.below.fill",
                    title: "No Shortcuts Yet",
                    message: "Create shortcuts in the Shortcuts app and they will show up here.",
                    actionTitle: "Open Shortcuts",
                    action: { manager.openShortcutsApp() }
                )
            } else if manager.widgetShortcuts.isEmpty {
                if manager.searchText.isEmpty {
                    ShortcutsEmptyStateView(
                        icon: "eye.slash",
                        title: "All Shortcuts Hidden",
                        message: "Every shortcut is hidden. Show some again from AgentNook settings.",
                        actionTitle: "Unhide All",
                        action: { manager.unhideAll() }
                    )
                } else {
                    ShortcutsEmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matches",
                        message: "No shortcut name contains \u{201C}\(manager.searchText)\u{201D}.",
                        actionTitle: "Clear Search",
                        action: { manager.searchText = "" }
                    )
                }
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118, maximum: 220), spacing: 8)],
                spacing: 8
            ) {
                ForEach(manager.widgetShortcuts) { item in
                    ShortcutsChipView(manager: manager, item: item)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Chip

private struct ShortcutsChipView: View {
    @ObservedObject var manager: ShortcutsManager
    let item: ShortcutsItem
    @State private var hovering = false

    private var isRunning: Bool { manager.runningNames.contains(item.name) }
    private var outcome: ShortcutsRunOutcome? { manager.recentOutcomes[item.name] }
    private var isFavorite: Bool { manager.isFavorite(item.name) }

    var body: some View {
        HStack(spacing: 6) {
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(isRunning ? 0.5 : 0.92))

            Spacer(minLength: 2)

            trailingAccessory
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(fillColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .overlay(runOverlay)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard !isRunning else { return }
            manager.run(item)
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: outcome)
        .animation(.easeInOut(duration: 0.2), value: isRunning)
        .help("Run \u{201C}\(item.name)\u{201D}")
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                manager.toggleFavorite(item.name)
            }
            Button("Hide from Widget") {
                manager.setHidden(item.name, true)
            }
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if let outcome {
            Image(systemName: outcome == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(outcome == .success ? Color.green : Color.red)
                .transition(.scale.combined(with: .opacity))
        } else if isRunning {
            // Space is held by the run overlay's spinner.
            Color.clear.frame(width: 12, height: 12)
        } else if hovering || isFavorite {
            Button {
                manager.toggleFavorite(item.name)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.yellow.opacity(0.92) : Color.white.opacity(0.5))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Favorite — floats to the top")
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var runOverlay: some View {
        if isRunning {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.35))
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .tint(.white)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private var fillColor: Color {
        switch outcome {
        case .success: return Color.green.opacity(0.22)
        case .failure: return Color.red.opacity(0.24)
        case nil:
            return hovering && !isRunning
                ? Color.white.opacity(0.14)
                : Color.white.opacity(0.07)
        }
    }

    private var borderColor: Color {
        switch outcome {
        case .success: return Color.green.opacity(0.65)
        case .failure: return Color.red.opacity(0.65)
        case nil: return Color.white.opacity(hovering ? 0.14 : 0.06)
        }
    }
}

// MARK: - Empty state

private struct ShortcutsEmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
