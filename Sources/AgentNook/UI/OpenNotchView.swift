import SwiftUI

/// The expanded notch hub: tab bar + active feature view.
struct OpenNotchView: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 8) {
            tabBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, vm.geometry.notchSize.height + 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        vm.tab = tab
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(vm.tab == tab ? Color.white.opacity(0.15) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.tab {
        case .home:
            PlaceholderPane(title: "Now Playing", icon: "play.circle")
        case .shelf:
            PlaceholderPane(title: "Shelf", icon: "tray.full")
        case .agents:
            PlaceholderPane(title: "Agent Sessions", icon: "sparkles.rectangle.stack")
        case .tools:
            PlaceholderPane(title: "Tools", icon: "wrench.and.screwdriver")
        }
    }
}

struct PlaceholderPane: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
