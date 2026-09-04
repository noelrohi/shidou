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
            if let renderError = error as? MermaidRenderError, renderError.isPermanent {
                insert(.failure, for: key)
            }
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

private enum MermaidRenderError: Error, Sendable {
    case missingResources
    case invalidResponse
    case invalidDiagram
    case diagramTooTall
    case timedOut

    var isPermanent: Bool {
        switch self {
        case .invalidDiagram, .diagramTooTall: true
        case .missingResources, .invalidResponse, .timedOut: false
        }
    }
}

/// Serialized because Mermaid owns document-global configuration and renders
/// into one shared DOM node.
@MainActor
private final class MermaidRenderer: NSObject, WKNavigationDelegate {
    private struct RenderedImage: @unchecked Sendable {
        let value: UIImage
    }

    private enum RenderAttempt: Sendable {
        case image(RenderedImage)
        case failure(MermaidRenderError)
    }

    private static let maximumSourceBytes = 50_000
    private static let maximumHeight: CGFloat = 2_400
    private static let loadTimeout: Duration = .seconds(20)
    private static let renderTimeout: Duration = .seconds(8)

    private var webView: WKWebView?
    private var hostWindow: UIWindow?
    private var rendererURL: URL?
    private var loaded = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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

        let webView = try hostedWebView()
        try await loadPage(in: webView)
        let renderWidth = CGFloat(max(1, width))
        resize(webView, to: CGSize(width: renderWidth, height: 1))

        let attempt: RenderAttempt? = await withTimeout(Self.renderTimeout) {
            await self.renderPage(
                webView,
                source: source,
                width: renderWidth,
                appearance: appearance
            )
        }
        guard let attempt else {
            retireWebView()
            throw MermaidRenderError.timedOut
        }
        switch attempt {
        case .image(let image):
            return image.value
        case .failure(let error):
            if !error.isPermanent { retireWebView() }
            throw error
        }
    }

    private func renderPage(
        _ webView: WKWebView,
        source: String,
        width: CGFloat,
        appearance: MermaidStore.Appearance
    ) async -> RenderAttempt {
        let response: Any?
        do {
            response = try await webView.callAsyncJavaScript(
                "return await window.renderMermaid(source, appearance);",
                arguments: ["source": source, "appearance": appearance.rawValue],
                in: nil,
                contentWorld: .page
            )
        } catch let error as WKError where error.code == .javaScriptExceptionOccurred {
            return .failure(.invalidDiagram)
        } catch {
            return .failure(.invalidResponse)
        }
        guard let values = response as? [String: Any],
            let height = values["height"] as? NSNumber
        else {
            return .failure(.invalidResponse)
        }

        let renderHeight = ceil(CGFloat(truncating: height))
        guard renderHeight > 0, renderHeight <= Self.maximumHeight else {
            return .failure(.diagramTooTall)
        }
        resize(webView, to: CGSize(width: width, height: renderHeight))
        do {
            _ = try await webView.callAsyncJavaScript(
                "return await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = CGRect(x: 0, y: 0, width: width, height: renderHeight)
            snapshot.snapshotWidth = NSNumber(value: Double(width))
            snapshot.afterScreenUpdates = true
            return .image(RenderedImage(value: try await webView.takeSnapshot(configuration: snapshot)))
        } catch {
            return .failure(.invalidResponse)
        }
    }

    private func hostedWebView() throws -> WKWebView {
        if let webView, webView.window != nil { return webView }
        retireWebView()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        else {
            throw MermaidRenderError.invalidResponse
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 1),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true

        // WebKit only finishes Mermaid's SVG measurement and rasterization in
        // a window. This covered window keeps the renderer hosted without
        // putting a web view in every transcript row.
        let window = UIWindow(windowScene: scene)
        window.frame = webView.frame
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        window.addSubview(webView)
        window.isHidden = false
        hostWindow = window
        self.webView = webView
        return webView
    }

    private func resize(_ webView: WKWebView, to size: CGSize) {
        hostWindow?.frame = CGRect(origin: .zero, size: size)
        webView.frame = CGRect(origin: .zero, size: size)
        webView.layoutIfNeeded()
        webView.scrollView.contentOffset = .zero
    }

    private func loadPage(in webView: WKWebView) async throws {
        if loaded { return }
        guard let url = Bundle.main.url(
            forResource: "mermaid-renderer", withExtension: "html"
        ) else {
            throw MermaidRenderError.missingResources
        }
        rendererURL = url
        let didLoad: Bool? = await withTimeout(Self.loadTimeout) {
            do {
                try await withCheckedThrowingContinuation { continuation in
                    self.loadContinuation = continuation
                    webView.loadFileURL(
                        url,
                        allowingReadAccessTo: url.deletingLastPathComponent()
                    )
                }
                return true
            } catch {
                return false
            }
        }
        guard didLoad == true else {
            retireWebView()
            throw didLoad == nil ? MermaidRenderError.timedOut : MermaidRenderError.invalidResponse
        }
    }

    private func retireWebView() {
        let continuation = loadContinuation
        loadContinuation = nil
        loaded = false
        rendererURL = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        hostWindow?.isHidden = true
        webView = nil
        hostWindow = nil
        continuation?.resume(throwing: MermaidRenderError.invalidResponse)
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @MainActor () async -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: duration)
                once.resume(nil)
            }
            Task { @MainActor in
                if once.resume(await operation()) { deadline.cancel() }
            }
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
        guard self.webView === webView, webView.url == rendererURL else { return }
        loaded = true
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        retireWebView()
    }

    private func failLoad(_ webView: WKWebView, error: Error) {
        guard self.webView === webView else { return }
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = self.webView === webView
            && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url == rendererURL
            && !loaded
        decisionHandler(allowed ? .allow : .cancel)
    }

    private final class ResumeOnce<T: Sendable> {
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        @discardableResult
        func resume(_ value: T?) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: value)
            return true
        }
    }
}
