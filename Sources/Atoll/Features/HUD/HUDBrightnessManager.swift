import AppKit
import Combine
import CoreGraphics

/// Reads/writes the built-in display's brightness through the private
/// DisplayServices framework (`dlopen` + `dlsym`, no linking).
///
/// There is no change-notification API for brightness — callers refresh on
/// demand (the media-key interceptor refreshes before stepping). When the
/// symbols are missing (future macOS, unusual hardware) `isAvailable` stays
/// false and all calls degrade to no-ops; brightness keys are then passed
/// through to the system instead of being swallowed.
@MainActor
final class HUDBrightnessManager: ObservableObject {
    static let shared = HUDBrightnessManager()

    @Published private(set) var brightness: Float = 0.5
    @Published private(set) var lastChangedAt: Date?
    @Published private(set) var isAvailable = false

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private var getBrightnessFn: GetBrightnessFn?
    private var setBrightnessFn: SetBrightnessFn?
    private var started = false

    private init() {}

    /// DisplayServices only controls the built-in panel — resolve it per call
    /// (CGMainDisplayID is whatever display is primary, e.g. an external).
    private var targetDisplayID: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 {
                return ids[i]
            }
        }
        return CGMainDisplayID()
    }

    /// Call once at app launch.
    func start() {
        guard !started else { return }
        started = true
        loadDisplayServices()
        refresh()
    }

    private func loadDisplayServices() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            NSLog("Atoll HUD: DisplayServices dlopen failed — brightness HUD disabled")
            isAvailable = false
            return
        }
        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightnessFn = unsafeBitCast(symbol, to: GetBrightnessFn.self)
        }
        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFn = unsafeBitCast(symbol, to: SetBrightnessFn.self)
        }
        isAvailable = (getBrightnessFn != nil && setBrightnessFn != nil)
        if !isAvailable {
            NSLog("Atoll HUD: DisplayServices symbols missing — brightness HUD disabled")
        }
        // Never dlclose: the function pointers must stay valid for the app's lifetime.
    }

    /// Re-read the hardware value (there are no change notifications).
    @discardableResult
    func refresh() -> Float? {
        guard let getBrightnessFn else { return nil }
        var value: Float = 0
        let status = getBrightnessFn(targetDisplayID, &value)
        guard status == 0 else { return nil }
        brightness = min(max(value, 0), 1)
        return brightness
    }

    /// Set absolute brightness (0...1) on the main display.
    func setBrightness(_ target: Float) {
        guard let setBrightnessFn else { return }
        let clamped = min(max(target, 0), 1)
        guard setBrightnessFn(targetDisplayID, clamped) == 0 else { return }
        brightness = clamped
        lastChangedAt = Date()
    }

    /// Step brightness by a delta. Returns the new value, or nil when unavailable.
    @discardableResult
    func stepBrightness(by delta: Float) -> Float? {
        guard isAvailable else { return nil }
        let current = refresh() ?? brightness
        let next = min(max(current + delta, 0), 1)
        setBrightness(next)
        return brightness
    }
}
