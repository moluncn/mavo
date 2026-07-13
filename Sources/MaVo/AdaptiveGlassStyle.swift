import SwiftUI

enum AdaptiveGlassTreatment {
    case regular
    case clear
}

enum AdaptiveGlassButtonKind {
    case regular
    case prominent
}

struct AdaptiveGlassBackdrop: View {
    let treatment: AdaptiveGlassTreatment

    init(treatment: AdaptiveGlassTreatment = .regular) {
        self.treatment = treatment
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            switch treatment {
            case .regular:
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: Rectangle())
                    .overlay {
                        backdropGradient(whiteOpacity: 0.10, accentOpacity: 0.035)
                    }
            case .clear:
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Rectangle())
                    .overlay {
                        backdropGradient(whiteOpacity: 0.055, accentOpacity: 0.018)
                    }
            }
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }

    private func backdropGradient(
        whiteOpacity: Double,
        accentOpacity: Double
    ) -> some View {
        LinearGradient(
            colors: [
                Color.white.opacity(whiteOpacity),
                Color.clear,
                Color.accentColor.opacity(accentOpacity)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }
}

struct AdaptiveGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let treatment: AdaptiveGlassTreatment
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            glassSurface(content: content)
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .padding(padding)
                .background {
                    switch treatment {
                    case .regular:
                        shape.fill(.regularMaterial)
                    case .clear:
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .background {
                    if let tint {
                        shape.fill(tint)
                    }
                }
                .overlay {
                    shape
                        .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
                }
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func glassSurface(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch (treatment, tint) {
        case let (.regular, .some(tint)):
            content
                .padding(padding)
                .glassEffect(.regular.tint(tint).interactive(isInteractive), in: shape)
        case (.regular, .none):
            content
                .padding(padding)
                .glassEffect(.regular.interactive(isInteractive), in: shape)
        case let (.clear, .some(tint)):
            content
                .padding(padding)
                .glassEffect(.clear.tint(tint).interactive(isInteractive), in: shape)
        case (.clear, .none):
            content
                .padding(padding)
                .glassEffect(.clear.interactive(isInteractive), in: shape)
        }
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let kind: AdaptiveGlassButtonKind

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch kind {
            case .regular:
                hoverFeedback(content.buttonStyle(.glass))
            case .prominent:
                hoverFeedback(content.buttonStyle(.glassProminent))
            }
        } else {
            switch kind {
            case .regular:
                hoverFeedback(content.buttonStyle(.bordered))
            case .prominent:
                hoverFeedback(content.buttonStyle(.borderedProminent))
            }
        }
    }

    private func hoverFeedback<Content: View>(_ content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.025 : 1)
            .brightness(isHovered ? 0.045 : 0)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.16 : 0),
                radius: isHovered ? 8 : 0,
                y: isHovered ? 3 : 0
            )
            .animation(.easeOut(duration: 0.13), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct AdaptiveTranslucentCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background {
                shape.fill(
                    Color.white.opacity(colorScheme == .dark ? 0.055 : 0.12)
                )
            }
            .overlay {
                shape.strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.14 : 0.32),
                    lineWidth: 0.6
                )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.035),
                radius: 9,
                y: 3
            )
    }
}

extension View {
    func adaptiveGlassSurface(
        cornerRadius: CGFloat,
        padding: CGFloat = 0,
        treatment: AdaptiveGlassTreatment = .regular,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            AdaptiveGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                padding: padding,
                treatment: treatment,
                tint: tint,
                isInteractive: isInteractive
            )
        )
    }

    func adaptiveGlassCard(
        cornerRadius: CGFloat = 18,
        treatment: AdaptiveGlassTreatment = .regular
    ) -> some View {
        adaptiveGlassSurface(
            cornerRadius: cornerRadius,
            padding: 13,
            treatment: treatment
        )
    }

    func adaptiveGlassButton(_ kind: AdaptiveGlassButtonKind = .regular) -> some View {
        modifier(AdaptiveGlassButtonModifier(kind: kind))
    }

    func adaptiveTranslucentCard(
        cornerRadius: CGFloat = 18,
        padding: CGFloat = 13
    ) -> some View {
        modifier(
            AdaptiveTranslucentCardModifier(
                cornerRadius: cornerRadius,
                padding: padding
            )
        )
    }
}
