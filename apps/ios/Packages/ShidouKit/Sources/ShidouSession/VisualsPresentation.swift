import Foundation
import ShidouProtocol

/// The gallery's share of `apps/web/src/lib/visuals-presentation.ts`.
///
/// The desktop's justified-masonry plan and its folder picker are not ported:
/// a phone shows one narrow column of folders and a fixed grid inside each,
/// so the row plan has nothing to justify and the picker has nowhere to go.
/// What does carry over is which files count as images, how they sort, and
/// how a workspace-relative path becomes a daemon path — the three answers a
/// divergence would make visible as a missing or unopenable picture.
public enum VisualsPresentation {
    /// Mirrors `VISUAL_IMAGE_EXTENSIONS` in
    /// `crates/shidou-protocol/src/protocol.rs`, which both other clients read
    /// from the same constant.
    public static let imageExtensions: Set<String> = [
        "gif", "jpeg", "jpg", "png", "svg", "webp",
    ]

    public static func isSupported(path: String) -> Bool {
        imageExtensions.contains(extensionOf(path))
    }

    static func extensionOf(_ path: String) -> String {
        guard let dot = path.lastIndex(of: "."), dot < path.index(before: path.endIndex) else {
            return ""
        }
        let suffix = path[path.index(after: dot)...]
        // A dot in a directory name is not a file extension.
        guard !suffix.contains("/") else { return "" }
        return suffix.lowercased()
    }

    /// Every supported image in the listing, in stable path order.
    public static func images(in entries: [FileEntry]) -> [FileEntry] {
        entries
            .filter { !$0.isDir && isSupported(path: $0.path) }
            .sorted { $0.path < $1.path }
            .prefix(WorkspaceSurfaces.visualGalleryCap)
            .map { $0 }
    }

    /// The folder part of a workspace-relative path; the empty string is the
    /// workspace root.
    public static func folder(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let separator = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[normalized.startIndex..<separator])
    }

    /// One section per folder holding images. A phone reads a gallery by
    /// folder, so the section header carries the orientation the desktop's
    /// folder picker provides.
    public struct Section: Identifiable, Hashable, Sendable {
        public var folder: String
        public var images: [FileEntry]

        public var id: String { folder }

        /// The workspace root has no name of its own.
        public var title: String { folder.isEmpty ? "." : folder }
    }

    /// Sorted component-wise, like the web client's folder choices: the
    /// workspace root leads and every folder is immediately followed by its
    /// descendants. Plain string order breaks that (`pages-x` sorts before
    /// `pages/…`), which reads as a shuffled tree.
    public static func sections(_ images: [FileEntry]) -> [Section] {
        var grouped: [String: [FileEntry]] = [:]
        for image in images { grouped[folder(of: image.path), default: []].append(image) }
        return grouped.keys
            .sorted { left, right in
                let leftParts = left.isEmpty ? [] : left.split(separator: "/")
                let rightParts = right.isEmpty ? [] : right.split(separator: "/")
                for index in 0..<min(leftParts.count, rightParts.count)
                where leftParts[index] != rightParts[index] {
                    return leftParts[index] < rightParts[index]
                }
                return leftParts.count < rightParts.count
            }
            .map { Section(folder: $0, images: grouped[$0] ?? []) }
    }

    /// Mirrors `workspacePath` in the web client: join a daemon root and a
    /// workspace-relative path with the separator the root itself uses, so a
    /// Windows daemon does not receive a mixed path. This is the one door from
    /// the surfaces' path space to a path the daemon can open.
    public static func workspacePath(root: String, relativePath: WorkspaceRelativePath) -> String {
        let separator = root.contains("\\") && !root.contains("/") ? "\\" : "/"
        var trimmedRoot = root
        while trimmedRoot.hasSuffix("/") || trimmedRoot.hasSuffix("\\") {
            trimmedRoot.removeLast()
        }
        var trimmedPath = relativePath.rawValue
        while trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("\\") {
            trimmedPath.removeFirst()
        }
        return trimmedRoot + separator + trimmedPath
    }
}
