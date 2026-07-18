import SwiftUI

// MARK: - BatteryWingView

/// Compact battery view for a closed-notch wing (~28–36 pt tall).
///
/// - `.indicator`: battery glyph (plus % text when the "always show percentage"
///   setting is on). Suitable as a persistent right-wing indicator.
/// - `.event`: status text ("Charging", "Fully Charged", …) + percentage + glyph.
///   The integrator shows this for ~3 s whenever `BatteryMonitor.shared.events` fires.
@MainActor
struct BatteryWingView: View {
    enum Variant {
        case indicator
        case event
    }

    var variant: Variant = .indicator

    @ObservedObject private var monitor = BatteryMonitor.shared
    @AppStorage("systemEvents.showBatteryPercentAlways") private var showPercentAlways = false

    var body: some View {
        if monitor.hasBattery {
            switch variant {
            case .indicator: indicator
            case .event: eventBody
            }
        }
    }

    private var indicator: some View {
        HStack(spacing: 5) {
            if showPercentAlways {
                percentText
            }
            glyph
        }
        .frame(height: 28)
        .padding(.horizontal, 2)
    }

    private var eventBody: some View {
        HStack(spacing: 8) {
            Text(monitor.eventStatusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusTextColor)
                .lineLimit(1)
                .fixedSize()
            percentText
            glyph
        }
        .frame(height: 28)
        .padding(.horizontal, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var percentText: some View {
        Text("\(monitor.percentage)%")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize()
    }

    private var glyph: some View {
        BatteryGlyph(
            level: Double(monitor.percentage) / 100.0,
            charging: monitor.isCharging,
            tint: fillColor
        )
    }

    private var fillColor: Color {
        if monitor.isLowPowerMode { return .yellow }
        if monitor.isCharging || (monitor.isPluggedIn && monitor.percentage >= 95) { return .green }
        if monitor.percentage <= 20 { return .red }
        return .white.opacity(0.9)
    }

    private var statusTextColor: Color {
        guard let event = monitor.lastEvent else { return .white }
        switch event {
        case .pluggedIn, .chargedFull:
            return .green
        case .lowBattery:
            return .red
        case .lowPowerModeChanged(let enabled):
            return enabled ? .yellow : .white
        case .unplugged:
            return .white
        }
    }
}

// MARK: - Battery glyph

/// Hand-drawn battery outline with proportional fill, terminal nub and charging bolt.
private struct BatteryGlyph: View {
    var level: Double // 0...1
    var charging: Bool
    var tint: Color

    private let bodyWidth: CGFloat = 25
    private let bodyHeight: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(tint)
                    .frame(width: fillWidth)
                    .padding(2.5)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .frame(width: bodyWidth, height: bodyHeight)
                }
            }
            .frame(width: bodyWidth, height: bodyHeight)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.white.opacity(0.4))
                .frame(width: 2, height: 5)
        }
        .animation(.easeInOut(duration: 0.35), value: level)
        .animation(.easeInOut(duration: 0.35), value: charging)
        .accessibilityLabel("Battery \(Int((level * 100).rounded())) percent\(charging ? ", charging" : "")")
    }

    private var fillWidth: CGFloat {
        let inner = bodyWidth - 5
        return max(2.5, inner * CGFloat(min(1, max(0, level))))
    }
}

// MARK: - BluetoothEventWingView

/// Compact Bluetooth connect/disconnect view for a closed-notch wing.
/// Pass an explicit `event`, or omit it to render `BluetoothMonitor.shared.lastEvent`.
/// The integrator shows it for ~3 s whenever `BluetoothMonitor.shared.events` fires.
@MainActor
struct BluetoothEventWingView: View {
    var event: BluetoothEvent?

    @ObservedObject private var monitor = BluetoothMonitor.shared

    init(event: BluetoothEvent? = nil) {
        self.event = event
    }

    private var displayedEvent: BluetoothEvent? {
        event ?? monitor.lastEvent
    }

    var body: some View {
        if let displayedEvent {
            HStack(spacing: 7) {
                Image(systemName: displayedEvent.deviceKind.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        displayedEvent.connected
                            ? Color(red: 0.36, green: 0.63, blue: 1.0)
                            : Color.white.opacity(0.45)
                    )
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayedEvent.deviceName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(displayedEvent.connected ? "Connected" : "Disconnected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(height: 28)
            .frame(maxWidth: 170, alignment: .leading)
            .padding(.horizontal, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
