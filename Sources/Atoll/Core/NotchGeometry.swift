import AppKit

/// Describes the physical (or simulated) notch on a screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// Size of the notch cutout itself, in points.
    var notchSize: CGSize
    /// Whether the screen has a real hardware notch.
    var hasHardwareNotch: Bool

    /// Frame of the notch in screen coordinates (origin bottom-left, AppKit style).
    var notchFrame: CGRect {
        CGRect(
            x: screenFrame.midX - notchSize.width / 2,
            y: screenFrame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0 {
            // Real notch: width is what's left between the two auxiliary top areas.
            var width: CGFloat = 200
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = frame.width - left.width - right.width
            }
            return NotchGeometry(
                screenFrame: frame,
                notchSize: CGSize(width: width, height: topInset),
                hasHardwareNotch: true
            )
        }
        // No hardware notch (external display / older Mac): simulate one sized to the menu bar.
        let menuBarHeight = frame.maxY - screen.visibleFrame.maxY - (screen.visibleFrame.origin.y - frame.origin.y > 0 ? 0 : 0)
        let height = max(24, min(menuBarHeight, 38))
        return NotchGeometry(
            screenFrame: frame,
            notchSize: CGSize(width: 196, height: height),
            hasHardwareNotch: false
        )
    }

    /// The screen Atoll should live on, honoring the user's preference.
    static func preferredScreen(preferBuiltIn: Bool = true) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if preferBuiltIn, let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? screens.first
    }
}
