import SwiftUI

extension Notification.Name {
    static let agentNookOpenSettings = Notification.Name("Atoll.openSettings")
}

/// The expanded notch hub: tab bar + active feature pane.
struct OpenNotchView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var agents = AgentSessionStore.shared

    private var visibleTabs: [NotchTab] {
        let names = Set(settings.visibleTabsCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let tabs = NotchTab.allCases.filter { $0 == .home || names.contains($0.rawValue) }
        return tabs.isEmpty ? [.home] : tabs
    }

    enum ToolPane: String, CaseIterable, Identifiable {
        case timers = "Timers"
        case notes = "Notes"
        case todos = "To-dos"
        case shortcuts = "Shortcuts"
        case mirror = "Mirror"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .timers: return "timer"
            case .notes: return "note.text"
            case .todos: return "checklist"
            case .shortcuts: return "app.connected.to.app.below.fill"
            case .mirror: return "web.camera"
            }
        }
    }

    @AppStorage("tools.selectedPane") private var toolPaneRaw = ToolPane.timers.rawValue

    var body: some View {
        VStack(spacing: 6) {
            tabBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, vm.geometry.notchSize.height + 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 5) {
            ForEach(visibleTabs) { tab in
                tabButton(tab)
            }
            Spacer()
            Button {
                vm.isPinned.toggle()
                if vm.isPinned { vm.cancelPendingClose() }
            } label: {
                Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(vm.isPinned ? settings.accentColor : Color.white.opacity(0.55))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(vm.isPinned ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .help(vm.isPinned ? "Unpin the nook" : "Keep the nook open")
            Button {
                NotificationCenter.default.post(name: .agentNookOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Atoll Settings")
        }
    }

    private func tabButton(_ tab: NotchTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                vm.tab = tab
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(vm.tab == tab ? Color.white.opacity(0.16) : .clear)
            )
            .overlay(alignment: .topTrailing) {
                if tab == .agents, agents.attention {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Panes

    @ViewBuilder
    private var content: some View {
        switch vm.tab {
        case .home:
            switch settings.homeLayout {
            case "mediaOnly":
                MediaPlayerCard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case "calendarOnly":
                CalendarWidgetView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                HStack(spacing: 10) {
                    MediaPlayerCard()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    CalendarWidgetView()
                        .frame(width: 232)
                        .frame(maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                }
            }
        case .shelf:
            ShelfView()
        case .agents:
            AgentsPanelView(onDismiss: { vm.close() })
        case .tools:
            HStack(spacing: 8) {
                toolRail
                toolContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var toolPane: ToolPane {
        ToolPane(rawValue: toolPaneRaw) ?? .timers
    }

    private var toolRail: some View {
        VStack(spacing: 4) {
            ForEach(ToolPane.allCases) { pane in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        toolPaneRaw = pane.rawValue
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: pane.systemImage)
                            .font(.system(size: 13, weight: .medium))
                        Text(pane.rawValue)
                            .font(.system(size: 8.5))
                    }
                    .frame(width: 52, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(toolPane == pane ? Color.white.opacity(0.16) : Color.white.opacity(0.04))
                    )
                    .foregroundStyle(toolPane == pane ? .white : Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var toolContent: some View {
        switch toolPane {
        case .timers: TimersWidgetView()
        case .notes: NotesWidgetView()
        case .todos: TodosWidgetView()
        case .shortcuts: ShortcutsWidgetView()
        case .mirror: MirrorView()
        }
    }
}
