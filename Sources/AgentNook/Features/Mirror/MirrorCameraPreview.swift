import AVFoundation
import AppKit
import SwiftUI

/// Layer-backed NSView hosting an `AVCaptureVideoPreviewLayer` with aspect-fill
/// video gravity, wrapped for SwiftUI.
struct MirrorCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool
    /// Bumped by `MirrorManager` after each session reconfiguration; its presence
    /// here makes SwiftUI call `updateNSView` again so mirroring is re-applied to
    /// the connection that the new configuration created.
    let configurationVersion: Int

    func makeNSView(context: Context) -> MirrorPreviewNSView {
        let view = MirrorPreviewNSView()
        view.attach(session: session)
        view.apply(mirrored: isMirrored)
        return view
    }

    func updateNSView(_ nsView: MirrorPreviewNSView, context: Context) {
        nsView.attach(session: session)
        nsView.apply(mirrored: isMirrored)
    }
}

/// The backing layer of this view *is* the preview layer, so it always tracks the
/// view's bounds with no manual layout.
final class MirrorPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePreviewLayer()
    }

    private func configurePreviewLayer() {
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
    }

    override func makeBackingLayer() -> CALayer { previewLayer }

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
    }

    func apply(mirrored: Bool) {
        guard let connection = previewLayer.connection else { return }
        if connection.automaticallyAdjustsVideoMirroring {
            connection.automaticallyAdjustsVideoMirroring = false
        }
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != mirrored {
            connection.isVideoMirrored = mirrored
        }
    }
}
