import EventKit
import SwiftUI

/// Open-notch calendar pane: day header with prev/next paging + Today button,
/// scrolling event list, permission prompts, empty state.
/// Designed for the black expanded notch (white/secondary text on dark).
struct CalendarWidgetView: View {
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        VStack(spacing: 8) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { manager.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(manager.displayedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(manager.displayedDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 4)

            if !manager.isDisplayingToday {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        manager.goToToday()
                    }
                } label: {
                    Text("Today")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            pagerButton(systemImage: "chevron.left", help: "Previous day") {
                manager.goToPreviousDay()
            }
            pagerButton(systemImage: "chevron.right", help: "Next day") {
                manager.goToNextDay()
            }
        }
    }

    private func pagerButton(systemImage: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { action() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch manager.authorizationStatus {
        case .fullAccess:
            if manager.displayedEvents.isEmpty {
                emptyState
            } else {
                eventList
            }
        case .notDetermined:
            CalendarPermissionPrompt(
                message: "See your day at a glance right in the notch.",
                buttonTitle: "Enable Calendar Access",
                isWorking: manager.isRequestingAccess
            ) {
                manager.requestAccess()
            }
        default: // .denied, .restricted, .writeOnly, @unknown
            CalendarPermissionPrompt(
                message: "Calendar access is turned off. Grant full access in System Settings to see your events.",
                buttonTitle: "Open System Settings",
                isWorking: false
            ) {
                manager.openCalendarPrivacySettings()
            }
        }
    }

    private var eventList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(manager.displayedEvents, id: \.calendarRowID) { event in
                    CalendarEventRow(event: event) {
                        manager.openInCalendarApp(event)
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("No events")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Event row

private struct CalendarEventRow: View {
    let event: EKEvent
    let onOpen: () -> Void

    @State private var isHovered = false

    private var calendarColor: Color {
        Color(nsColor: event.calendar?.color ?? .systemBlue)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 9) {
                Capsule()
                    .fill(calendarColor)
                    .frame(width: 4, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.title ?? "Untitled Event")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if event.isAllDay {
                            Text("All-day")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(calendarColor.opacity(0.25)))
                                .foregroundStyle(calendarColor)
                        }
                    }

                    if !event.isAllDay {
                        Text(timeRangeText)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    if let location = trimmedLocation {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 8))
                            Text(location)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }
                }

                Spacer(minLength: 0)

                if isHovered {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help("Open in Calendar")
    }

    private var trimmedLocation: String? {
        guard let raw = event.location?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Locations are often multi-line addresses; keep the first line.
        return raw.components(separatedBy: .newlines).first
    }

    private var timeRangeText: String {
        guard let start = event.startDate, let end = event.endDate else { return "" }
        let startText = start.formatted(date: .omitted, time: .shortened)
        if CalendarManager.isMultiDay(event) {
            let endText = end.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return "\(startText) \u{2013} \(endText)"
        }
        let endText = end.formatted(date: .omitted, time: .shortened)
        return "\(startText) \u{2013} \(endText)"
    }
}

// MARK: - Permission prompt

/// Shared prompt used for both the "not yet asked" and "denied" states.
private struct CalendarPermissionPrompt: View {
    let message: String
    let buttonTitle: String
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            Button(action: action) {
                HStack(spacing: 6) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(buttonTitle)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row identity

extension EKEvent {
    /// Stable-enough ForEach identity: recurring events share `eventIdentifier`
    /// across occurrences, so mix in the occurrence start date.
    var calendarRowID: String {
        let base = eventIdentifier ?? calendarItemIdentifier
        let stamp = startDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(base)#\(stamp)"
    }
}
