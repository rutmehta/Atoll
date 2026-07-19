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

    /// Hard cap on the event-title width so the wing never sprawls across the
    /// menu bar (`fixedSize` in the closed-notch container would otherwise let
    /// long titles win over any frame cap).
    var titleMaxWidth: CGFloat = 72

    var body: some View {
        if let event = manager.nextEvent, isImminent(event) {
            HStack(spacing: 5) {
                Capsule()
                    .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                    .frame(width: 3, height: 13)
                Text(timeText(for: event))
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                Text(event.title ?? "Event")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: titleMaxWidth, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    /// Only surface the wing while an event is ongoing or starts within 45 min —
    /// a persistent all-day "next event" banner just eats menu bar space.
    private func isImminent(_ event: EKEvent) -> Bool {
        guard let start = event.startDate else { return false }
        return start.timeIntervalSinceNow < 45 * 60
    }

    private func timeText(for event: EKEvent) -> String {
        guard let start = event.startDate else { return "" }
        if start <= Date() { return "Now" }
        return start.formatted(date: .omitted, time: .shortened)
    }
}
