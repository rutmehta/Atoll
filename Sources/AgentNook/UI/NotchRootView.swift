import SwiftUI

/// Root SwiftUI view hosted in the notch panel. Draws the morphing notch shape
/// and switches between the closed sliver and the open hub.
struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var currentSize: CGSize {
        vm.state == .open ? vm.openSize : vm.closedSize
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            if vm.state == .open {
                OpenNotchView()
                    .frame(width: vm.openSize.width, height: vm.openSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else {
                ClosedNotchView()
                    .frame(width: vm.closedSize.width, height: vm.closedSize.height)
                    .transition(.opacity)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(
            NotchShape(
                topCornerRadius: vm.state == .open ? 12 : 8,
                bottomCornerRadius: vm.state == .open ? settings.openCornerRadius : 13
            )
            .fill(.black)
            .shadow(color: .black.opacity(vm.state == .open ? 0.6 : 0), radius: 14, y: 6)
        )
        .clipShape(
            NotchShape(
                topCornerRadius: vm.state == .open ? 12 : 8,
                bottomCornerRadius: vm.state == .open ? settings.openCornerRadius : 13
            )
        )
        .contentShape(Rectangle())
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
        .animation(vm.state == .open ? NotchViewModel.openAnimation : NotchViewModel.closeAnimation, value: vm.state)
    }
}

/// The collapsed notch sliver. Live-activity "wings" get wired in here.
struct ClosedNotchView: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        HStack {
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
