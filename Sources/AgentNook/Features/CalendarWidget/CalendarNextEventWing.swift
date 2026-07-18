import EventKit
import SwiftUI

/// Compact closed-notch live activity: the next upcoming (or ongoing) event
/// today — calendar-colored capsule, start time ("Now" once started), and a
/// truncated title. Renders nothing when there is no such event or calendar
/// access is missing, so the integrator can include it unconditionally.
///
/// Sized for a wing beside the physical notch (~28-36 pt tall).
struct CalendarNextEventWing: View {
    @ObservedObject private var manager = CalendarManager.shared

    var maxWidth: CGFloat = 150

    var body: some View {
        if let event = manager.nextEvent {
            HStack(spacing: 5) {
                Capsule()
                    .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                    .frame(width: 3, height: 13)
                Text(timeText(for: event))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(event.title ?? "Event")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    private func timeText(for event: EKEvent) -> String {
        guard let start = event.startDate else { return "" }
        if start <= Date() { return "Now" }
        return start.formatted(date: .omitted, time: .shortened)
    }
}
