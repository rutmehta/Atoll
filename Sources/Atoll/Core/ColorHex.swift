import SwiftUI

extension Color {
    /// "#RRGGBB" or "RRGGBB" (case-insensitive). Falls back to black.
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X",
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded())
        )
    }
}

/// Two-way bridge between a stored hex string and SwiftUI's ColorPicker.
@MainActor
func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
    Binding<Color>(
        get: { Color(hex: hex.wrappedValue) },
        set: { hex.wrappedValue = $0.hexString }
    )
}
