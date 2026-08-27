import Observation
import ShidouMarkdown
import SwiftUI

/// Per-message markdown parsers, kept outside the view tree.
///
/// A `LazyVStack` tears down and rebuilds row views as they scroll, so a
/// parser owned by a row would restart from scratch every time the row came
/// back — and a streaming message would lose the very stable-prefix state that
/// makes streaming cheap. Keying them by message id here means a row builder
/// asks for blocks and gets an answer that is already computed.
@MainActor
final class MarkdownStore {
    private var parsers: [UUID: IncrementalMarkdown] = [:]
    /// A message that has stopped streaming can never change again, so its
    /// final blocks are cached and its parser released.
    private var settled: [UUID: [TopBlock]] = [:]

    func blocks(for id: UUID, content: String, streaming: Bool) -> [TopBlock] {
        if !streaming, let cached = settled[id] { return cached }
        let parser = parsers[id] ?? {
            let parser = IncrementalMarkdown()
            parsers[id] = parser
            return parser
        }()
        parser.setText(content)
        let blocks = parser.displayBlocks(streaming: streaming)
        if !streaming {
            settled[id] = blocks
            parsers.removeValue(forKey: id)
        }
        return blocks
    }

    /// Drop everything: a refetched transcript may have replaced messages this
    /// store has cached under ids that no longer mean the same thing.
    func reset() {
        parsers.removeAll()
        settled.removeAll()
    }
}

/// Syntax highlights, computed off the main thread and read from a store.
///
/// The view asks for spans on every frame and gets `nil` until the work lands,
/// which renders as plain code in the same place — no layout moves when the
/// colours arrive.
@MainActor
@Observable
final class HighlightStore {
    private struct Key: Hashable {
        let code: String
        let language: String?
    }

    private var results: [Key: [HighlightedSpan]] = [:]
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private let highlighter = SyntaxHighlighter()

    func spans(code: String, language: String?) -> [HighlightedSpan]? {
        results[Key(code: code, language: language)]
    }

    func load(code: String, language: String?) async {
        let key = Key(code: code, language: language)
        guard results[key] == nil, inFlight.insert(key).inserted else { return }
        let spans = await highlighter.spans(for: code, language: language)
        inFlight.remove(key)
        results[key] = spans
    }
}
