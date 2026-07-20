import SwiftUI
import Combine
import ServiceManagement

/// Central user settings, persisted via UserDefaults.
/// Feature modules should keep feature-specific keys here grouped under a MARK,
/// or use their own @AppStorage keys in their own views.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: General
    @AppStorage("openOnHover") var openOnHover = true { willSet { objectWillChange.send() } }
    @AppStorage("hoverDelay") var hoverDelay = 0.1 { willSet { objectWillChange.send() } }
    @AppStorage("showOnAllDisplays") var showOnAllDisplays = true { willSet { objectWillChange.send() } }
    @AppStorage("fakeNotchOnExternalDisplays") var fakeNotchOnExternalDisplays = true { willSet { objectWillChange.send() } }
    @AppStorage("hapticFeedback") var hapticFeedback = true { willSet { objectWillChange.send() } }

    // MARK: Appearance
    @AppStorage("notchExtraWidth") var notchExtraWidth = 0.0 { willSet { objectWillChange.send() } }
    @AppStorage("openCornerRadius") var openCornerRadius = 24.0 { willSet { objectWillChange.send() } }
    @AppStorage("showBorderGlow") var showBorderGlow = false { willSet { objectWillChange.send() } }
    /// "black" | "gradient" | "artwork"
    @AppStorage("appearance.backgroundStyle") var backgroundStyle = "black" { willSet { objectWillChange.send() } }
    @AppStorage("appearance.gradientStartHex") var gradientStartHex = "#101018" { willSet { objectWillChange.send() } }
    @AppStorage("appearance.gradientEndHex") var gradientEndHex = "#000000" { willSet { objectWillChange.send() } }
    @AppStorage("appearance.accentHex") var accentHex = "#FF8A3D" { willSet { objectWillChange.send() } }
    @AppStorage("appearance.openWidth") var openWidth = 640.0 { willSet { objectWillChange.send() } }
    @AppStorage("appearance.openHeight") var openHeight = 400.0 { willSet { objectWillChange.send() } }

    // MARK: Layout
    /// Comma-separated raw values of visible tabs (Home is always shown).
    @AppStorage("layout.visibleTabs") var visibleTabsCSV = "Home,Shelf,Agents,Tools" { willSet { objectWillChange.send() } }
    @AppStorage("layout.defaultTab") var defaultTabRaw = "Home" { willSet { objectWillChange.send() } }
    /// "mediaCalendar" | "mediaOnly" | "calendarOnly"
    @AppStorage("layout.homeLayout") var homeLayout = "mediaCalendar" { willSet { objectWillChange.send() } }

    var accentColor: Color { Color(hex: accentHex) }

    // MARK: Live activities
    @AppStorage("mediaLiveActivity") var mediaLiveActivity = true { willSet { objectWillChange.send() } }
    @AppStorage("timerLiveActivity") var timerLiveActivity = true { willSet { objectWillChange.send() } }
    @AppStorage("batteryLiveActivity") var batteryLiveActivity = true { willSet { objectWillChange.send() } }
    @AppStorage("agentsLiveActivity") var agentsLiveActivity = true { willSet { objectWillChange.send() } }
    @AppStorage("calendarLiveActivity") var calendarLiveActivity = true { willSet { objectWillChange.send() } }
    @AppStorage("todosLiveActivity") var todosLiveActivity = true { willSet { objectWillChange.send() } }

    // MARK: HUD replacement
    @AppStorage("replaceSystemHUD") var replaceSystemHUD = false { willSet { objectWillChange.send() } }

    // MARK: Weather
    @AppStorage("weatherEnabled") var weatherEnabled = true { willSet { objectWillChange.send() } }
    @AppStorage("weatherUseCelsius") var weatherUseCelsius = false { willSet { objectWillChange.send() } }
    @AppStorage("weatherManualLocation") var weatherManualLocation = "" { willSet { objectWillChange.send() } }

    // MARK: Agent sessions
    @AppStorage("agentsNotifyOnAttention") var agentsNotifyOnAttention = true { willSet { objectWillChange.send() } }
    @AppStorage("agentsNotifyOnCompletion") var agentsNotifyOnCompletion = true { willSet { objectWillChange.send() } }
    @AppStorage("agentsIdleCutoffMinutes") var agentsIdleCutoffMinutes = 30.0 { willSet { objectWillChange.send() } }

    // MARK: Launch at login
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Atoll: launch-at-login toggle failed: \(error)")
            }
        }
    }
}
