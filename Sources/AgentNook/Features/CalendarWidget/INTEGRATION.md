# CalendarWidget — Integration

## Views

| View | Placement |
|---|---|
| `CalendarWidgetView` | Open notch. Intended for the **Home** tab as the calendar peek beside the media player (works at ~240-300 pt wide), or full-width in its own pane. Handles its own permission prompts and empty state; safe to show in any authorization state. |
| `CalendarNextEventWing` | Closed-notch wing (right side suggested). Shows `time + title` of the next upcoming/ongoing non-all-day event today; renders **nothing** (EmptyView) when there is no such event or access is missing — safe to compose unconditionally. Optional `maxWidth:` parameter (default 150). Intrinsic height ~13-16 pt; center it vertically in the wing. |
| `CalendarSettingsView` | Settings window tab/section ("Calendar", suggested icon `calendar`). Standard grouped Form, system appearance. |

## Startup

```swift
CalendarManager.shared.start()   // at app launch (AppDelegate). @MainActor.
```

`start()` never triggers a permission prompt — it only begins observing
(`.EKEventStoreChanged` + 5-min refresh timer + 1-min wing recompute) when full
access is already granted. The permission prompt is button-triggered from
`CalendarWidgetView` / `CalendarSettingsView` via `CalendarManager.shared.requestAccess()`.

## Permissions / Info.plist

- **Required Info.plist key:** `NSCalendarsFullAccessUsageDescription`
  (e.g. "AgentNook shows your upcoming events in the notch."). Without it,
  macOS 14+ denies the request silently.
- App is unsandboxed; if sandboxing is ever enabled add entitlement
  `com.apple.security.personal-information.calendars`.
- Denied/restricted state deep-links to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars`.

## Settings keys (module-internal, `@AppStorage`)

- `calendar.enabledCalendarIDs` — JSON array of enabled calendar IDs ("" = all)
- `calendar.hideAllDay`, `calendar.hideMultiDay` — Bool filters

## Public API surface

`CalendarManager.shared` (`@MainActor ObservableObject`): `authorizationStatus`,
`hasFullAccess`, `displayedDate`, `displayedEvents`, `nextEvent`,
`calendarGroups`, `events(for: Date)`, `goToPreviousDay()/goToNextDay()/goToToday()`,
`requestAccess()`, `openInCalendarApp(_:)`, calendar enable/disable helpers.
`CalendarSourceGroup` (calendars grouped by account source).

## Notes

- Clicking an event row deep-links Calendar.app to that occurrence via
  `ical://ekevent/<UTC-stamp>/<calendarItemIdentifier>?method=showEvent&options=more`,
  falling back to activating Calendar.app (`com.apple.iCal`) if the URL is refused.
- The day header pager keeps `displayedDate` pinned to "today" across midnight
  unless the user has paged away.
