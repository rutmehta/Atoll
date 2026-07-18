import SwiftUI

/// Compact closed-notch wing: a checklist glyph plus the number of open
/// to-dos. Renders nothing when every to-do is completed or the list is
/// empty, so the integrator can compose it unconditionally.
struct TodoCountWing: View {
    @ObservedObject private var store = TodosStore.shared

    var body: some View {
        if store.openCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(store.openCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.openCount)
        }
    }
}
