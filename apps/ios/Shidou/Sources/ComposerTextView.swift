import SwiftUI
import UIKit

/// What a hardware keyboard can do to the suggestion list while the caret is
/// still in the text view.
enum ComposerKeyCommand {
    case previous
    case next
    case accept
    case dismiss
}

/// A text view that yields the arrow keys, Return, Tab and Escape while the
/// suggestion list is open, and behaves like an ordinary text view the rest of
/// the time — so Return still makes a newline when there is nothing to accept.
final class ComposerInputTextView: UITextView {
    var suggestionsOpen = false
    var onKeyCommand: ((ComposerKeyCommand) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        guard suggestionsOpen else { return nil }
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousSuggestion)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextSuggestion)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(acceptSuggestion)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(acceptSuggestion)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissSuggestions)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func previousSuggestion() { onKeyCommand?(.previous) }
    @objc private func nextSuggestion() { onKeyCommand?(.next) }
    @objc private func acceptSuggestion() { onKeyCommand?(.accept) }
    @objc private func dismissSuggestions() { onKeyCommand?(.dismiss) }
}

/// The composer's text input.
///
/// It is a `UITextView` rather than SwiftUI's `TextEditor` because the
/// composer needs the caret: `@file` and `/command` completion is driven by
/// which token the caret is inside, and iOS 17's SwiftUI text views do not
/// report a selection. Wrapping the real control also gets the rest for free —
/// the growing height, the keyboard's interactive dismissal, Dynamic Type, and
/// VoiceOver's own text-view rotor.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// Caret offset in characters. Autocomplete reads it every keystroke.
    @Binding var selection: Int
    @Binding var focused: Bool
    /// Measured content height, so the box grows with what is typed and stops.
    @Binding var height: CGFloat

    let placeholder: String
    let maxHeight: CGFloat
    /// While the suggestion list is up, the arrow keys, Return, Tab and Escape
    /// belong to it rather than to the text.
    var suggestionsOpen = false
    var onKeyCommand: (ComposerKeyCommand) -> Void = { _ in }

    func makeUIView(context: Context) -> ComposerInputTextView {
        let view = ComposerInputTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.keyboardDismissMode = .interactive
        // A prompt is prose, not an identifier: the ordinary text behaviours
        // are the right ones.
        view.autocapitalizationType = .sentences
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.accessibilityLabel = placeholder

        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isAccessibilityElement = false
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor),
        ])
        context.coordinator.placeholderLabel = placeholderLabel
        return view
    }

    func updateUIView(_ view: ComposerInputTextView, context: Context) {
        context.coordinator.parent = self
        view.suggestionsOpen = suggestionsOpen
        view.onKeyCommand = onKeyCommand
        if view.text != text {
            view.text = text
            context.coordinator.applySelection(selection, to: view)
        } else if view.offset(from: view.beginningOfDocument, to: view.selectedTextRange?.start
            ?? view.beginningOfDocument) != selection
            && !view.isFirstResponder
        {
            context.coordinator.applySelection(selection, to: view)
        }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        context.coordinator.placeholderLabel?.text = placeholder
        view.accessibilityLabel = placeholder

        if focused && !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !focused && view.isFirstResponder {
            view.resignFirstResponder()
        }
        context.coordinator.measure(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var placeholderLabel: UILabel?
        private var lastHeight: CGFloat = 0

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func applySelection(_ offset: Int, to view: UITextView) {
            let clamped = max(0, min(offset, view.text.count))
            guard let position = view.position(from: view.beginningOfDocument, offset: clamped)
            else { return }
            view.selectedTextRange = view.textRange(from: position, to: position)
        }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            publishSelection(view)
            measure(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            publishSelection(view)
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.focused { parent.focused = false }
        }

        private func publishSelection(_ view: UITextView) {
            guard let start = view.selectedTextRange?.start else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: start)
            if parent.selection != offset { parent.selection = offset }
        }

        /// One measurement per change, and only published when it moves: the
        /// height feeds a layout, and a binding that rewrites itself every pass
        /// is how a text view starts fighting its own container.
        func measure(_ view: UITextView) {
            let width = view.bounds.width
            guard width > 0 else { return }
            let fitted = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let bounded = min(max(fitted, view.font?.lineHeight ?? 20), parent.maxHeight)
            guard abs(bounded - lastHeight) > 0.5 else { return }
            lastHeight = bounded
            let height = bounded
            DispatchQueue.main.async { [parent] in
                parent.height = height
            }
        }
    }
}
