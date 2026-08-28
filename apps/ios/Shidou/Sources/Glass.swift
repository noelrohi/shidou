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

extension View {
    /// The backdrop a floating bottom bar needs on a system without Liquid
    /// Glass. Under iOS 26 the glass surfaces float over the transcript and
    /// the scroll edge effect keeps them legible; below it, a bar material is
    /// what separates the composer from the text scrolling beneath it.
    @ViewBuilder
    func floatingBarBackdrop() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            background(.bar)
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
