import Foundation
import ShidouProtocol

// Port of `apps/web/src/lib/composer-preferences.ts`, on `UserDefaults` rather
// than `localStorage`. This is disposable convenience state — what the last
// task was started with, and which models are starred — so it is deliberately
// not in the Keychain and not on the daemon: losing it costs two taps.

public struct RememberedModelTraits: Codable, Hashable, Sendable {
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var contextWindow: String?

    public init(
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        contextWindow: String? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.contextWindow = contextWindow
    }
}

public struct ComposerPreferences: Codable, Sendable {
    public var lastProvider: ProviderKind
    public var lastModel: String?
    public var lastReasoningEffort: String?
    public var lastServiceTier: String?
    public var lastContextWindow: String?
    public var modelTraits: [String: RememberedModelTraits]
    /// `provider:model` keys the model picker stars.
    public var favoriteModels: [String]

    public init(
        lastProvider: ProviderKind = .codex,
        lastModel: String? = nil,
        lastReasoningEffort: String? = nil,
        lastServiceTier: String? = nil,
        lastContextWindow: String? = nil,
        modelTraits: [String: RememberedModelTraits] = [:],
        favoriteModels: [String] = []
    ) {
        self.lastProvider = lastProvider
        self.lastModel = lastModel
        self.lastReasoningEffort = lastReasoningEffort
        self.lastServiceTier = lastServiceTier
        self.lastContextWindow = lastContextWindow
        self.modelTraits = modelTraits
        self.favoriteModels = favoriteModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decodeIfPresent(ProviderKind.self, forKey: .lastProvider)
        // A provider this build does not know is not a preference we can honour.
        lastProvider = (provider == .unknown ? nil : provider) ?? .codex
        lastModel = try container.decodeIfPresent(String.self, forKey: .lastModel)
        lastReasoningEffort = try container.decodeIfPresent(
            String.self, forKey: .lastReasoningEffort)
        lastServiceTier = try container.decodeIfPresent(String.self, forKey: .lastServiceTier)
        lastContextWindow = try container.decodeIfPresent(String.self, forKey: .lastContextWindow)
        modelTraits =
            try container.decodeIfPresent([String: RememberedModelTraits].self, forKey: .modelTraits)
            ?? [:]
        favoriteModels =
            try container.decodeIfPresent([String].self, forKey: .favoriteModels) ?? []
    }

    public static func modelKey(provider: ProviderKind, model: String) -> String {
        "\(provider.rawValue)\u{0}\(model)"
    }

    public static func favoriteKey(provider: ProviderKind, model: String) -> String {
        "\(provider.rawValue):\(model)"
    }

    public func traits(provider: ProviderKind, model: String) -> RememberedModelTraits? {
        modelTraits[Self.modelKey(provider: provider, model: model)]
    }

    public func isFavorite(provider: ProviderKind, model: String) -> Bool {
        favoriteModels.contains(Self.favoriteKey(provider: provider, model: model))
    }

    public mutating func toggleFavorite(provider: ProviderKind, model: String) {
        let key = Self.favoriteKey(provider: provider, model: model)
        if let index = favoriteModels.firstIndex(of: key) {
            favoriteModels.remove(at: index)
        } else {
            favoriteModels.append(key)
        }
    }

    /// Records what a task was configured with, so the next New Task opens on
    /// the same model and the same model keeps the traits it was last given.
    public mutating func remember(_ session: AgentSession) {
        guard let model = session.model else { return }
        lastProvider = session.provider
        lastModel = model
        lastReasoningEffort = session.reasoningEffort
        lastServiceTier = session.serviceTier
        lastContextWindow = session.contextWindow
        modelTraits[Self.modelKey(provider: session.provider, model: model)] =
            RememberedModelTraits(
                reasoningEffort: session.reasoningEffort,
                serviceTier: session.serviceTier,
                contextWindow: session.contextWindow
            )
    }
}

/// Preferences are per daemon: the models one Mac has installed say nothing
/// about another's.
public struct ComposerPreferenceStore: Sendable {
    private static let key = "shidou.composer-preferences.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func preferences(for daemonAddress: String) -> ComposerPreferences {
        guard let data = defaults.data(forKey: Self.key),
            let all = try? JSONDecoder().decode([String: ComposerPreferences].self, from: data),
            let preferences = all[daemonAddress]
        else { return ComposerPreferences() }
        return preferences
    }

    public func save(_ preferences: ComposerPreferences, for daemonAddress: String) {
        var all: [String: ComposerPreferences] = [:]
        if let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([String: ComposerPreferences].self, from: data)
        {
            all = decoded
        }
        all[daemonAddress] = preferences
        guard let encoded = try? JSONEncoder().encode(all) else { return }
        defaults.set(encoded, forKey: Self.key)
    }
}
