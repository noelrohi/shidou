import Foundation

// Mirrors `crates/shidou-protocol/src/usage_history.rs`, which carries
// `rename_all = "camelCase"` throughout. `chrono::NaiveDate` is a
// `"YYYY-MM-DD"` string on the wire, so it gets a small value type here
// rather than a `Date` — a usage day is a calendar day in the daemon host's
// zone, and pulling it through `Date` would drift it by the phone's offset.

public struct CalendarDay: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(wire: String) {
        let parts = wire.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = CalendarDay(wire: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a YYYY-MM-DD date: \(raw)")
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Noon in the current calendar, which is what a chart axis wants to
    /// format. Noon rather than midnight so a DST transition cannot move the
    /// label onto the neighbouring day.
    public var localNoon: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Externally tagged: `{"trailingDays": 7}`, `{"months": 12}`, `"thisMonth"`,
/// `"lastMonth"`.
public enum UsageWindow: Codable, Hashable, Sendable {
    case trailingDays(UInt32)
    case months(UInt32)
    case thisMonth
    case lastMonth

    /// Mirrors `WINDOW_CHOICES`.
    public static let choices: [UsageWindow] = [
        .trailingDays(7), .trailingDays(30), .trailingDays(90), .thisMonth, .lastMonth,
    ]

    /// Mirrors `MONTHLY_WINDOW`.
    public static let monthly = UsageWindow.months(12)

    private enum CodingKeys: String, CodingKey {
        case trailingDays, months
    }

    public init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            self = raw == "lastMonth" ? .lastMonth : .thisMonth
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let days = try container.decodeIfPresent(UInt32.self, forKey: .trailingDays) {
            self = .trailingDays(days)
        } else if let months = try container.decodeIfPresent(UInt32.self, forKey: .months) {
            self = .months(months)
        } else {
            self = .thisMonth
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .trailingDays(let days):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(days, forKey: .trailingDays)
        case .months(let months):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(months, forKey: .months)
        case .thisMonth:
            var container = encoder.singleValueContainer()
            try container.encode("thisMonth")
        case .lastMonth:
            var container = encoder.singleValueContainer()
            try container.encode("lastMonth")
        }
    }
}

public enum UsageProvider: String, WireStringEnum {
    case claude, codex
    case unknown

    public static var unknownCase: Self { .unknown }

    public static let all: [UsageProvider] = [.claude, .codex]

    /// Mirrors `UsageProvider::label` — a product name, not a translated one.
    public var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .unknown: return "Unknown"
        }
    }

    /// Mirrors `UsageProvider::index`, which is the position each provider
    /// occupies in the fixed two-slot `byProvider` arrays.
    public var index: Int { self == .codex ? 1 : 0 }
}

public struct TokenTotals: Codable, Hashable, Sendable {
    public var uncachedInput: UInt64
    public var cachedInput: UInt64
    public var cacheCreation: UInt64
    public var output: UInt64
    public var reasoning: UInt64

    public var total: UInt64 { uncachedInput + cachedInput + cacheCreation + output }
}

public enum PricingStatus: String, WireStringEnum {
    case fresh, cached, unavailable
    case unknown

    public static var unknownCase: Self { .unknown }
}

public struct ProviderSlice: Codable, Hashable, Sendable, Identifiable {
    public var provider: UsageProvider
    public var costUsd: Double
    public var totalTokens: UInt64
    public var costShare: Double
    public var tokenShare: Double

    public var id: UsageProvider { provider }
}

public struct ModelSlice: Codable, Hashable, Sendable, Identifiable {
    public var provider: UsageProvider
    public var model: String
    public var costUsd: Double
    public var totalTokens: UInt64
    public var costShare: Double

    public var id: String { "\(provider.rawValue):\(model)" }
}

public struct ProviderDay: Codable, Hashable, Sendable {
    public var costUsd: Double
    public var totalTokens: UInt64
}

public struct DaySlice: Codable, Hashable, Sendable, Identifiable {
    public var day: CalendarDay
    public var costUsd: Double
    public var totalTokens: UInt64
    public var byProvider: [ProviderDay]

    public var id: CalendarDay { day }

    public func provider(_ provider: UsageProvider) -> ProviderDay? {
        byProvider.indices.contains(provider.index) ? byProvider[provider.index] : nil
    }
}

public struct CostQuality: Codable, Hashable, Sendable {
    public var providerReportedShare: Double
    public var modelPricedShare: Double
    public var unpricedShare: Double
    public var cacheSavingsUsd: Double
}

/// `top_models` is a Rust `Vec<(String, f64)>`, which serde writes as an
/// array of two-element arrays.
public struct ModelCost: Hashable, Sendable, Identifiable, Decodable {
    public var model: String
    public var costUsd: Double

    public var id: String { model }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        model = try container.decode(String.self)
        costUsd = try container.decode(Double.self)
    }
}

public struct MonthSlice: Codable, Hashable, Sendable, Identifiable {
    public var firstDay: CalendarDay
    public var costUsd: Double
    public var totalTokens: UInt64
    public var byProvider: [ProviderDay]
    public var sessions: UInt64
    public var activeDays: UInt32
    public var topModels: [ModelCost]

    public var id: CalendarDay { firstDay }
}

public struct ProjectSlice: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var costUsd: Double
    public var totalTokens: UInt64
    public var byProvider: [ProviderDay]
    public var sessions: UInt64
    public var costShare: Double
    public var lastDay: CalendarDay?
    public var topModels: [ModelCost]

    public var id: String { path }

    /// The last path component, which is what a narrow row can show.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

public struct UsageHistory: Codable, Hashable, Sendable {
    public var window: UsageWindow
    public var sinceDay: CalendarDay
    public var untilDay: CalendarDay
    public var totals: TokenTotals
    public var totalTokens: UInt64
    public var costUsd: Double
    public var records: UInt64
    public var sessions: UInt64
    public var providers: [ProviderSlice]
    public var models: [ModelSlice]
    public var daily: [DaySlice]
    public var months: [MonthSlice]
    public var projects: [ProjectSlice]
    public var quality: CostQuality
    public var pricing: PricingStatus
    public var scannedFiles: Int
    public var skippedFiles: Int
    public var errors: [String]

    private enum CodingKeys: String, CodingKey {
        case window, sinceDay, untilDay, totals, totalTokens, costUsd, records, sessions
        case providers, models, daily, months, projects, quality, pricing
        case scannedFiles, skippedFiles, errors
    }
}

extension ModelCost: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(model)
        try container.encode(costUsd)
    }
}
