import Foundation

/// A path relative to the workspace root — the only path space the surfaces
/// speak. A daemon-absolute path cannot be mistaken for one of these, and
/// leaving this space for one the daemon can open has exactly one door:
/// `VisualsPresentation.workspacePath`.
public struct WorkspaceRelativePath: Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The last component, for a navigation title or a caption.
    public var name: String {
        rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }
}
