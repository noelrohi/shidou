// PROTOTYPE — streaming transcript spike (wayfinder #9). Throwaway.
//
// The question under test: does ScrollView + LazyVStack +
// defaultScrollAnchor(.bottom) hold up on a physical iPhone with a long
// transcript and a growing streaming tail row? Evidence comes from the HUD
// (fps / worst frame / hitches / memory) and from scrubbing the list by hand
// while a turn streams.

import ShidouProtocol
import ShidouSession
import SwiftUI

// MARK: - Row assembly

private enum SpikeRow: Identifiable {
    case user(Message)
    case assistant(Message)
    case activities(key: String, [ActivityItem])

    var id: AnyHashable {
        switch self {
        case .user(let message), .assistant(let message): return message.id
        case .activities(let key, _): return key
        }
    }
}

private func assembleRows(_ session: AgentSession) -> [SpikeRow] {
    var blocksByIndex: [Int: [TranscriptBlock]] = [:]
    for block in session.transcriptBlocks {
        blocksByIndex[block.afterMessage, default: []].append(block)
    }
    var rows: [SpikeRow] = []
    for index in 0...session.messages.count {
        for (offset, block) in (blocksByIndex[index] ?? []).enumerated() {
            rows.append(.activities(key: "block-\(index)-\(offset)", block.activities))
        }
        guard index < session.messages.count else { break }
        let message = session.messages[index]
        rows.append(message.role == .user ? .user(message) : .assistant(message))
    }
    return rows
}

// MARK: - Screen

struct SpikeTranscriptScreen: View {
    @State private var feed = SpikeFeed()
    @State private var meter = SpikeFrameMeter()
    @State private var store = SpikeMarkdownStore()
    @State private var renderMarkdown = true

    var body: some View {
        let rows = assembleRows(feed.model.session)
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
        }
        .navigationTitle("Streaming spike")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            SpikeHUDView(meter: meter, rowCount: rows.count)
                .padding(.bottom, 4)
        }
        .onAppear {
            meter.start()
            if feed.model.session.messages.isEmpty {
                feed.preload(turns: 40)
            }
        }
        .onDisappear {
            meter.stop()
            feed.stop()
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button("40 turns") { preload(40) }
                Button("120 turns") { preload(120) }
                Spacer()
                Toggle("md", isOn: $renderMarkdown)
                    .labelsHidden()
                    .toggleStyle(.button)
                Button(feed.running ? "Stop" : "Stream") {
                    feed.running ? feed.stop() : feed.start()
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.footnote)
            HStack {
                Text("\(Int(feed.tokensPerSecond)) tok/s")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 64, alignment: .leading)
                Slider(value: $feed.tokensPerSecond, in: 10...120, step: 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func preload(_ turns: Int) {
        store.resetAll()
        meter.reset()
        feed.preload(turns: turns)
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: SpikeRow) -> some View {
        switch row {
        case .user(let message):
            HStack {
                Spacer(minLength: 48)
                Text(message.visibleContent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant(let message):
            if renderMarkdown {
                let blocks = store.blocks(
                    for: message.id, content: message.content, streaming: message.streaming)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { blockView($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .activities(_, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { activityView($0) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func blockView(_ block: SpikeBlock) -> some View {
        switch block {
        case .paragraph(_, let text):
            Text(text)
        case .heading(_, let level, let text):
            Text(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .codeBlock(_, _, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        case .listItems(_, let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(item)
                    }
                }
            }
        case .quote(_, let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(text).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func activityView(_ item: ActivityItem) -> some View {
        if item.kind == .reasoning, let reasoning = item.reasoning {
            VStack(alignment: .leading, spacing: 4) {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(reasoning.content)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.complete ? "checkmark.circle" : "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(item.complete ? Color.green : .secondary)
                Text(item.title)
                    .font(.callout)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
