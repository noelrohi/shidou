import Foundation
import Observation
import ShidouProtocol

/// The read-only surfaces for one workspace directory: its file tree, the file
/// currently being read, the review diff, and the image gallery.
///
/// It lives beside the session store rather than inside a view for the same
/// reason the store does — a tree fetch outlives the sheet that started it,
/// and an iPad inspector and an iPhone sheet are two presentations of one
/// state. Everything here is fetched in the background and read from memory;
/// a miss means "not known yet" and every surface degrades to a placeholder
/// rather than blocking.
@MainActor
@Observable
public final class WorkspaceSurfaces {
    /// The one file the reader is showing, with whatever is known about it.
    public struct OpenFile: Sendable, Equatable {
        public var relativePath: WorkspaceRelativePath
        public var content: String?
        public var error: String?
        /// The line a transcript link asked for, so the reader can scroll to it.
        public var focusLine: Int?

        public var name: String { relativePath.name }
    }

    public let cwd: String

    // MARK: Files

    public private(set) var tree: [WorkingTreeEntry] = []
    public private(set) var expanded: Set<String> = []
    public private(set) var isLoadingTree = false
    public private(set) var treeError: String?
    public private(set) var hasLoadedTree = false

    public private(set) var openFile: OpenFile?
    public private(set) var isLoadingFile = false

    // MARK: Changes

    public private(set) var diffSource: ReviewDiffSource = .uncommitted
    public private(set) var diffFiles: [UnifiedDiff.File] = []
    /// The daemon could not include full context for the patch — usually a
    /// file too large to inline. Worth saying, because the diff on screen is
    /// then not the whole change.
    public private(set) var diffIsComplete = true
    public private(set) var isLoadingDiff = false
    public private(set) var diffError: String?
    public private(set) var hasLoadedDiff = false

    // MARK: Visuals

    public private(set) var images: [FileEntry] = []
    public private(set) var isLoadingImages = false
    public private(set) var imagesError: String?
    public private(set) var hasLoadedImages = false

    // MARK: Wiring

    /// Which surface a generation counter belongs to. One counter per surface
    /// is what makes a superseded pass harmless: a stale answer cannot commit
    /// over a newer one.
    private enum LoadKind: String {
        case tree, file, diff, images
    }

    @ObservationIgnored private let request: @MainActor (Command) async throws -> ResponsePayload
    @ObservationIgnored private var generations: [LoadKind: Int] = [:]
    /// Decoded image bytes, keyed by workspace-relative path. Observed on
    /// purpose: this is the one cache here whose contents a view reads
    /// directly, so a write has to invalidate — otherwise a thumbnail waits
    /// forever for a redraw nobody promised it. Bounded because a gallery of
    /// full-resolution screenshots is the one surface that can outgrow a phone.
    private var imageData: [String: Data] = [:]
    @ObservationIgnored private var imageOrder: [String] = []
    @ObservationIgnored private var imageLoads: Set<WorkspaceRelativePath> = []

    /// The largest patch this will hold in memory. The parse itself runs off
    /// the main actor, so this is a memory bound rather than a frame one: past
    /// it the diff is reported as too large rather than spending a phone's
    /// working set on a change nobody can read anyway.
    static let maxPatchBytes = 4 * 1024 * 1024
    static let maxCachedImages = 24
    /// The cap `listProjectFiles` is asked for, matching the web gallery's.
    static let visualGalleryCap = 50_000

    public init(
        cwd: String,
        request: @escaping @MainActor (Command) async throws -> ResponsePayload
    ) {
        self.cwd = cwd
        self.request = request
    }

    // MARK: - Loading

    /// Kills any in-flight load for a surface without starting a new one.
    private func invalidate(_ kind: LoadKind) {
        let generation = (generations[kind] ?? 0) &+ 1
        generations[kind] = generation
    }

    /// The one loader shape every surface shares: bump the generation, mark
    /// loading, fetch, and let only the still-current pass commit. The
    /// variation between surfaces is the command, the payload case, and where
    /// the result lands — each of which the caller names.
    private func fetch<T: Sendable>(
        _ kind: LoadKind,
        isLoading: ReferenceWritableKeyPath<WorkspaceSurfaces, Bool>,
        command: @autoclosure @escaping () -> Command,
        decode: @escaping @MainActor (ResponsePayload) async throws -> T,
        commit: @escaping @MainActor (T) -> Void,
        fail: @escaping @MainActor (Error) -> Void
    ) {
        invalidate(kind)
        let generation = generations[kind] ?? 0
        self[keyPath: isLoading] = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.request(command())
                guard self.generations[kind] == generation else { return }
                let value = try await decode(payload)
                // The awaits let a newer load win, so the guard is rechecked
                // after every one — the detached parse inside a diff decode is
                // exactly where that window is widest.
                guard self.generations[kind] == generation else { return }
                commit(value)
            } catch {
                guard self.generations[kind] == generation else { return }
                fail(error)
            }
            self[keyPath: isLoading] = false
        }
    }

    // MARK: - Files

    public func loadTree(force: Bool = false) {
        guard force || (!hasLoadedTree && !isLoadingTree) else { return }
        let expandedPaths = expanded.sorted()
        fetch(
            .tree,
            isLoading: \.isLoadingTree,
            command: .workspace(.listTree(root: self.cwd, expandedPaths: expandedPaths)),
            decode: { payload in
                guard case .workspace(.workingTree(let entries)) = payload else {
                    throw ShidouSessionError.unexpectedResponse(expected: "workingTree")
                }
                return entries
            },
            commit: { entries in
                self.tree = entries
                self.treeError = nil
                self.hasLoadedTree = true
            },
            fail: { self.treeError = $0.localizedDescription }
        )
    }

    /// Expanding a directory is a re-list, because the daemon owns which
    /// children exist — the phone never walks a filesystem it cannot see.
    public func toggle(_ entry: WorkingTreeEntry) {
        guard entry.isDir else { return }
        if expanded.contains(entry.absolutePath) {
            expanded.remove(entry.absolutePath)
        } else {
            expanded.insert(entry.absolutePath)
        }
        loadTree(force: true)
    }

    public func isExpanded(_ entry: WorkingTreeEntry) -> Bool {
        expanded.contains(entry.absolutePath)
    }

    /// Open one file for reading. `focusLine` comes from a transcript link and
    /// is only a scroll target — nothing here can edit.
    public func openFile(_ path: WorkspaceRelativePath, focusLine: Int? = nil) {
        openFile = OpenFile(relativePath: path, focusLine: focusLine)
        fetch(
            .file,
            isLoading: \.isLoadingFile,
            command: .workspace(.readTextFile(root: self.cwd, relativePath: path.rawValue)),
            decode: { payload in
                guard case .workspace(.textFile(let content)) = payload else {
                    throw ShidouSessionError.unexpectedResponse(expected: "textFile")
                }
                return content
            },
            commit: { self.openFile?.content = $0 },
            fail: { self.openFile?.error = $0.localizedDescription }
        )
    }

    public func closeFile() {
        invalidate(.file)
        openFile = nil
        isLoadingFile = false
    }

    // MARK: - Changes

    public func selectDiffSource(_ source: ReviewDiffSource) {
        guard source != diffSource else { return }
        diffSource = source
        hasLoadedDiff = false
        loadDiff(force: true)
    }

    /// What a review-diff response decodes into, before it lands on the model.
    private struct DecodedDiff: Sendable {
        var files: [UnifiedDiff.File]
        var completeContext: Bool
    }

    public func loadDiff(force: Bool = false) {
        guard force || (!hasLoadedDiff && !isLoadingDiff) else { return }
        let source = diffSource
        fetch(
            .diff,
            isLoading: \.isLoadingDiff,
            command: .workspace(.collectReviewDiff(cwd: self.cwd, source: source)),
            decode: { payload -> DecodedDiff in
                guard case .workspace(.reviewDiff(let data)) = payload else {
                    throw ShidouSessionError.unexpectedResponse(expected: "reviewDiff")
                }
                guard data.patch.utf8.count <= Self.maxPatchBytes else {
                    throw ShidouSessionError.patchTooLarge
                }
                // Parsing a megabyte of patch is several frames of work, so it
                // never runs on the actor that renders. The generation is
                // rechecked afterwards because the await lets a newer load win.
                let patch = data.patch
                let files = await Task.detached(priority: .userInitiated) {
                    UnifiedDiff.parse(patch)
                }.value
                return DecodedDiff(files: files, completeContext: data.completeContext)
            },
            commit: { diff in
                self.diffFiles = diff.files
                self.diffIsComplete = diff.completeContext
                self.diffError = nil
                self.hasLoadedDiff = true
            },
            fail: { error in
                self.diffFiles = []
                self.diffError = error.localizedDescription
            }
        )
    }

    public var diffAdditions: Int { UnifiedDiff.additions(diffFiles) }
    public var diffDeletions: Int { UnifiedDiff.deletions(diffFiles) }

    // MARK: - Visuals

    public func loadImages(force: Bool = false) {
        guard force || (!hasLoadedImages && !isLoadingImages) else { return }
        fetch(
            .images,
            isLoading: \.isLoadingImages,
            command: .workspace(.listProjectFiles(root: self.cwd, cap: Self.visualGalleryCap)),
            decode: { payload in
                guard case .workspace(.projectFiles(let entries)) = payload else {
                    throw ShidouSessionError.unexpectedResponse(expected: "projectFiles")
                }
                return entries
            },
            commit: { entries in
                self.images = VisualsPresentation.images(in: entries)
                self.imagesError = nil
                self.hasLoadedImages = true
            },
            fail: { self.imagesError = $0.localizedDescription }
        )
    }

    public func imageBytes(for path: WorkspaceRelativePath) -> Data? {
        imageData[path.rawValue]
    }

    /// Fetch one image's bytes, once. Lazy per image on purpose: a gallery is
    /// the one surface where loading everything up front would cost more than
    /// the phone has, and the grid only ever shows a screenful.
    public func loadImage(_ path: WorkspaceRelativePath) {
        guard imageData[path.rawValue] == nil, imageLoads.insert(path).inserted else {
            return
        }
        // The one place a workspace-relative path becomes a daemon path; the
        // types keep every other call site from doing this by hand.
        let absolute = VisualsPresentation.workspacePath(root: cwd, relativePath: path)
        Task { [weak self] in
            guard let self else { return }
            defer { self.imageLoads.remove(path) }
            guard case .attachmentStored(let attachment) =
                try? await self.request(.importPathAttachment(path: absolute))
            else { return }
            guard case .blobData(let bytes) = try? await self.request(
                .readAttachment(reference: attachment.reference, path: attachment.path))
            else { return }
            self.cacheImage(bytes, for: path)
        }
    }

    private func cacheImage(_ bytes: Data, for path: WorkspaceRelativePath) {
        if imageData[path.rawValue] == nil { imageOrder.append(path.rawValue) }
        imageData[path.rawValue] = bytes
        while imageOrder.count > Self.maxCachedImages {
            imageData.removeValue(forKey: imageOrder.removeFirst())
        }
    }
}
