import AVFoundation
import SwiftUI

/// Webcam mirror pane for the notch (Tools tab). Shows an aspect-fill rounded
/// camera preview with a flip button, plus a camera picker when more than one
/// device is connected. Gracefully handles missing permission and missing cameras.
///
/// The capture session only runs while this view is on screen.
struct MirrorView: View {
    @ObservedObject private var manager = MirrorManager.shared

    var body: some View {
        Group {
            switch manager.authStatus {
            case .authorized:
                if manager.devices.isEmpty {
                    noCameraView
                } else {
                    previewView
                }
            case .notDetermined:
                permissionPromptView
            case .denied, .restricted:
                deniedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.previewDidAppear() }
        .onDisappear { manager.previewDidDisappear() }
    }

    // MARK: - Camera preview

    private var previewView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
            MirrorCameraPreview(
                session: manager.session,
                isMirrored: manager.isMirrored,
                configurationVersion: manager.configurationVersion
            )
            if !manager.isSessionRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            flipButton
                .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            if manager.devices.count > 1 {
                cameraPicker
                    .padding(8)
            }
        }
    }

    private var flipButton: some View {
        Button {
            manager.isMirrored.toggle()
        } label: {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(manager.isMirrored ? "Show unmirrored" : "Show mirrored")
    }

    private var cameraPicker: some View {
        Menu {
            ForEach(manager.devices, id: \.uniqueID) { device in
                Button {
                    manager.selectedCameraID = device.uniqueID
                } label: {
                    if device.uniqueID == manager.activeDevice?.uniqueID {
                        Label(device.localizedName, systemImage: "checkmark")
                    } else {
                        Text(device.localizedName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose camera")
    }

    // MARK: - Fallback states

    private var permissionPromptView: some View {
        MirrorStatusPane(
            icon: "camera",
            title: "Camera access needed",
            message: "Atoll uses the camera only to show this mirror.",
            buttonTitle: "Enable Camera"
        ) {
            manager.requestAccess()
        }
    }

    private var deniedView: some View {
        MirrorStatusPane(
            icon: "video.slash",
            title: "Camera access is off",
            message: "Allow camera access for Atoll in System Settings to use the mirror.",
            buttonTitle: "Open System Settings"
        ) {
            MirrorManager.openCameraPrivacySettings()
        }
    }

    private var noCameraView: some View {
        MirrorStatusPane(
            icon: "video",
            title: "No camera found",
            message: "Connect a webcam, or bring your iPhone nearby to use Continuity Camera.",
            buttonTitle: nil,
            action: nil
        )
    }
}

// MARK: - Shared status pane

private struct MirrorStatusPane: View {
    let icon: String
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    init(icon: String, title: String, message: String,
         buttonTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(MirrorPillButtonStyle())
                    .padding(.top, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MirrorPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.15))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
    }
}
