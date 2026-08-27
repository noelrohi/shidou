import Foundation

/// Where a link in the transcript points, ported from the web client's
/// `lib/transcript-links.ts`.
///
/// In this slice both file routes are inert: the Surfaces Sheet that opens
/// them lands in slice ③. Parsing and rendering them now is the point —
/// a transcript that shows `src/limiter.rs:42` as ordinary prose today and as
/// a link tomorrow would have re-laid-out every answer in between.
public enum TranscriptLinkRoute: Hashable, Sendable {
    /// A path inside the session's workspace, relative to it.
    case projectFile(path: String, line: Int?)
    /// An absolute path on the daemon host, outside the workspace.
    case remoteFile(path: String, line: Int?)
    /// Anything else — a web URL, opened by the system.
    case external
}

public enum TranscriptLinks {
    public static func route(target: String, workspace: String? = nil) -> TranscriptLinkRoute {
        let located = fileLocation(target.trimmingCharacters(in: .whitespaces))
        guard let path = located?.path else { return .external }
        let line = located?.line
        let normalized = normalize(path)
        if let workspace {
            let root = normalize(workspace)
            let prefix = root == "/" ? "/" : root + "/"
            if normalized.hasPrefix(prefix), normalized != root {
                return .projectFile(path: String(normalized.dropFirst(prefix.count)), line: line)
            }
        }
        return .remoteFile(path: normalized, line: line)
    }

    /// Splits `path:12`, `path:12:4` and `path#L12` into path and line.
    static func fileLocation(_ target: String) -> (path: String, line: Int?)? {
        let (stripped, line) = stripLocation(target)
        var path: String
        if stripped.hasPrefix("/") {
            path = stripped
        } else if stripped.hasPrefix("file://localhost/") {
            path = String(stripped.dropFirst("file://localhost".count))
        } else if stripped.hasPrefix("file:///") {
            path = String(stripped.dropFirst("file://".count))
        } else if stripped.hasPrefix("file:/") {
            path = String(stripped.dropFirst("file:".count))
        } else {
            return nil
        }
        path = path.removingPercentEncoding ?? path
        return (path, line)
    }

    private static func stripLocation(_ target: String) -> (String, Int?) {
        if let hash = target.range(of: "#L", options: .backwards) {
            let suffix = target[hash.upperBound...]
            let head = suffix.prefix { $0.isNumber }
            let rest = suffix.dropFirst(head.count)
            let restIsColumn = rest.isEmpty
                || (rest.first == "C" && rest.dropFirst().allSatisfy(\.isNumber))
            if !head.isEmpty, restIsColumn {
                return (String(target[..<hash.lowerBound]), Int(head))
            }
        }
        // `path:12:4` — the column is dropped, the line is kept.
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[parts.count - 1].allSatisfy(\.isNumber),
            parts[parts.count - 2].allSatisfy(\.isNumber), !parts[parts.count - 2].isEmpty
        {
            return (parts.dropLast(2).joined(separator: ":"), Int(parts[parts.count - 2]))
        }
        if parts.count >= 2, let last = parts.last, last.allSatisfy(\.isNumber), !last.isEmpty {
            return (parts.dropLast().joined(separator: ":"), Int(last))
        }
        return (target, nil)
    }

    /// Resolve `.` and `..` without touching the filesystem — the path names a
    /// file on the daemon host, which the phone cannot see.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
