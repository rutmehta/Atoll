import AppKit
import Combine
import CoreAudio

/// Tracks and controls the default output device's volume + mute via CoreAudio.
///
/// - Follows default-output-device changes (`kAudioHardwarePropertyDefaultOutputDevice`)
///   and re-subscribes all listeners when the device changes.
/// - Reads/writes `kAudioDevicePropertyVolumeScalar` on the main element, falling
///   back to averaging channels 1–2 when the device has no main volume control.
/// - Uses `kAudioDevicePropertyMute` when the device supports it, otherwise a
///   software mute (remember volume, set 0, restore on unmute).
/// - Property listener blocks mean EXTERNAL changes (menu-bar slider, AirPods,
///   another app) also publish — and surface the notch HUD via `SneakPeekCoordinator`.
@MainActor
final class HUDVolumeManager: ObservableObject {
    static let shared = HUDVolumeManager()

    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var lastChangedAt: Date?
    @Published private(set) var lastChangeSource: HUDEventSource = .external
    @Published private(set) var hasOutputDevice = false

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var softwareMuteRestoreVolume: Float?
    /// Our own writes echo back through the CoreAudio listener; changes inside
    /// this window are treated as internal so we don't double-show the HUD.
    private var suppressExternalUntil = Date.distantPast
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app launch.
    func start() {
        guard !started else { return }
        started = true
        installDefaultDeviceListener()
        rebindToDefaultOutputDevice()
    }

    // MARK: - Public controls

    /// Set the absolute output volume (0...1).
    func setVolume(_ target: Float, source: HUDEventSource = .internalControl) {
        guard deviceID != kAudioObjectUnknown else { return }
        let clamped = min(max(target, 0), 1)
        if source == .internalControl {
            suppressExternalUntil = Date().addingTimeInterval(0.35)
        }

        var wrote = false
        var mainAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &mainAddress), isSettable(mainAddress) {
            wrote = writeFloat(clamped, mainAddress)
        }
        if !wrote {
            for channel in Self.fallbackChannels {
                var address = Self.volumeAddress(element: channel)
                if AudioObjectHasProperty(deviceID, &address), isSettable(address) {
                    if writeFloat(clamped, address) { wrote = true }
                }
            }
        }
        guard wrote else { return }
        volume = clamped
        lastChangedAt = Date()
        lastChangeSource = source
    }

    /// Step volume by a delta (positive or negative), returns the new value.
    @discardableResult
    func stepVolume(by delta: Float, source: HUDEventSource = .internalControl) -> Float {
        if isMuted, delta > 0 {
            setMuted(false, source: source)
        }
        let next = min(max(volume + delta, 0), 1)
        setVolume(next, source: source)
        return volume
    }

    func setMuted(_ muted: Bool, source: HUDEventSource = .internalControl) {
        guard deviceID != kAudioObjectUnknown else { return }
        if source == .internalControl {
            suppressExternalUntil = Date().addingTimeInterval(0.35)
        }

        var muteAddress = Self.muteAddress()
        if AudioObjectHasProperty(deviceID, &muteAddress), isSettable(muteAddress) {
            var muteValue: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                deviceID, &muteAddress, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &muteValue
            )
            if status == noErr {
                isMuted = muted
                lastChangedAt = Date()
                lastChangeSource = source
                return
            }
        }

        // Software-mute fallback for devices without a mute control.
        if muted {
            softwareMuteRestoreVolume = volume
            isMuted = true
            setVolume(0, source: source)
        } else {
            let restore = softwareMuteRestoreVolume ?? 0.5
            softwareMuteRestoreVolume = nil
            isMuted = false
            setVolume(restore, source: source)
        }
        lastChangedAt = Date()
        lastChangeSource = source
    }

    func toggleMute(source: HUDEventSource = .internalControl) {
        setMuted(!isMuted, source: source)
    }

    // MARK: - Default device tracking

    private func installDefaultDeviceListener() {
        var address = Self.defaultDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebindToDefaultOutputDevice() }
        }
        defaultDeviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        if status != noErr {
            NSLog("AgentNook HUD: failed to observe default output device (\(status))")
        }
    }

    private func rebindToDefaultOutputDevice() {
        removeDeviceListeners()

        var address = Self.defaultDeviceAddress()
        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &newDeviceID
        )
        guard status == noErr, newDeviceID != kAudioObjectUnknown else {
            deviceID = AudioObjectID(kAudioObjectUnknown)
            hasOutputDevice = false
            return
        }

        deviceID = newDeviceID
        hasOutputDevice = true
        softwareMuteRestoreVolume = nil

        // Volume listeners: main element plus channels 1-2 fallback.
        let changeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDevicePropertyChanged() }
        }
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        elements.append(contentsOf: Self.fallbackChannels)
        for element in elements {
            var volumeAddress = Self.volumeAddress(element: element)
            if AudioObjectHasProperty(deviceID, &volumeAddress) {
                if AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, changeBlock) == noErr {
                    deviceListeners.append((volumeAddress, changeBlock))
                }
            }
        }
        var muteAddress = Self.muteAddress()
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            if AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, changeBlock) == noErr {
                deviceListeners.append((muteAddress, changeBlock))
            }
        }

        refreshFromHardware(source: .external, showHUD: false)
    }

    private func removeDeviceListeners() {
        if deviceID != kAudioObjectUnknown {
            for entry in deviceListeners {
                var address = entry.address
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, entry.block)
            }
        }
        deviceListeners.removeAll()
    }

    // MARK: - Change handling

    private func handleDevicePropertyChanged() {
        let isExternal = Date() >= suppressExternalUntil
        refreshFromHardware(source: isExternal ? .external : .internalControl, showHUD: isExternal)
    }

    private func refreshFromHardware(source: HUDEventSource, showHUD: Bool) {
        guard deviceID != kAudioObjectUnknown else { return }
        let newVolume = readVolume()
        let newMuted = readMuted()

        var changed = false
        var muteChanged = false

        if let newVolume, abs(newVolume - volume) > 0.0005 {
            volume = newVolume
            changed = true
        }
        if let newMuted, newMuted != isMuted {
            isMuted = newMuted
            changed = true
            muteChanged = true
        }
        // No hardware mute: if a software-muted device's volume was raised
        // externally, consider it unmuted again.
        if newMuted == nil, isMuted, let newVolume, newVolume > 0.001, source == .external {
            isMuted = false
            softwareMuteRestoreVolume = nil
            changed = true
            muteChanged = true
        }

        guard changed else { return }
        lastChangedAt = Date()
        lastChangeSource = source
        if showHUD, source == .external {
            SneakPeekCoordinator.shared.showExternalChange(
                type: muteChanged ? .mute : .volume,
                value: volume
            )
        }
    }

    // MARK: - CoreAudio plumbing

    private static let fallbackChannels: [AudioObjectPropertyElement] = [1, 2]

    private static func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readVolume() -> Float? {
        var mainAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &mainAddress), let value = readFloat(mainAddress) {
            return min(max(value, 0), 1)
        }
        var channelValues: [Float] = []
        for channel in Self.fallbackChannels {
            var address = Self.volumeAddress(element: channel)
            if AudioObjectHasProperty(deviceID, &address), let value = readFloat(address) {
                channelValues.append(value)
            }
        }
        guard !channelValues.isEmpty else { return nil }
        let average = channelValues.reduce(0, +) / Float(channelValues.count)
        return min(max(average, 0), 1)
    }

    private func readMuted() -> Bool? {
        var address = Self.muteAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value != 0
    }

    private func readFloat(_ address: AudioObjectPropertyAddress) -> Float? {
        var mutableAddress = address
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        let status = AudioObjectGetPropertyData(deviceID, &mutableAddress, 0, nil, &size, &value)
        guard status == noErr, size == UInt32(MemoryLayout<Float32>.size) else { return nil }
        return value
    }

    private func writeFloat(_ value: Float, _ address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        var mutableValue = Float32(value)
        let status = AudioObjectSetPropertyData(
            deviceID, &mutableAddress, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &mutableValue
        )
        return status == noErr
    }

    private func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &mutableAddress, &settable)
        return status == noErr && settable.boolValue
    }
}
