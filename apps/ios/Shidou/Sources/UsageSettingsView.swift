import Charts
import ShidouProtocol
import ShidouSession
import SwiftUI

/// What the agents have cost, with the desktop's charts at mobile density.
///
/// The daemon does the whole scan and the arithmetic; this only picks a window
/// and draws. That matters here more than elsewhere — a usage history is the
/// largest single response the phone asks for, and re-deriving any of it on
/// the main actor would be a visible stall on a screen the user is scrolling.
struct UsageSettingsView: View {
    @Environment(DaemonConnection.self) private var connection

    @State private var window = UsageWindow.trailingDays(30)
    @State private var history: UsageHistory?
    @State private var isLoading = false
    @State private var error: String?

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: windowBinding) {
                    ForEach(UsageWindowChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
            }

            if let history {
                Section {
                    TotalsRow(history: history)
                } header: {
                    Text(verbatim: "\(history.sinceDay.description) – \(history.untilDay.description)")
                } footer: {
                    if history.pricing == .unavailable {
                        Text("Model prices could not be fetched, so costs are estimates from what the providers reported.")
                    }
                }

                if !history.daily.isEmpty {
                    Section("By day") {
                        DailyChart(history: history)
                    }
                }

                if !history.providers.isEmpty {
                    Section("By agent") {
                        ForEach(history.providers) { slice in
                            ShareRow(
                                title: slice.provider.label,
                                cost: slice.costUsd,
                                tokens: slice.totalTokens,
                                share: slice.costShare
                            )
                        }
                    }
                }

                if !history.models.isEmpty {
                    Section("By model") {
                        ForEach(history.models.prefix(8)) { slice in
                            ShareRow(
                                title: slice.model,
                                subtitle: slice.provider.label,
                                cost: slice.costUsd,
                                tokens: slice.totalTokens,
                                share: slice.costShare
                            )
                        }
                    }
                }

                if !history.projects.isEmpty {
                    Section("By project") {
                        ForEach(history.projects.prefix(8)) { slice in
                            ShareRow(
                                title: slice.name,
                                subtitle: slice.path,
                                cost: slice.costUsd,
                                tokens: slice.totalTokens,
                                share: slice.costShare
                            )
                        }
                    }
                }

                if !history.errors.isEmpty {
                    Section("Skipped") {
                        ForEach(history.errors, id: \.self) { message in
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if history == nil {
                if isLoading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView {
                        Label("Could not read usage", systemImage: "chart.bar")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                }
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: UsageWindowChoice(window)) { await load() }
    }

    private var windowBinding: Binding<UsageWindowChoice> {
        Binding(
            get: { UsageWindowChoice(window) },
            set: { window = $0.window }
        )
    }

    private func load() async {
        guard let store else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            history = try await store.loadUsageHistory(window: window)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The five windows the daemon offers, plus the twelve-month roll-up its
/// monthly charts use. Mirrors `WINDOW_CHOICES`.
enum UsageWindowChoice: String, CaseIterable, Identifiable, Hashable {
    case week, month, quarter, thisMonth, lastMonth, year

    var id: String { rawValue }

    init(_ window: UsageWindow) {
        switch window {
        case .trailingDays(7): self = .week
        case .trailingDays(90): self = .quarter
        case .months: self = .year
        case .thisMonth: self = .thisMonth
        case .lastMonth: self = .lastMonth
        default: self = .month
        }
    }

    var window: UsageWindow {
        switch self {
        case .week: return .trailingDays(7)
        case .month: return .trailingDays(30)
        case .quarter: return .trailingDays(90)
        case .thisMonth: return .thisMonth
        case .lastMonth: return .lastMonth
        case .year: return .monthly
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .quarter: return "Last 90 days"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .year: return "Last 12 months"
        }
    }
}

private struct TotalsRow: View {
    let history: UsageHistory

    var body: some View {
        // At accessibility sizes three figures cannot share a row, and a
        // truncated cost is a wrong cost.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                figures
            }
            VStack(alignment: .leading, spacing: 10) {
                figures
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var figures: some View {
        Figure(title: "Cost", value: UsageFormat.cost(history.costUsd))
        Figure(title: "Tokens", value: UsageFormat.tokens(history.totalTokens))
        Figure(title: "Sessions", value: "\(history.sessions)")
    }
}

private struct Figure: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Cost per day, stacked by agent. Stacked rather than grouped because the
/// question a phone screen answers is "how much, and when" — the split is the
/// second reading, which the colour and the legend carry.
private struct DailyChart: View {
    let history: UsageHistory

    var body: some View {
        Chart {
            ForEach(history.daily) { day in
                ForEach(UsageProvider.all, id: \.self) { provider in
                    if let slice = day.provider(provider), slice.costUsd > 0 {
                        BarMark(
                            x: .value("Day", day.day.localNoon, unit: .day),
                            y: .value("Cost", slice.costUsd)
                        )
                        .foregroundStyle(by: .value("Agent", provider.label))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(verbatim: UsageFormat.cost(cost))
                    }
                }
            }
        }
        .frame(height: 180)
        .padding(.vertical, 6)
        .accessibilityLabel("Cost per day")
        .accessibilityValue(
            "\(UsageFormat.cost(history.costUsd)) over ^[\(history.daily.count) day](inflect: true)")
    }
}

private struct ShareRow: View {
    let title: String
    var subtitle: String?
    let cost: Double
    let tokens: UInt64
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).lineLimit(1)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: UsageFormat.cost(cost))
                    .font(.callout.monospacedDigit())
            }
            // The bar repeats what the numbers already say, so nothing depends
            // on reading it.
            ProgressView(value: min(max(share, 0), 1))
                .tint(.accentColor)
                .accessibilityHidden(true)
            Text("\(UsageFormat.tokens(tokens)) tokens · \(UsageFormat.percent(share))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

enum UsageFormat {
    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
    }

    static func tokens(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }
}
