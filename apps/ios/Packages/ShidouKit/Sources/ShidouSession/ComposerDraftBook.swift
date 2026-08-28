import Foundation
import ShidouProtocol

// Port of `apps/web/src/lib/composer-drafts.ts`.
//
// Drafts are server-synced, and several clients type into the same daemon at
// once. That is why a change is keyed rather than a whole-file snapshot: the
// phone sending everything it believes would quietly delete what someone just
// typed on the desktop. Every mutation here returns the one change to send.
extension ComposerDrafts {
    public func draft(for key: ComposerDraftKey) -> ComposerDraft {
        self[key] ?? ComposerDraft()
    }

    /// Applies a draft locally and returns the change to send, or `nil` when
    /// nothing actually differs. An empty draft is a removal.
    public mutating func setDraft(
        _ draft: ComposerDraft,
        for key: ComposerDraftKey
    ) -> ComposerDraftChange? {
        guard self.draft(for: key) != draft else { return nil }
        self[key] = draft.isEmpty ? nil : draft
        return ComposerDraftChange(target: key, draft: draft.isEmpty ? nil : draft)
    }

    /// Carries a draft across when a new task acquires an identity — a project
    /// switch, or the moment an unstarted task becomes a real one. It refuses
    /// to overwrite: whatever is already at the destination was typed there.
    public mutating func moveToEmpty(
        from source: ComposerDraftKey,
        to destination: ComposerDraftKey
    ) -> [ComposerDraftChange] {
        guard source != destination else { return [] }
        let carried = draft(for: source)
        guard !carried.isEmpty, draft(for: destination).isEmpty else { return [] }
        var changes: [ComposerDraftChange] = []
        if let change = setDraft(carried, for: destination) { changes.append(change) }
        if let change = setDraft(ComposerDraft(), for: source) { changes.append(change) }
        return changes
    }
}
