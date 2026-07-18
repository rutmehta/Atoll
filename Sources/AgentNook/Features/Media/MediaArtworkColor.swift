import AppKit
import SwiftUI

enum MediaArtworkColor {
    /// Average color of an image, tuned for use as a UI tint on a black
    /// background (saturation floor + brightness floor so it stays visible).
    static func tint(for image: NSImage?) -> Color {
        guard let image, let avg = averageColor(of: image) else {
            return Color.white.opacity(0.85)
        }
        guard let rgb = avg.usingColorSpace(.deviceRGB) else {
            return Color.white.opacity(0.85)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        if s < 0.08 {
            // Effectively grayscale artwork — keep a neutral bright tint.
            return Color(white: max(0.75, min(b + 0.35, 0.95)))
        }
        let boosted = NSColor(
            hue: h,
            saturation: min(max(s, 0.35), 0.85),
            brightness: min(max(b, 0.65), 0.95),
            alpha: 1
        )
        return Color(nsColor: boosted)
    }

    /// Downsamples to a small bitmap and averages opaque pixels.
    static func averageColor(of image: NSImage) -> NSColor? {
        let sample = 12
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: sample * sample * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sample,
            height: sample,
            bitsPerComponent: 8,
            bytesPerRow: sample * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sample, height: sample))

        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3])
            guard alpha > 25 else { continue }
            r += Double(pixels[i])
            g += Double(pixels[i + 1])
            b += Double(pixels[i + 2])
            count += 1
        }
        guard count > 0 else { return nil }
        return NSColor(
            red: r / count / 255.0,
            green: g / count / 255.0,
            blue: b / count / 255.0,
            alpha: 1
        )
    }
}
