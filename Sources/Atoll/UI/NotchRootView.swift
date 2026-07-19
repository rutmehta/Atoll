import SwiftUI
import UniformTypeIdentifiers

/// Root SwiftUI view hosted in the notch panel. Draws the morphing notch shape
/// and switches between the closed sliver and the open hub.
struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        VStack(spacing: 0) {
            notch
                .overlay(alignment: .top) { quickPeek }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var currentSize: CGSize {
        vm.state == .open ? vm.openSize : vm.closedSize
    }

    private var notchShape: NotchShape {
        NotchShape(
            topCornerRadius: vm.state == .open ? 12 : 8,
            bottomCornerRadius: vm.state == .open ? settings.openCornerRadius : 13
        )
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            if vm.state == .open {
                OpenNotchView()
                    .frame(width: vm.openSize.width, height: vm.openSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else {
                ClosedNotchView()
                    .transition(.opacity)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(
            notchShape
                .fill(.black)
                .shadow(color: .black.opacity(vm.state == .open ? 0.6 : 0), radius: 14, y: 6)
        )
        .clipShape(notchShape)
        .overlay(
            // Seal the seam against the physical notch.
            Rectangle().fill(.black).frame(height: 1),
            alignment: .top
        )
        .contentShape(notchShape)
        // Keep the clear cutout pinned over the hardware notch when the wings
        // are asymmetric (the container is centered on the screen).
        .offset(x: vm.state == .closed ? (vm.rightWingWidth - vm.leftWingWidth) / 2 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.leftWingWidth)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.rightWingWidth)
        .onHover { hovering in
            switch vm.state {
            case .closed:
                vm.hoverChanged(hovering)
            case .open:
                if hovering {
                    vm.cancelPendingClose()
                } else {
                    vm.mouseExitedOpenNotch()
                }
            }
        }
        .onTapGesture {
            if vm.state == .closed { vm.open() }
        }
        .onDrop(
            of: [.fileURL, .url, .utf8PlainText, .plainText, .data],
            isTargeted: Binding(
                get: { vm.isDropTargeted },
                set: { targeted in
                    vm.isDropTargeted = targeted
                    if targeted, vm.state == .closed {
                        vm.open(tab: .shelf)
                    } else if !targeted, vm.state == .open {
                        // Aborted drag: hover events don't fire during drags, so
                        // schedule a close; an actual drop re-opens and cancels it.
                        vm.close(after: 1.2)
                    }
                }
            )
        ) { providers in
            ShelfStore.shared.ingest(providers)
            vm.open(tab: .shelf)
            return true
        }
        .animation(vm.state == .open ? NotchViewModel.openAnimation : NotchViewModel.closeAnimation, value: vm.state)
    }

    @ViewBuilder
    private var quickPeek: some View {
        if vm.state == .closed, settings.mediaLiveActivity, music.showQuickPeek {
            MediaQuickPeekView()
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.88))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                )
                .offset(y: vm.geometry.notchSize.height + 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: music.showQuickPeek)
        }
    }
}
