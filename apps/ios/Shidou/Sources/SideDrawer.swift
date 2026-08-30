import SwiftUI
import UIKit

/// The iPhone task switcher: a sidebar the content slides off to reveal.
///
/// SwiftUI has no compact drawer — `NavigationSplitView` collapses to a stack
/// on iPhone — so the shape is built here, but built the way the platform
/// builds it: a real `UIScreenEdgePanGestureRecognizer` pulls it open from the
/// left edge, a drag anywhere on the panel or the dimmed content pushes it
/// back, and both track the finger rather than playing a canned animation.
/// Releasing hands off to a spring that respects where the finger was going.
struct SideDrawer<Sidebar: View, Content: View>: View {
    @Binding var isOpen: Bool
    /// Three quarters of the screen, near enough. The quarter of the task
    /// left showing is what keeps the place you are coming back to, and it
    /// has to be wide enough for the task's own leading button to sit in it
    /// with air on both sides — the toolbar's inset is the system's, so the
    /// room has to come from here.
    var widthFraction: CGFloat = 0.76
    var maxWidth: CGFloat = 420
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var containerWidth: CGFloat = 0
    /// In-flight finger translation. Zero whenever nothing is being dragged,
    /// so `isOpen` alone describes the resting state.
    @State private var drag: CGFloat = 0
    @State private var dragging = false

    /// The device's own corner, near enough: the task keeps the shape it had
    /// full-screen as it slides aside, rather than growing a new one.
    private let cornerRadius: CGFloat = 48

    private var width: CGFloat {
        guard containerWidth > 0 else { return 0 }
        return min(maxWidth, containerWidth * widthFraction)
    }

    /// 0 closed, 1 open — everything the drawer animates is a function of this.
    private var progress: CGFloat {
        guard width > 0 else { return isOpen ? 1 : 0 }
        return min(1, max(0, ((isOpen ? width : 0) + drag) / width))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            sidebarLayer
            contentLayer
        }
        .background {
            // Measured outside the safe area so a landscape notch does not
            // make the panel narrower than the fraction asks for.
            GeometryReader { geometry in
                Color.clear.preference(key: DrawerWidthKey.self, value: geometry.size.width)
            }
            .ignoresSafeArea()
        }
        .onPreferenceChange(DrawerWidthKey.self) { containerWidth = $0 }
        .background {
            ScreenEdgePan(
                isEnabled: !isOpen,
                edge: layoutDirection == .rightToLeft ? .right : .left,
                onChange: { translation in
                    dragging = true
                    drag = max(0, flipped(translation))
                },
                onEnd: { _, velocity in settle(velocity: flipped(velocity)) }
            )
        }
    }

    // MARK: - Layers

    private var sidebarLayer: some View {
        sidebar()
            .frame(width: width > 0 ? width : nil)
            .frame(maxHeight: .infinity, alignment: .top)
            // A touch of parallax: the panel arrives rather than being already
            // there, which is what makes the pull feel attached to the finger.
            .offset(x: reduceMotion ? 0 : -(1 - progress) * width * 0.22)
            .opacity(progress == 0 ? 0 : 1)
            .accessibilityHidden(progress < 0.5)
            // Simultaneous, so the task list keeps its own scrolling and its
            // rows keep taking taps; the gesture only claims a drag once it is
            // unambiguously sideways.
            .simultaneousGesture(panelDrag)
    }

    private var contentLayer: some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius * progress, style: .continuous))
            // A hairline along the rounded edge so the task reads as a card
            // lifted off the drawer, not a screen cut in half.
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius * progress, style: .continuous)
                    .strokeBorder(.white.opacity(0.14 * progress), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if progress > 0 {
                    Rectangle()
                        .fill(.black.opacity(0.32 * progress))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { setOpen(false) }
                        .gesture(panelDrag)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Close tasks")
                }
            }
            .shadow(color: .black.opacity(0.3 * progress), radius: 20, x: -8)
            .offset(x: progress * width)
            .accessibilityHidden(progress > 0.5)
    }

    // MARK: - Gestures

    /// Closing drag, on the panel and on the dimmed task behind it. It waits
    /// 12 points and only claims horizontal movement, so the task list keeps
    /// scrolling vertically and its rows still take a tap.
    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isOpen else { return }
                guard dragging || abs(value.translation.width) > abs(value.translation.height)
                else { return }
                dragging = true
                drag = min(0, flipped(value.translation.width))
            }
            .onEnded { value in
                guard dragging else { return }
                settle(velocity: flipped(value.velocity.width))
            }
    }

    /// Where the drawer lands when the finger lifts: a flick decides on its
    /// own, and anything slower goes to whichever side it is already nearer.
    private func settle(velocity: CGFloat) {
        let flick: CGFloat = 300
        let open = velocity > flick ? true : velocity < -flick ? false : progress > 0.5
        dragging = false
        setOpen(open)
    }

    /// Right-to-left reads the drawer from the other edge, so every horizontal
    /// measurement changes sign.
    private func flipped(_ value: CGFloat) -> CGFloat {
        layoutDirection == .rightToLeft ? -value : value
    }

    private func setOpen(_ open: Bool) {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            drag = 0
            isOpen = open
        }
    }
}

private struct DrawerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A real screen-edge pan, installed on the hosting view controller's view.
///
/// The recognizer belongs to the controller rather than the window, so a
/// presented sheet does not hand its edge swipes back to the drawer
/// underneath it. Nothing is cancelled while it tracks, which is what lets a
/// swipe that starts at the edge but never becomes one leave the touch it
/// interrupted intact.
private struct ScreenEdgePan: UIViewRepresentable {
    var isEnabled: Bool
    var edge: UIRectEdge
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        view.isUserInteractionEnabled = false
        // A view that is not in a window yet has no responder chain to search,
        // and `updateUIView` may never run again to try a second time.
        view.movedToWindow = { [weak view] in
            guard let view else { return }
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        context.coordinator.recognizer.edges = edge
        context.coordinator.recognizer.isEnabled = isEnabled
        context.coordinator.attach(to: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onEnd: onEnd)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat, CGFloat) -> Void
        let recognizer = UIScreenEdgePanGestureRecognizer()
        private weak var host: UIView?

        init(onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChange = onChange
            self.onEnd = onEnd
            super.init()
            recognizer.addTarget(self, action: #selector(handle))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
        }

        /// Finds the view controller this SwiftUI view is hosted in and hangs
        /// the recognizer there, once.
        func attach(to view: UIView) {
            guard recognizer.view == nil else { return }
            var responder: UIResponder? = view
            while let next = responder?.next {
                if let controller = next as? UIViewController {
                    controller.view.addGestureRecognizer(recognizer)
                    host = controller.view
                    return
                }
                responder = next
            }
        }

        @objc private func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let host else { return }
            let translation = recognizer.translation(in: host).x
            switch recognizer.state {
            case .changed:
                onChange(translation)
            case .ended, .cancelled, .failed:
                onEnd(translation, recognizer.velocity(in: host).x)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// Never takes a touch: it is only here to find the view controller.
    private final class PassthroughView: UIView {
        var movedToWindow: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { movedToWindow?() }
        }
    }
}
