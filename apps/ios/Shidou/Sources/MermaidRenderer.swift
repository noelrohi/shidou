import UIKit
import WebKit

/// Mermaid diagrams rendered by one private WebKit page and cached as images.
///
/// The page contains the official Mermaid bundle and a restrictive CSP. WebKit
/// runs Mermaid in its content process; the main actor only coordinates the
/// asynchronous call and snapshots the finished SVG. Keeping one page avoids a
/// `WKWebView` per transcript row, which would defeat LazyVStack virtualization.
@MainActor
final class MermaidStore {
    enum Appearance: String, Hashable {
        case light
        case dark
    }

    private struct Key: Hashable {
        let source: String
        let width: Int
        let appearance: Appearance
    }

    private enum Cached {
        case image(UIImage)
        case failure
    }

    private struct CacheEntry {
        let value: Cached
        /// Decoded backing-store bytes, not compressed resource bytes.
        let byteCost: Int
    }

    /// Avoid starting WebKit for transcripts that contain no diagrams.
    private lazy var renderer = MermaidRenderer()
    private var cached: [Key: CacheEntry] = [:]
    private var order: [Key] = []
    private var cachedImageBytes = 0
    private var inFlight: [Key: Task<UIImage, Error>] = [:]
    private let cacheEntryLimit = 24
    private let cacheByteLimit = 32 * 1_024 * 1_024

    func image(source: String, width: Int, appearance: Appearance) async throws -> UIImage {
        let key = Key(source: source, width: width, appearance: appearance)
        if let cached = cached[key] {
            switch cached.value {
            case .image(let image): return image
            case .failure: throw MermaidRenderError.invalidDiagram
            }
        }
        if let task = inFlight[key] { return try await task.value }

        let task = Task { @MainActor [renderer] in
            try await renderer.render(source: source, width: width, appearance: appearance)
        }
        inFlight[key] = task
        do {
            let image = try await task.value
            inFlight.removeValue(forKey: key)
            insert(.image(image), for: key)
            return image
        } catch {
            inFlight.removeValue(forKey: key)
            insert(.failure, for: key)
            throw error
        }
    }

    private func insert(_ value: Cached, for key: Key) {
        let byteCost = switch value {
        case .image(let image): Self.decodedByteCost(image)
        case .failure: 0
        }
        if let previous = cached.removeValue(forKey: key) {
            cachedImageBytes -= previous.byteCost
        }
        order.removeAll { $0 == key }

        // The visible view still receives an unusually large image, but the
        // transcript cache never retains one image beyond its total budget.
        guard byteCost <= cacheByteLimit else { return }
        cached[key] = CacheEntry(value: value, byteCost: byteCost)
        cachedImageBytes += byteCost
        order.append(key)
        while order.count > cacheEntryLimit || cachedImageBytes > cacheByteLimit {
            let evicted = order.removeFirst()
            if let entry = cached.removeValue(forKey: evicted) {
                cachedImageBytes -= entry.byteCost
            }
        }
    }

    private static func decodedByteCost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(
                by: cgImage.height
            )
            return overflow ? .max : cost
        }
        let width = ceil(image.size.width * image.scale)
        let height = ceil(image.size.height * image.scale)
        let estimate = width * height * 4
        return estimate >= Double(Int.max) ? .max : Int(estimate)
    }
}

private enum MermaidRenderError: Error {
    case missingResources
    case invalidResponse
    case invalidDiagram
    case diagramTooTall
}

/// Serialized because Mermaid owns document-global configuration and renders
/// into one shared DOM node.
@MainActor
private final class MermaidRenderer: NSObject, WKNavigationDelegate {
    private static let maximumSourceBytes = 50_000
    private static let maximumHeight: CGFloat = 2_400

    private let webView: WKWebView
    private var rendererURL: URL?
    private var loaded = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
    }

    func render(
        source: String,
        width: Int,
        appearance: MermaidStore.Appearance
    ) async throws -> UIImage {
        guard source.utf8.count <= Self.maximumSourceBytes else {
            throw MermaidRenderError.invalidDiagram
        }
        await acquire()
        defer { release() }
        try await loadPage()

        let renderWidth = CGFloat(max(1, width))
        try attachToActiveWindowIfNeeded()
        webView.frame = CGRect(x: -10_000, y: 0, width: renderWidth, height: 1)
        let response = try await webView.callAsyncJavaScript(
            "return await window.renderMermaid(source, appearance);",
            arguments: ["source": source, "appearance": appearance.rawValue],
            in: nil,
            contentWorld: .page
        )
        guard let values = response as? [String: Any],
            let height = values["height"] as? NSNumber
        else {
            throw MermaidRenderError.invalidResponse
        }

        let renderHeight = ceil(CGFloat(truncating: height))
        guard renderHeight > 0, renderHeight <= Self.maximumHeight else {
            throw MermaidRenderError.diagramTooTall
        }
        webView.frame.size.height = renderHeight
        _ = try await webView.callAsyncJavaScript(
            "return await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        snapshot.snapshotWidth = NSNumber(value: Double(renderWidth))
        return try await webView.takeSnapshot(configuration: snapshot)
    }

    private func attachToActiveWindowIfNeeded() throws {
        guard webView.superview == nil else { return }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            throw MermaidRenderError.invalidResponse
        }
        // Mermaid measures SVG text while rendering. WKWebView does not finish
        // that work when detached from a view hierarchy on iOS 26.
        window.addSubview(webView)
    }

    private func loadPage() async throws {
        if loaded { return }
        guard let url = Bundle.main.url(
            forResource: "mermaid-renderer", withExtension: "html"
        ) else {
            throw MermaidRenderError.missingResources
        }
        rendererURL = url
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = navigationAction.request.url == rendererURL
        decisionHandler(allowed ? .allow : .cancel)
    }
}
