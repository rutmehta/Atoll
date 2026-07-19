import AppKit

/// Detects a live content drag (something on the drag pasteboard) approaching the
/// notch region of any screen, using global mouse monitors — the drag is noticed
/// *before* the cursor ever reaches the notch window, so the shelf can auto-open.
///
/// Wiring (integrator):
///     DragDetector.shared.onDragNearNotch = { [weak vm] in vm?.open(tab: .shelf) }
///     DragDetector.shared.start()
///
/// No Accessibility permission is required for global mouse-event monitors.
@MainActor
final class DragDetector {
    static let shared = DragDetector()

    /// Fired at most once per drag when the drag enters a notch region.
    var onDragNearNotch: (() -> Void)?

    private var monitors: [Any] = []
    private var isMouseDown = false
    private var baselineChangeCount = 0
    private var firedForCurrentDrag = false

    /// Pasteboard types that count as shelf-able content.
    private static let supportedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string,
        .tiff,
        .png,
        .pdf,
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
    ]

    private init() {}

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseDown() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseDragged() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseUp() }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        isMouseDown = false
        firedForCurrentDrag = false
    }

    // MARK: Event handling

    private func handleMouseDown() {
        isMouseDown = true
        firedForCurrentDrag = false
        baselineChangeCount = NSPasteboard(name: .drag).changeCount
    }

    private func handleMouseDragged() {
        guard isMouseDown, !firedForCurrentDrag else { return }
        guard UserDefaults.standard.bool(forKey: ShelfSettingsKeys.autoOpenOnDrag) else { return }

        // A real content drag bumps the drag pasteboard's changeCount after mouse-down.
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount else { return }
        guard pasteboard.availableType(from: Self.supportedTypes) != nil else { return }

        let location = NSEvent.mouseLocation
        guard NSScreen.screens.contains(where: { Self.notchRegion(for: $0).contains(location) }) else { return }

        firedForCurrentDrag = true
        onDragNearNotch?()
    }

    private func handleMouseUp() {
        isMouseDown = false
        firedForCurrentDrag = false
    }

    // MARK: Geometry

    /// The notch rect widened and extended downward so drags aimed loosely at the
    /// notch still trigger. Global (bottom-left origin) coordinates, matching
    /// `NSEvent.mouseLocation`.
    static func notchRegion(for screen: NSScreen) -> CGRect {
        let geometry = NotchGeometry.forScreen(screen)
        var region = geometry.notchFrame
        region.origin.x -= 100
        region.size.width += 200
        region.origin.y -= 24
        region.size.height += 24
        return region
    }
}
