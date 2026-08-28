import Foundation

// Mirrors `crates/shidou-protocol/src/attachments.rs`. `StoredAttachment` and
// `AttachmentUploadEntry` do carry `rename_all = "camelCase"`; the upload
// enum's own fields do not, so `data_base64` stays snake_case.

public enum AttachmentLimits {
    public static let attachmentScheme = "shidou-attachment:"
    public static let blobScheme = "shidou-blob:"
    public static let maxAttachmentBytes = 32 * 1024 * 1024
    /// The largest file we will base64 into one wire frame, with room left for
    /// the envelope around it.
    public static let maxUploadBytes = (ShidouWire.maxWireMessageBytes * 3) / 4 - 1024 * 1024
}

public struct AttachmentUploadEntry: Encodable, Sendable {
    public var relativePath: String
    public var dataBase64: String

    public init(relativePath: String, dataBase64: String) {
        self.relativePath = relativePath
        self.dataBase64 = dataBase64
    }
}

/// Encode-only: the phone uploads, it never receives an upload.
public enum AttachmentUpload: Sendable {
    case file(dataBase64: String)
    case directory(entries: [AttachmentUploadEntry])
}

extension AttachmentUpload: Encodable {
    enum CodingKeys: String, CodingKey {
        case kind, entries
        case dataBase64 = "data_base64"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let dataBase64):
            try container.encode("file", forKey: .kind)
            try container.encode(dataBase64, forKey: .dataBase64)
        case .directory(let entries):
            try container.encode("directory", forKey: .kind)
            try container.encode(entries, forKey: .entries)
        }
    }
}

public struct StoredAttachment: Codable, Hashable, Sendable {
    public var reference: String
    public var path: String
    public var name: String
    public var isDir: Bool

    public init(reference: String, path: String, name: String, isDir: Bool) {
        self.reference = reference
        self.path = path
        self.name = name
        self.isDir = isDir
    }
}

extension MessageAttachment {
    /// The extensions Shidou treats as previewable images, matching
    /// `apps/web/src/lib/attachments.ts`.
    public static func isImageName(_ name: String) -> Bool {
        let suffix = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return ["avif", "gif", "heic", "jpeg", "jpg", "png", "svg", "webp"].contains(suffix)
    }

    public static func imageMimeType(for name: String) -> String {
        let suffix = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        switch suffix {
        case "avif": return "image/avif"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "jpeg", "jpg": return "image/jpeg"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
