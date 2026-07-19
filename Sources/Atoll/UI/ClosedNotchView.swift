import SwiftUI
import Combine

/// The collapsed notch sliver: live-activity wings either side of the physical
/// notch cutout. Wing content is measured via preference keys and fed back to
/// the view model so the black shape grows to fit.
struct ClosedNotchView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore

    @ObservedObject private var peek = SneakPeekCoordinator.shared
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var agents = AgentSessionStore.shared
    @ObservedObject private var battery = BatteryMonitor.shared

    /// Transient battery/bluetooth event live activity.
    @State private var transientEvent: TransientEvent?
    @State private var transientHideTask: Task<Void, Never>?

    enum TransientEvent: Equatable {
        case battery
        case bluetooth(BluetoothEvent)

        static func == (lhs: TransientEvent, rhs: TransientEvent) -> Bool {
            switch (lhs, rhs) {
            case (.battery, .battery): return true
            case let (.bluetooth(a), .bluetooth(b)):
                return a.deviceName == b.deviceName && a.connected == b.connected
            default: return false
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(height: vm.geometry.notchSize.height)
                .fixedSize()
                .background(WingWidthReader(side: .left))
            Color.clear
                .frame(width: vm.geometry.notchSize.width, height: vm.geometry.notchSize.height)
            rightWing
                .frame(height: vm.geometry.notchSize.height)
                .fixedSize()
                .background(WingWidthReader(side: .right))
        }
        .onPreferenceChange(WingWidthPreferenceKey.self) { widths in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                vm.leftWingWidth = widths[.left] ?? 0
                vm.rightWingWidth = widths[.right] ?? 0
            }
        }
        .onReceive(BatteryMonitor.shared.events) { _ in
            showTransient(.battery)
        }
        .onReceive(BluetoothMonitor.shared.events) { event in
            showTransient(.bluetooth(event))
        }
    }

    // MARK: Wing content

    @ViewBuilder
    private var leftWing: some View {
        if peek.visible {
            HUDWingLeftView()
                .frame(width: 96)
                .padding(.leading, 8)
        } else if case .battery = transientEvent, settings.batteryLiveActivity {
            Text(battery.eventStatusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(batteryEventColor)
                .lineLimit(1)
                .padding(.leading, 10)
                .padding(.trailing, 4)
        } else if settings.mediaLiveActivity {
            MediaClosedWingLeft()
                .padding(.leading, 7)
                .padding(.trailing, 3)
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if peek.visible {
            HUDWingRightView()
                .frame(width: 96)
                .padding(.trailing, 8)
        } else if let event = transientEvent {
            switch event {
            case .battery:
                if settings.batteryLiveActivity {
                    BatteryWingView(variant: .event)
                        .padding(.horizontal, 8)
                }
            case .bluetooth(let btEvent):
                BluetoothEventWingView(event: btEvent)
                    .padding(.horizontal, 8)
            }
        } else {
            HStack(spacing: 7) {
                if settings.mediaLiveActivity {
                    MediaClosedWingRight()
                }
                if settings.timerLiveActivity {
                    TimerClosedWing()
                }
                if settings.agentsLiveActivity {
                    AgentsClosedWingView(onTap: { vm.open(tab: .agents) })
                }
                CalendarNextEventWing()
                TodoCountWing()
            }
            .padding(.leading, 3)
            .padding(.trailing, hasAnyRightContent ? 8 : 0)
        }
    }

    private var hasAnyRightContent: Bool {
        (settings.mediaLiveActivity && music.playback != nil)
            || (settings.agentsLiveActivity && agents.liveSessionCount > 0)
    }

    private var batteryEventColor: Color {
        if case .lowBattery = battery.lastEvent { return .red }
        return battery.isCharging || battery.isCharged ? .green : .white
    }

    private func showTransient(_ event: TransientEvent) {
        transientHideTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            transientEvent = event
        }
        transientHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                transientEvent = nil
            }
        }
    }
}

// MARK: - Wing width measurement

enum WingSide: Hashable {
    case left, right
}

struct WingWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [WingSide: CGFloat] = [:]
    static func reduce(value: inout [WingSide: CGFloat], nextValue: () -> [WingSide: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private struct WingWidthReader: View {
    let side: WingSide

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WingWidthPreferenceKey.self, value: [side: proxy.size.width])
        }
    }
}
