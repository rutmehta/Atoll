import AppKit
import Combine
import CoreBluetooth
import Foundation
import IOBluetooth

// MARK: - BluetoothEvent

/// A Bluetooth device connecting or disconnecting.
struct BluetoothEvent: Equatable {
    var deviceName: String
    var connected: Bool
    var deviceKind: BluetoothDeviceKind
    var date: Date
}

/// Coarse device category derived from the Bluetooth class-of-device, used to pick an icon.
enum BluetoothDeviceKind: Equatable {
    case headphones
    case speaker
    case keyboard
    case mouse
    case gamepad
    case phone
    case watch
    case generic

    var symbolName: String {
        switch self {
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker.fill"
        case .keyboard: return "keyboard.fill"
        case .mouse: return "computermouse.fill"
        case .gamepad: return "gamecontroller.fill"
        case .phone: return "iphone"
        case .watch: return "applewatch"
        case .generic: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - BluetoothMonitor

/// Publishes connect/disconnect events for paired Bluetooth devices.
///
/// Primary path: IOBluetooth connect notifications
/// (`IOBluetoothDevice.register(forConnectNotifications:selector:)`) plus a per-device
/// disconnect notification registered on every connection. If registration fails,
/// falls back to polling `IOBluetoothDevice.pairedDevices()` every 5 s.
///
/// Requires the `NSBluetoothAlwaysUsageDescription` Info.plist key on macOS 11+;
/// macOS shows the Bluetooth privacy prompt on first IOBluetooth use. When access
/// is denied `permissionDenied` becomes true and no events are delivered — the
/// settings view surfaces an "Open Privacy Settings" button for that case.
///
/// Call `BluetoothMonitor.shared.start()` once at app launch.
@MainActor
final class BluetoothMonitor: NSObject, ObservableObject {
    static let shared = BluetoothMonitor()

    /// Most recent event; mirrors `events`. The integrator typically shows
    /// `BluetoothEventWingView` for ~3 s whenever this changes.
    @Published private(set) var lastEvent: BluetoothEvent?
    @Published private(set) var lastEventDate: Date?
    /// Names of currently connected paired devices.
    @Published private(set) var connectedDeviceNames: [String] = []
    /// True when the app's Bluetooth privacy permission was denied or restricted.
    @Published private(set) var permissionDenied = false

    let events = PassthroughSubject<BluetoothEvent, Never>()

    // MARK: Internals

    private var started = false
    private var connectNotification: IOBluetoothUserNotification?
    /// Disconnect notifications keyed by device address.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// Addresses of devices we currently believe are connected.
    private var knownConnected: Set<String> = []
    private var pollTimer: Timer?

    private override init() {
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        refreshPermissionState()
        guard !permissionDenied else { return }

        // Baseline: devices already connected at launch produce no events.
        seedConnectedDevices()

        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(handleConnect(_:device:))
        )
        if connectNotification == nil {
            // API friction — fall back to polling paired devices.
            startPolling()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        connectNotification?.unregister()
        connectNotification = nil
        for (_, notification) in disconnectNotifications {
            notification.unregister()
        }
        disconnectNotifications.removeAll()
        knownConnected.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-checks permission (e.g. after the user visits System Settings) and
    /// starts monitoring if newly allowed.
    func retryAfterPermissionChange() {
        refreshPermissionState()
        if !permissionDenied, started {
            started = false
            start()
        }
    }

    static func openBluetoothPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPermissionState() {
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            permissionDenied = true
        default:
            permissionDenied = false
        }
    }

    // MARK: IOBluetooth notifications

    @objc private func handleConnect(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        guard let device else { return }
        registerDisconnectNotification(for: device)
        let key = deviceKey(device)
        guard !knownConnected.contains(key) else { return }
        knownConnected.insert(key)
        updateConnectedNames()
        emit(for: device, connected: true)
    }

    @objc private func handleDisconnect(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        notification?.unregister()
        guard let device else { return }
        let key = deviceKey(device)
        disconnectNotifications[key] = nil
        guard knownConnected.remove(key) != nil else { return }
        updateConnectedNames()
        emit(for: device, connected: false)
    }

    private func registerDisconnectNotification(for device: IOBluetoothDevice) {
        let key = deviceKey(device)
        guard disconnectNotifications[key] == nil else { return }
        if let notification = device.register(
            forDisconnectNotification: self,
            selector: #selector(handleDisconnect(_:device:))
        ) {
            disconnectNotifications[key] = notification
        }
    }

    // MARK: Polling fallback

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPairedDevices()
            }
        }
        timer.tolerance = 1
        pollTimer = timer
    }

    private func pollPairedDevices() {
        let paired = pairedDevices()
        var currentlyConnected: Set<String> = []
        var devicesByKey: [String: IOBluetoothDevice] = [:]
        for device in paired {
            let key = deviceKey(device)
            devicesByKey[key] = device
            if device.isConnected() {
                currentlyConnected.insert(key)
            }
        }

        let appeared = currentlyConnected.subtracting(knownConnected)
        let vanished = knownConnected.subtracting(currentlyConnected)
        knownConnected = currentlyConnected
        updateConnectedNames(paired: paired)

        for key in appeared {
            if let device = devicesByKey[key] {
                emit(for: device, connected: true)
            }
        }
        for key in vanished {
            if let device = devicesByKey[key] {
                emit(for: device, connected: false)
            }
        }
    }

    // MARK: Helpers

    private func seedConnectedDevices() {
        let paired = pairedDevices()
        for device in paired where device.isConnected() {
            knownConnected.insert(deviceKey(device))
            registerDisconnectNotification(for: device)
        }
        updateConnectedNames(paired: paired)
    }

    private func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private func deviceKey(_ device: IOBluetoothDevice) -> String {
        device.addressString ?? device.nameOrAddress ?? "unknown-device"
    }

    private func displayName(_ device: IOBluetoothDevice) -> String {
        if let name = device.name, !name.isEmpty { return name }
        if let nameOrAddress = device.nameOrAddress, !nameOrAddress.isEmpty { return nameOrAddress }
        return "Bluetooth Device"
    }

    private func updateConnectedNames(paired: [IOBluetoothDevice]? = nil) {
        let devices = paired ?? pairedDevices()
        connectedDeviceNames = devices
            .filter { knownConnected.contains(deviceKey($0)) }
            .map { displayName($0) }
            .sorted()
    }

    private var bluetoothLiveActivityEnabled: Bool {
        (UserDefaults.standard.object(forKey: "systemEvents.bluetoothLiveActivity") as? Bool) ?? true
    }

    private func emit(for device: IOBluetoothDevice, connected: Bool) {
        guard bluetoothLiveActivityEnabled else { return }
        let event = BluetoothEvent(
            deviceName: displayName(device),
            connected: connected,
            deviceKind: Self.deviceKind(for: device),
            date: Date()
        )
        lastEvent = event
        lastEventDate = event.date
        events.send(event)
    }

    /// Maps the Bluetooth class-of-device (major/minor) to a coarse kind.
    /// Raw values per the Bluetooth SIG "Class of Device" assigned numbers.
    private static func deviceKind(for device: IOBluetoothDevice) -> BluetoothDeviceKind {
        let major = device.deviceClassMajor
        let minor = device.deviceClassMinor
        switch major {
        case 0x02: // Phone
            return .phone
        case 0x04: // Audio / Video
            switch minor {
            case 0x05: return .speaker      // Loudspeaker
            case 0x08: return .speaker      // Car audio
            case 0x09: return .speaker      // Set-top / HiFi
            default: return .headphones     // Headset, hands-free, headphones, portable audio, …
            }
        case 0x05: // Peripheral (HID)
            if minor & 0x10 != 0 { return .keyboard }          // Keyboard or keyboard/pointing combo
            if minor & 0x20 != 0 { return .mouse }             // Pointing device
            let lowBits = minor & 0x0F
            if lowBits == 0x01 || lowBits == 0x02 { return .gamepad } // Joystick / gamepad
            return .generic
        case 0x07: // Wearable
            return .watch
        default:
            return .generic
        }
    }
}
