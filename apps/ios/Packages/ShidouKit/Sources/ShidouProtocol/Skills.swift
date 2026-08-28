import Foundation

// Mirrors `crates/shidou-protocol/src/skills.rs`, which carries
// `rename_all = "camelCase"` throughout. `SkillSource` is an externally
// tagged enum: `"shared"` for the shared case, `{"provider": "claude"}` for
// the provider one.

public enum SkillSource: Codable, Hashable, Sendable {
    case shared
    case provider(ProviderKind)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case provider
    }

    public init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            self = raw == "shared" ? .shared : .unknown
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let provider = try container.decodeIfPresent(ProviderKind.self, forKey: .provider) {
            self = .provider(provider)
        } else {
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .shared, .unknown:
            var container = encoder.singleValueContainer()
            try container.encode("shared")
        case .provider(let provider):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(provider, forKey: .provider)
        }
    }

    /// Mirrors `SkillSource::label`, minus the localization the daemon does
    /// for the shared case — the app owns that string.
    public var providerName: String? {
        if case .provider(let provider) = self { return provider.displayName }
        return nil
    }
}

public enum SkillScope: String, WireStringEnum {
    case user, project
    case unknown

    public static var unknownCase: Self { .unknown }
}

public struct SkillInstall: Codable, Hashable, Sendable, Identifiable {
    public var source: SkillSource
    public var dir: String
    public var skillFile: String
    public var enabled: Bool

    public var id: String { dir }

    public init(source: SkillSource, dir: String, skillFile: String, enabled: Bool) {
        self.source = source
        self.dir = dir
        self.skillFile = skillFile
        self.enabled = enabled
    }
}

public struct SkillEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var scope: SkillScope
    public var project: String?
    public var installs: [SkillInstall]
    public var enabled: Bool
    public var allowedTools: String?
    public var body: String
    public var supportingFiles: Int
    public var totalBytes: UInt64
    public var modifiedAt: UInt64?
    public var duplicates: Int
    public var rowKey: UInt64

    public var id: UInt64 { rowKey }

    /// Mirrors `SkillEntry::primary`. The daemon guarantees at least one
    /// install, but a defensive `first` keeps a malformed catalog from
    /// trapping a view.
    public var primary: SkillInstall? { installs.first }

    /// Every directory this skill occupies — what an enable/disable or trash
    /// has to name, since one skill can be installed for several providers.
    public var dirs: [String] { installs.map(\.dir) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        scope = try container.decode(SkillScope.self, forKey: .scope)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        installs = try container.decodeIfPresent([SkillInstall].self, forKey: .installs) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowedTools = try container.decodeIfPresent(String.self, forKey: .allowedTools)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        supportingFiles = try container.decodeIfPresent(Int.self, forKey: .supportingFiles) ?? 0
        totalBytes = try container.decodeIfPresent(UInt64.self, forKey: .totalBytes) ?? 0
        modifiedAt = try container.decodeIfPresent(UInt64.self, forKey: .modifiedAt)
        duplicates = try container.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0
        rowKey = try container.decodeIfPresent(UInt64.self, forKey: .rowKey) ?? 0
    }
}

public struct SkillsCatalog: Codable, Hashable, Sendable {
    public var skills: [SkillEntry]

    public init(skills: [SkillEntry] = []) {
        self.skills = skills
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = try container.decodeIfPresent([SkillEntry].self, forKey: .skills) ?? []
    }

    /// Mirrors `SkillsCatalog::disabled_count`.
    public var disabledCount: Int { skills.filter { !$0.enabled }.count }
}
