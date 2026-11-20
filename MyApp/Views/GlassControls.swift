import AppKit
import SwiftUI

/// Micro press feedback shared by every glass control: no chrome, just a
/// slight contraction while the mouse is down.
private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small circular translucent button used in the Finder bubble header and the
/// floating tab strip. Keeps a single, consistent Liquid Glass treatment.
struct GlassIconButton: View {
    let systemName: String
    var help: String = ""
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                    isActive ? Color.accentColor : Color.primary.opacity(isEnabled ? 0.78 : 0.3)
                )
                .frame(width: 24, height: 24)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(
                    Circle().fill(
                        isActive
                            ? Color.accentColor.opacity(0.16)
                            : Color.white.opacity(isHovering && isEnabled ? 0.14 : 0)
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovering && isEnabled ? 0.48 : 0.35),
                                .white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .help(help)
        .accessibilityLabel(help.isEmpty ? systemName : help)
    }
}

/// Same glass circle, but opening an `NSMenu`.
struct GlassMenuButton<Content: View>: View {
    var help: String = ""
    @ViewBuilder var menu: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(
                    Circle().fill(Color.white.opacity(isHovering ? 0.14 : 0))
                )
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovering ? 0.48 : 0.35),
                                .white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .help(help)
    }
}

/// Capsule/rounded glass surface used by tab pills.
struct GlassPillBackground: View {
    var cornerRadius: CGFloat = 12
    var isActive = false
    var isHovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isActive
                            ? Color.white.opacity(0.10)
                            : Color.white.opacity(isHovering ? 0.07 : 0)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(isHovering || isActive ? 0.10 : 0.04), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isActive ? 0.45 : 0.26), location: 0),
                                .init(color: .white.opacity(0.12), location: 0.5),
                                .init(color: .white.opacity(0.05), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(isActive ? 0.12 : 0.05), radius: isActive ? 5 : 2, y: 1)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

/// The floating "Liquid Glass" bubble wrapper: desktop blur, thin material,
/// a luminous top edge, a soft inner rim and a drop shadow.
struct LiquidGlassBubbleBackground: View {
    var cornerRadius: CGFloat = 22

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color.clear)
            .background(
                ZStack {
                    VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    Rectangle().fill(.ultraThinMaterial)
                }
            )
            .clipShape(shape)
            // Specular sheen: brightest along the top edge, gone by mid height.
            .overlay(
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.10), location: 0),
                                .init(color: .white.opacity(0.03), location: 0.28),
                                .init(color: .clear, location: 0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            )
            // Inner rim: reads as the thickness of the glass.
            .overlay(
                shape
                    .strokeBorder(Color.black.opacity(0.09), lineWidth: 1.5)
                    .blur(radius: 2)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.45), location: 0),
                            .init(color: .white.opacity(0.12), location: 0.45),
                            .init(color: .white.opacity(0.05), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
            .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
            .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
    }
}

extension View {
    /// Shared visual language for the floating palettes (⌘O, ⌘⇧F).
    func floatingGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.22), in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.42), location: 0),
                            .init(color: .white.opacity(0.10), location: 0.5),
                            .init(color: .white.opacity(0.04), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}
