import EventKit
import SwiftUI

/// Settings pane: event filters plus per-calendar checkboxes grouped by
/// account/source. Lives in the regular settings window (system appearance,
/// not the dark notch), so it uses standard form styling.
struct CalendarSettingsView: View {
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        Form {
            if manager.hasFullAccess {
                filtersSection
                calendarsSections
            } else {
                permissionSection
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refresh() }
    }

    // MARK: - Filters

    private var filtersSection: some View {
        Section("Events") {
            Toggle("Hide all-day events", isOn: Binding(
                get: { manager.hideAllDayEvents },
                set: { manager.hideAllDayEvents = $0 }
            ))
            Toggle("Hide multi-day events", isOn: Binding(
                get: { manager.hideMultiDayEvents },
                set: { manager.hideMultiDayEvents = $0 }
            ))
        }
    }

    // MARK: - Calendars

    @ViewBuilder
    private var calendarsSections: some View {
        Section {
            HStack {
                Button("Select All") { manager.enableAllCalendars() }
                Button("Deselect All") { manager.disableAllCalendars() }
                Spacer()
            }
            .controlSize(.small)
        } header: {
            Text("Calendars")
        } footer: {
            Text("Only events from selected calendars appear in the notch.")
        }

        ForEach(manager.calendarGroups) { group in
            Section(group.title) {
                ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                    Toggle(isOn: Binding(
                        get: { manager.isCalendarEnabled(calendar) },
                        set: { manager.setCalendar(calendar, enabled: $0) }
                    )) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(nsColor: calendar.color ?? .systemBlue))
                                .frame(width: 9, height: 9)
                            Text(calendar.title)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section("Permission") {
            switch manager.authorizationStatus {
            case .notDetermined:
                LabeledContent("Calendar access") {
                    Button {
                        manager.requestAccess()
                    } label: {
                        if manager.isRequestingAccess {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Enable\u{2026}")
                        }
                    }
                    .disabled(manager.isRequestingAccess)
                }
            default:
                LabeledContent("Calendar access") {
                    Button("Open System Settings\u{2026}") {
                        manager.openCalendarPrivacySettings()
                    }
                }
                Text("Atoll needs full Calendar access to show your events. Grant it under Privacy & Security \u{203A} Calendars.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
