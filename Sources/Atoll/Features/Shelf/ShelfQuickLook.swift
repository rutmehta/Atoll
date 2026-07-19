import AppKit
import QuickLookUI

/// Drives the shared QLPreviewPanel for shelf items with a proper data source.
/// Not @MainActor as a class so the Objective-C data-source callbacks satisfy the
/// protocol cleanly; all entry points are @MainActor and the panel always calls
/// back on the main thread.
final class ShelfQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLookController()

    private var previewURLs: [NSURL] = []

    private override init() {
        super.init()
    }

    @MainActor
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// Space-bar behavior: toggle the panel for the given URLs.
    @MainActor
    func toggle(urls: [URL], startAt index: Int = 0) {
        if isVisible {
            close()
        } else {
            show(urls: urls, startAt: index)
        }
    }

    @MainActor
    func show(urls: [URL], startAt index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        previewURLs = urls.map { $0 as NSURL }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), previewURLs.count - 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // QLPreviewPanel re-derives its controller from the responder chain when it
        // becomes key, which can clear a manually-set data source — re-assert ours.
        DispatchQueue.main.async { [weak self] in
            guard let self, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
            if panel.dataSource !== self {
                panel.dataSource = self
                panel.delegate = self
                panel.reloadData()
            }
        }
    }

    @MainActor
    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index]
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
