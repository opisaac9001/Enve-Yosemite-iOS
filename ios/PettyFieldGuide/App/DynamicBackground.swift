import SwiftUI

/// Restrained atmospheric backdrop: two slowly drifting soft circles over the canvas colour.
struct DynamicBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Palette.canvas(scheme)
                Circle()
                    .fill(Palette.accent.opacity(scheme == .dark ? 0.16 : 0.22))
                    .frame(width: size.width * 0.9)
                    .blur(radius: 70)
                    .offset(x: phase ? size.width * 0.25 : -size.width * 0.35,
                            y: phase ? -size.height * 0.35 : -size.height * 0.15)
                Circle()
                    .fill(Palette.pine.opacity(scheme == .dark ? 0.28 : 0.18))
                    .frame(width: size.width * 1.1)
                    .blur(radius: 90)
                    .offset(x: phase ? -size.width * 0.3 : size.width * 0.3,
                            y: phase ? size.height * 0.45 : size.height * 0.25)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 38).repeatForever(autoreverses: true)) { phase = true }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
