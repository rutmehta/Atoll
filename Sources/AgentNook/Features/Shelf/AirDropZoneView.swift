import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AirDrop sender

/// Performs AirDrop shares and releases security scopes when the share finishes.
final class ShelfAirDropper: NSObject, NSSharingServiceDelegate {
    static let shared = ShelfAirDropper()

    private var scopedURLs: [URL] = []
    private var activeService: NSSharingService?

    private override init() {
        super.init()
    }

    /// AirDrops the given items (file URLs, web URLs, NSStrings).
    /// `scopedURLs` are URLs with security-scoped access already started; the
    /// scope is released once the share completes or fails.
    @MainActor
    @discardableResult
    func airDrop(items: [Any], scopedURLs: [URL] = []) -> Bool {
        guard !items.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: items) else {
            for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
            NSSound.beep()
            return false
        }
        self.scopedURLs.append(contentsOf: scopedURLs)
        service.delegate = self
        activeService = service
        service.perform(withItems: items)
        return true
    }

    private func releaseScopes() {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        activeService = nil
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        releaseScopes()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        releaseScopes()
    }
}

// MARK: - Drop zone view

/// Dashed-border AirDrop target. Anything dropped on it (files, links, text) is
/// AirDropped immediately without entering the shelf. Clicking it AirDrops the
/// current selection (or all shelf items) via `onActivate`.
struct AirDropZoneView: View {
    /// Invoked on click — the host decides what to AirDrop (e.g. selection).
    var onActivate: (@MainActor () -> Void)?

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 21, weight: .medium))
            Text("AirDrop")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isTargeted ? 0.12 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.25))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .onTapGesture {
            onActivate?()
        }
        .onDrop(of: [UTType.fileURL, .url, .utf8PlainText, .plainText],
                isTargeted: $isTargeted) { providers in
            guard !providers.isEmpty else { return false }
            Task {
                let payload = await Self.payload(from: providers)
                _ = await MainActor.run {
                    ShelfAirDropper.shared.airDrop(items: payload)
                }
            }
            return true
        }
        .help("Drop files, links or text to AirDrop them")
        .accessibilityLabel("AirDrop drop zone")
    }

    /// Extracts an AirDrop-able payload (URLs and strings) from dropped providers.
    static func payload(from providers: [NSItemProvider]) async -> [Any] {
        var payload: [Any] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await ShelfStore.loadURL(from: provider, type: .fileURL) {
                payload.append(url)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await ShelfStore.loadURL(from: provider, type: .url) {
                payload.append(url)
                continue
            }
            if let string = await ShelfStore.loadString(from: provider) {
                payload.append(string as NSString)
            }
        }
        return payload
    }
}
