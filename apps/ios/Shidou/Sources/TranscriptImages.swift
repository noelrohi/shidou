import ShidouProtocol
import ShidouSession
import SwiftUI
import UIKit

/// Every image the transcript can show, and the one place that fetches them.
///
/// A transcript image arrives as one of four things: a `data:` URL the model
/// inlined, a remote URL, a blob the daemon already holds, or a path on the
/// daemon host. They resolve differently and render identically, so the
/// difference stops here.
enum TranscriptImageSource: Hashable, Sendable {
    case inline(String)
    case remote(URL)
    /// A provider blob or attachment reference.
    case reference(String)
    /// A message attachment, which knows both its reference and its path.
    case attachment(MessageAttachment)
    /// An absolute path on the daemon host.
    case daemonPath(String)

    /// Classify a markdown `src` or a provider image reference.
    ///
    /// `workspaceCwd` is what makes a relative path resolvable: a model writes
    /// `![](docs/shot.png)` meaning the repository it is working in, and the
    /// phone has no such directory of its own.
    init?(_ raw: String, workspaceCwd: String?) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("data:") {
            self = .inline(value)
        } else if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard let url = URL(string: value) else { return nil }
            self = .remote(url)
        } else if value.hasPrefix("file://") {
            guard let url = URL(string: value) else { return nil }
            self = .daemonPath(url.path)
        } else if value.hasPrefix(AttachmentLimits.blobScheme) {
            self = .reference(value)
        } else if value.hasPrefix("/") {
            self = .daemonPath(value)
        } else if let workspaceCwd, !workspaceCwd.isEmpty {
            let root = workspaceCwd.hasSuffix("/")
                ? String(workspaceCwd.dropLast()) : workspaceCwd
            self = .daemonPath("\(root)/\(value)")
        } else {
            // Nothing here can be resolved to bytes; the alt text is what the
            // transcript can honestly show.
            return nil
        }
    }

    /// A provider's `image_urls` entry, which is a data URL, a remote URL, or
    /// a reference the daemon can read back.
    static func activityOutput(_ raw: String) -> TranscriptImageSource? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("data:") { return .inline(value) }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value).map { .remote($0) }
        }
        if value.hasPrefix("/") { return .daemonPath(value) }
        return .reference(value)
    }
}

/// Decoded transcript images, kept for as long as the transcript is on screen.
///
/// Decoded, not encoded: turning bytes into a `UIImage` costs milliseconds,
/// and a row builder runs for every visible row of every frame. What render
/// reads is the finished image or nothing at all, and nothing at all means
/// "not known yet" — never "no image".
@MainActor
@Observable
final class TranscriptImageStore {
    private var images: [TranscriptImageSource: UIImage] = [:]
    @ObservationIgnored private var loads: Set<TranscriptImageSource> = []
    /// Sources that resolved to nothing. Kept so a broken reference is tried
    /// once rather than once per appearance.
    @ObservationIgnored private var failures: Set<TranscriptImageSource> = []

    func image(for source: TranscriptImageSource) -> UIImage? { images[source] }

    func hasFailed(_ source: TranscriptImageSource) -> Bool { failures.contains(source) }

    func load(_ source: TranscriptImageSource, using store: SessionStore) {
        guard images[source] == nil, !failures.contains(source) else { return }
        guard loads.insert(source).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.loads.remove(source) }
            let data = await Self.bytes(for: source, using: store)
            // Decoding is the expensive half, and it has no business on the
            // thread that is drawing the transcript.
            guard let data, let image = await Self.decode(data) else {
                self.failures.insert(source)
                return
            }
            self.images[source] = image
        }
    }

    private static func bytes(
        for source: TranscriptImageSource,
        using store: SessionStore
    ) async -> Data? {
        switch source {
        case .inline(let value):
            guard let comma = value.firstIndex(of: ",") else { return nil }
            let encoded = String(value[value.index(after: comma)...])
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        case .remote(let url):
            return try? await URLSession.shared.data(from: url).0
        case .reference(let reference):
            return try? await store.imageData(reference: reference)
        case .attachment(let attachment):
            return try? await store.attachmentData(attachment)
        case .daemonPath(let path):
            return try? await store.imageData(daemonPath: path)
        }
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
    }
}

/// What a markdown image needs to become bytes, carried in the environment so
/// the recursive block views do not each have to forward it.
struct TranscriptImageContext {
    var images: TranscriptImageStore?
    var store: SessionStore?
    var workspaceCwd: String?
}

private struct TranscriptImageContextKey: EnvironmentKey {
    static let defaultValue = TranscriptImageContext()
}

extension EnvironmentValues {
    var transcriptImages: TranscriptImageContext {
        get { self[TranscriptImageContextKey.self] }
        set { self[TranscriptImageContextKey.self] = newValue }
    }
}

/// A markdown image, resolved against whatever workspace the transcript is
/// reading. Rendered separately from `TranscriptImageView` only because it
/// takes its dependencies from the environment rather than its call site.
struct MarkdownImageView: View {
    let source: String?
    let alt: String

    @Environment(\.transcriptImages) private var context

    @ViewBuilder
    var body: some View {
        if let images = context.images {
            TranscriptImageView(
                source: source.flatMap {
                    TranscriptImageSource($0, workspaceCwd: context.workspaceCwd)
                },
                alt: alt,
                images: images,
                store: context.store
            )
        } else {
            // Markdown rendered outside a transcript — a composer preview —
            // has nowhere to fetch from, and says so with the alt text.
            Label(alt.isEmpty ? "Image" : alt, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// One image in the transcript: a tappable thumbnail that opens full screen,
/// and an honest placeholder until the bytes land.
struct TranscriptImageView: View {
    let source: TranscriptImageSource?
    let alt: String
    var maxHeight: CGFloat = 220
    let images: TranscriptImageStore
    let store: SessionStore?

    @State private var showingPreview = false

    var body: some View {
        Group {
            if let source, let image = images.image(for: source) {
                Button { showingPreview = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: maxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                .accessibilityHint("Opens the image full screen")
                .fullScreenCover(isPresented: $showingPreview) {
                    TranscriptImagePreview(image: image, title: alt)
                }
            } else {
                placeholder
            }
        }
        .task(id: source) {
            guard let source, let store else { return }
            images.load(source, using: store)
        }
    }

    private var placeholder: some View {
        Label(label, systemImage: source == nil ? "photo" : "photo.badge.arrow.down")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        if !alt.isEmpty { return alt }
        guard let source, images.hasFailed(source) else { return "Image" }
        return "Image unavailable"
    }
}

/// The full-screen image, zoomable and dismissable.
private struct TranscriptImagePreview: View {
    let image: UIImage
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black.opacity(0.92))
            .navigationTitle(title.isEmpty ? "Image" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(
                        title.isEmpty ? "Image" : title, image: Image(uiImage: image)
                    ))
                }
            }
        }
    }
}

/// A message's attachments, as the tiles the web transcript shows above the
/// bubble. Images resolve to thumbnails; anything else states its name.
struct MessageAttachmentsRow: View {
    let attachments: [MessageAttachment]
    let images: TranscriptImageStore
    let store: SessionStore?

    var body: some View {
        if !attachments.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)],
                alignment: .trailing,
                spacing: 8
            ) {
                ForEach(attachments, id: \.self) { attachment in
                    if attachment.isImage, attachment.blobReference != nil {
                        TranscriptImageView(
                            source: .attachment(attachment),
                            alt: attachment.name,
                            maxHeight: 96,
                            images: images,
                            store: store
                        )
                    } else {
                        Label(attachment.name, systemImage: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
