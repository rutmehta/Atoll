@preconcurrency import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Camera authorization state exposed to the mirror UI.
enum MirrorAuthStatus: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// Owns the webcam `AVCaptureSession` shown in the notch mirror.
///
/// All session configuration and start/stop calls run on a private serial queue;
/// published state is always mutated back on the main actor. The session is only
/// started while a `MirrorView` is visible (`previewDidAppear`/`previewDidDisappear`),
/// and the integrator may additionally call `notchDidClose()` as a belt-and-braces
/// guarantee that the camera light turns off when the notch collapses.
@MainActor
final class MirrorManager: ObservableObject {
    static let shared = MirrorManager()

    /// The shared capture session driving every `MirrorCameraPreview` layer.
    let session = AVCaptureSession()

    @Published private(set) var authStatus: MirrorAuthStatus = .notDetermined
    /// All currently connected video devices (built-in, external, Continuity Camera).
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var isSessionRunning = false
    /// Incremented (on the main actor) after every session (re)configuration finishes.
    /// `MirrorCameraPreview` depends on it so mirroring is re-applied to the freshly
    /// created `AVCaptureConnection`.
    @Published private(set) var configurationVersion = 0

    /// `uniqueID` of the user's preferred camera. Empty string = automatic (first available).
    @AppStorage("mirror.selectedCameraID") var selectedCameraID = "" {
        willSet { objectWillChange.send() }
        didSet {
            guard oldValue != selectedCameraID else { return }
            reconfigureForActiveDevice()
        }
    }

    /// Whether the preview is horizontally flipped like a physical mirror. Defaults on.
    @AppStorage("mirror.isMirrored") var isMirrored = true {
        willSet { objectWillChange.send() }
    }

    private let sessionQueue = DispatchQueue(label: "app.atoll.mirror.session")
    private var visibleViewCount = 0
    /// uniqueID of the device the session is currently configured for.
    private var configuredDeviceID: String?
    private var notificationObservers: [NSObjectProtocol] = []

    private init() {
        refreshAuthStatus()
        if authStatus == .authorized {
            refreshDevices()
        }

        let center = NotificationCenter.default
        let topologyChanged: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in
                MirrorManager.shared.handleDeviceTopologyChange()
            }
        }
        notificationObservers.append(center.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main, using: topologyChanged))
        notificationObservers.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main, using: topologyChanged))
        notificationObservers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                NSLog("Atoll Mirror: capture session runtime error: %@",
                      error?.localizedDescription ?? "unknown")
                Task { @MainActor in
                    MirrorManager.shared.recoverFromRuntimeError()
                }
            })
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Authorization

    func refreshAuthStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: authStatus = .notDetermined
        case .denied: authStatus = .denied
        case .restricted: authStatus = .restricted
        case .authorized: authStatus = .authorized
        @unknown default: authStatus = .denied
        }
    }

    /// Presents the system camera permission prompt (no-op unless status is undetermined).
    func requestAccess() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            refreshAuthStatus()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in
                let manager = MirrorManager.shared
                manager.refreshAuthStatus()
                manager.refreshDevices()
                if manager.visibleViewCount > 0 {
                    manager.startSession()
                }
            }
        }
    }

    /// Deep-links to System Settings > Privacy & Security > Camera.
    static func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Devices

    private static let discoveryDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
    ]

    func refreshDevices() {
        guard authStatus == .authorized else {
            devices = []
            return
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.discoveryDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices
    }

    /// The camera that should currently feed the preview: the persisted choice when
    /// it is connected, otherwise the first available device.
    var activeDevice: AVCaptureDevice? {
        if !selectedCameraID.isEmpty,
           let match = devices.first(where: { $0.uniqueID == selectedCameraID }) {
            return match
        }
        return devices.first
    }

    private func handleDeviceTopologyChange() {
        refreshDevices()
        guard visibleViewCount > 0 || isSessionRunning else { return }
        // A disconnected device's input never resumes even if the camera returns,
        // so force a full reconfigure whenever the topology changes.
        configuredDeviceID = nil
        reconfigureForActiveDevice()
        if visibleViewCount > 0 {
            startSession()
        }
    }

    private func recoverFromRuntimeError() {
        guard visibleViewCount > 0 else { return }
        configuredDeviceID = nil
        refreshDevices()
        reconfigureForActiveDevice()
        startSession()
    }

    // MARK: - Session lifecycle

    /// Call from `MirrorView.onAppear`. Starts the session (requesting camera
    /// permission first if it has never been asked).
    func previewDidAppear() {
        visibleViewCount += 1
        refreshAuthStatus()
        switch authStatus {
        case .notDetermined:
            requestAccess()
        case .authorized:
            startSession()
        case .denied, .restricted:
            break
        }
    }

    /// Call from `MirrorView.onDisappear`. Stops the session once no preview is visible.
    func previewDidDisappear() {
        visibleViewCount = max(0, visibleViewCount - 1)
        if visibleViewCount == 0 {
            stopSession()
        }
    }

    /// Safety net for the integrator: guarantees the camera is released when the
    /// notch closes, even if SwiftUI keeps the tab's view tree alive.
    func notchDidClose() {
        visibleViewCount = 0
        stopSession()
    }

    /// Starts the capture session if authorized and a camera is available.
    func startSession() {
        guard authStatus == .authorized else { return }
        refreshDevices()
        reconfigureForActiveDevice()
        guard activeDevice != nil else { return }
        let session = self.session
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in
                MirrorManager.shared.isSessionRunning = running
            }
        }
    }

    /// Stops the capture session (turns the camera indicator light off).
    func stopSession() {
        let session = self.session
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
            Task { @MainActor in
                MirrorManager.shared.isSessionRunning = false
            }
        }
    }

    // MARK: - Configuration

    private func reconfigureForActiveDevice() {
        guard authStatus == .authorized else { return }
        let session = self.session

        guard let device = activeDevice else {
            // No cameras connected at all: tear the session down.
            guard configuredDeviceID != nil else { return }
            configuredDeviceID = nil
            sessionQueue.async {
                session.beginConfiguration()
                for input in session.inputs {
                    session.removeInput(input)
                }
                session.commitConfiguration()
                if session.isRunning {
                    session.stopRunning()
                }
                Task { @MainActor in
                    let manager = MirrorManager.shared
                    manager.isSessionRunning = false
                    manager.configurationVersion += 1
                }
            }
            return
        }

        guard device.uniqueID != configuredDeviceID else { return }
        configuredDeviceID = device.uniqueID
        sessionQueue.async {
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) {
                session.sessionPreset = .high
            }
            for input in session.inputs {
                session.removeInput(input)
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                } else {
                    NSLog("Atoll Mirror: session refused input for %@", device.localizedName)
                }
            } catch {
                NSLog("Atoll Mirror: failed to create camera input: %@", error.localizedDescription)
            }
            session.commitConfiguration()
            Task { @MainActor in
                MirrorManager.shared.configurationVersion += 1
            }
        }
    }
}
