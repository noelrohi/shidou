import SwiftUI

/// Liquid Glass, with the material fallback the deployment target still needs.
///
/// The app targets iOS 17, so every glass surface has to read as deliberate on
/// a system that has none. The fallback is a material in the same shape rather
/// than a flat fill, so a bar that floats over the transcript still separates
/// itself from what is behind it.

@available(iOS 26, *)
private func glassStyle(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// A glass surface in `shape`. Pass `interactive` only where the surface
    /// is itself the control — glass that flexes under a touch which does
    /// nothing is a lie about what is tappable.
    @ViewBuilder
    func glassSurface(
        in shape: some Shape,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: AnyShapeStyle = AnyShapeStyle(.regularMaterial)
    ) -> some View {
        if #available(iOS 26, *) {
            glassEffect(glassStyle(tint: tint, interactive: interactive), in: shape)
        } else {
            background(fallback, in: shape)
        }
    }
}

/// Groups glass surfaces so they sample one shared region.
///
/// Glass cannot sample glass: two bars in separate containers refract
/// differently and the pair reads as a mistake. Below iOS 26 this is the
/// layout it wraps and nothing else.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The blur a floating bottom bar rests on.
///
/// This is the material a system toolbar uses, so the transcript passing under
/// the composer is blurred rather than covered. It fades out over a short band
/// at its top instead of ending on a ruled line, and it reaches past the bottom
/// safe area so the home-indicator strip belongs to the same surface.
///
/// The bar draws this itself on every system. iOS 26's scroll edge effect does
/// not render under custom bar content — verified in the simulator, and the
/// same thing FB18350439 reports — and below 26 there is no such effect at all,
/// so one hand-drawn backdrop is what keeps the composer looking the same on
/// both.
private struct BarBlurBackdrop: View {
    /// How far the material takes to disappear. Fixed rather than a fraction of
    /// the bar: the bar grows when a permission panel or queued messages
    /// appear, and a proportional fade would haze more of the transcript every
    /// time it did.
    private let fade: CGFloat = 28

    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black], startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: fade)
                    Rectangle()
                }
            }
            .allowsHitTesting(false)
    }
}

extension View {
    /// Hangs `content` off the bottom edge as a bar the scroll view knows
    /// about, so the transcript keeps scrolling underneath it and comes to rest
    /// above it. `safeAreaBar` is how iOS 26 says "this is a bar"; below it the
    /// same room comes from a plain safe-area inset.
    @ViewBuilder
    func floatingBottomBar<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }

    /// What the bar's content rests on.
    ///
    /// On iOS 26 that is nothing: the composer's own glass floats over the
    /// transcript the way the system's bars do, and a material slab under it
    /// would be glass sitting on a tray rather than on the content. Below 26
    /// there is no glass, so the material is what separates the two.
    @ViewBuilder
    func floatingBarBackdrop() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            background { BarBlurBackdrop() }
        }
    }

    /// A hairline edge for the material fallback only — glass draws its own.
    @ViewBuilder
    func fallbackBorder(_ shape: some InsettableShape) -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            overlay { shape.strokeBorder(.separator) }
        }
    }
}
