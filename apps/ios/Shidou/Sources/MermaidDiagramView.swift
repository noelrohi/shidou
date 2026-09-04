import SwiftUI
import UIKit

/// A settled exact `mermaid` fence. The source remains the initial, loading,
/// and failure presentation, and can always be disclosed after rendering.
struct MermaidDiagramView: View {
    let source: String
    let store: MermaidStore

    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = Phase.loading
    @State private var width = 0
    @State private var showsSource = false
    @State private var copied = false

    private enum Phase {
        case loading
        case image(UIImage)
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .image(let image) = phase {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .accessibilityLabel("Mermaid diagram")
                    .accessibilityHint("Use Show source to read or copy the diagram source")
                if showsSource { sourceCode }
            } else {
                sourceCode
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .onGeometryChange(for: Int.self) { geometry in
            Int(geometry.size.width.rounded(.down))
        } action: { measuredWidth in
            let measuredWidth = max(0, measuredWidth - 20)
            if abs(measuredWidth - width) > 1 { width = measuredWidth }
        }
        .task(id: requestKey) {
            guard width > 0 else { return }
            phase = .loading
            do {
                let image = try await store.image(
                    source: source,
                    width: width,
                    appearance: colorScheme == .dark ? .dark : .light
                )
                guard !Task.isCancelled else { return }
                phase = .image(image)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private var requestKey: String {
        "\(colorScheme == .dark ? "dark" : "light")\u{1}\(width)\u{1}\(source)"
    }

    private var header: some View {
        HStack(spacing: 4) {
            Label(statusLabel, systemImage: "flowchart")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if case .loading = phase {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            if case .image = phase {
                Button(showsSource ? "Hide source" : "Show source") {
                    showsSource.toggle()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
            }
            Button {
                UIPasteboard.general.string = source
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(copied ? "Diagram source copied" : "Copy diagram source")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.top, 2)
    }

    private var statusLabel: String {
        switch phase {
        case .loading: return String(localized: "Mermaid diagram, rendering")
        case .image: return String(localized: "Mermaid diagram")
        case .failed: return String(localized: "Mermaid diagram unavailable")
        }
    }

    private var sourceCode: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .accessibilityLabel("Mermaid diagram source")
        .accessibilityValue(source)
    }
}
