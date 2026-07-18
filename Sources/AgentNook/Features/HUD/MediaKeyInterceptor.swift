import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Intercepts the hardware media keys (volume up/down, mute, brightness up/down)
/// with a HID-level CGEventTap so the system OSD bezel never appears, applies the
/// change through `HUDVolumeManager` / `HUDBrightnessManager`, and shows the
/// notch HUD via `SneakPeekCoordinator` instead.
///
/// - Tap: `CGEvent.tapCreate(.cghidEventTap, .headInsertEventTap, .defaultTap, 1 << 14)`
///   (14 = NSSystemDefined), decoded via `NSEvent(cgEvent:)` subtype 8.
/// - Swallowing only happens when the "Replace system HUD" setting is ON and
///   Accessibility is granted; otherwise every event passes through untouched.
/// - Steps are 1/16, or 1/64 with Option+Shift held.
/// - The tap is fully torn down when the setting is turned off (system HUD returns).
@MainActor
final class MediaKeyInterceptor: ObservableObject {
    static let shared = MediaKeyInterceptor()

    /// Whether the app currently holds Accessibility (AX) trust.
    @Published private(set) var axStatus: Bool = AXIsProcessTrusted()
    /// Whether the event tap is installed and enabled.
    @Published private(set) var isTapActive = false
    /// Set when tap creation failed even though the feature is on and AX is granted.
    @Published private(set) var tapCreationFailed = false

    static let replaceSystemHUDKey = "replaceSystemHUD"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var axPollTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var feedbackSound: NSSound?
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app launch. Reads the "Replace system HUD" setting and keeps
    /// the tap in sync with it from then on.
    func start() {
        guard !started else { return }
        started = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncWithSettings() }
        }
        syncWithSettings()
    }

    func stop() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        stopAXPolling()
        disableTap()
        started = false
    }

    /// Re-check AX trust (e.g. when the settings pane appears).
    func refreshPermissionStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted != axStatus { axStatus = trusted }
        syncWithSettings()
    }

    /// Prompt the user for Accessibility access, then poll every 3 s until granted.
    func requestPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        axStatus = AXIsProcessTrustedWithOptions(options)
        if axStatus {
            syncWithSettings()
        } else {
            startAXPolling()
        }
    }

    // MARK: - Settings sync

    private var interceptionWanted: Bool {
        UserDefaults.standard.bool(forKey: Self.replaceSystemHUDKey)
    }

    private func syncWithSettings() {
        let enabled = interceptionWanted
        let trusted = AXIsProcessTrusted()
        if trusted != axStatus { axStatus = trusted }

        if enabled && trusted {
            stopAXPolling()
            enableTap()
        } else {
            disableTap()
            if enabled && !trusted {
                startAXPolling()
            } else {
                stopAXPolling()
            }
        }
    }

    // MARK: - AX polling

    private func startAXPolling() {
        guard axPollTimer == nil else { return }
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAXStatus() }
        }
    }

    private func stopAXPolling() {
        axPollTimer?.invalidate()
        axPollTimer = nil
    }

    private func pollAXStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted != axStatus { axStatus = trusted }
        if trusted {
            stopAXPolling()
            syncWithSettings()
        }
    }

    // MARK: - Event tap lifecycle

    private func enableTap() {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            isTapActive = true
            return
        }

        let mask = CGEventMask(1 << 14) // NSSystemDefined
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hudMediaKeyTapCallback,
            userInfo: refcon
        ) else {
            NSLog("AgentNook HUD: CGEvent.tapCreate failed — media keys not intercepted")
            isTapActive = false
            tapCreationFailed = true
            return
        }

        eventTap = tap
        tapCreationFailed = false
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapActive = true
    }

    /// Fully tear the tap down — keys pass through and the system HUD returns.
    private func disableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        isTapActive = false
    }

    private func reenableTapAfterSystemDisable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    // MARK: - Event handling

    /// Entry point from the C tap callback. The tap's run-loop source lives on the
    /// main run loop, so hopping to the main actor synchronously is safe here.
    nonisolated fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { self.reenableTapAfterSystemDisable() }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14 else { // NSSystemDefined
            return Unmanaged.passUnretained(event)
        }
        return MainActor.assumeIsolated { self.processSystemDefinedEvent(event) }
    }

    private func processSystemDefinedEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard
            let nsEvent = NSEvent(cgEvent: event),
            nsEvent.type == .systemDefined,
            nsEvent.subtype.rawValue == 8
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0xA // 0xB = key up

        guard let action = HUDMediaKeyAction(nxKeyCode: keyCode) else {
            // Play/pause, next, etc. — never touched by this module.
            return Unmanaged.passUnretained(event)
        }

        // Only intercept when the feature is on and Accessibility is granted.
        guard interceptionWanted, axStatus else {
            return Unmanaged.passUnretained(event)
        }
        // If we can't control brightness, let the system handle those keys.
        if action.isBrightness, !HUDBrightnessManager.shared.isAvailable {
            return Unmanaged.passUnretained(event)
        }

        if isKeyDown {
            let modifiers = nsEvent.modifierFlags
            let fineStep = modifiers.contains(.option) && modifiers.contains(.shift)
            let step: Float = fineStep ? 1.0 / 64.0 : 1.0 / 16.0
            perform(action: action, step: step)
        }
        // Swallow key-down AND key-up so the system OSD never appears.
        return nil
    }

    private func perform(action: HUDMediaKeyAction, step: Float) {
        let volumeManager = HUDVolumeManager.shared
        let peek = SneakPeekCoordinator.shared
        switch action {
        case .volumeUp, .volumeDown:
            let delta = (action == .volumeUp) ? step : -step
            let newValue = volumeManager.stepVolume(by: delta, source: .internalControl)
            playVolumeFeedbackIfWanted()
            peek.show(type: .volume, value: newValue, source: .internalControl)
        case .mute:
            volumeManager.toggleMute(source: .internalControl)
            peek.show(
                type: .mute,
                value: volumeManager.isMuted ? 0 : volumeManager.volume,
                source: .internalControl
            )
        case .brightnessUp, .brightnessDown:
            let delta = (action == .brightnessUp) ? step : -step
            if let newValue = HUDBrightnessManager.shared.stepBrightness(by: delta) {
                peek.show(type: .brightness, value: newValue, source: .internalControl)
            }
        }
    }

    // MARK: - Key feedback sound

    /// Mirrors the system behavior: plays the volume tick when the user has
    /// "Play feedback when volume is changed" enabled in Sound settings.
    private func playVolumeFeedbackIfWanted() {
        guard volumeFeedbackEnabled() else { return }
        if feedbackSound == nil {
            let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
            feedbackSound = NSSound(contentsOfFile: path, byReference: true)
        }
        guard let feedbackSound else { return }
        feedbackSound.stop()
        feedbackSound.play()
    }

    private func volumeFeedbackEnabled() -> Bool {
        let value = CFPreferencesCopyValue(
            "com.apple.sound.beep.feedback" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        if let number = value as? NSNumber { return number.intValue == 1 }
        return false
    }
}

// MARK: - NX media-key codes

private enum HUDMediaKeyAction: Equatable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown

    /// NX_KEYTYPE_* codes from IOKit/hidsystem/ev_keymap.h.
    init?(nxKeyCode: Int32) {
        switch nxKeyCode {
        case 0: self = .volumeUp       // NX_KEYTYPE_SOUND_UP
        case 1: self = .volumeDown     // NX_KEYTYPE_SOUND_DOWN
        case 2: self = .brightnessUp   // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: self = .brightnessDown // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: self = .mute           // NX_KEYTYPE_MUTE
        default: return nil
        }
    }

    var isBrightness: Bool {
        self == .brightnessUp || self == .brightnessDown
    }
}

// MARK: - C tap callback

private func hudMediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    return interceptor.handleTap(type: type, event: event)
}
