import ShidouProtocol
import ShidouSession
import SwiftUI

/// The workspace's images, grouped by folder.
///
/// The desktop's justified masonry and its folder picker are not ported: one
/// narrow column has nothing to justify, and a picker would be a control for
/// choosing between sections that already fit on the same screen. Bytes load
/// per image, lazily — a gallery is the one surface where fetching everything
/// up front costs more than the phone has.
struct VisualsView: View {
    let surfaces: WorkspaceSurfaces

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8, pinnedViews: .sectionHeaders) {
                ForEach(VisualsPresentation.sections(surfaces.images)) { section in
                    Section {
                        ForEach(section.images) { image in
                            let path = WorkspaceRelativePath(image.path)
                            NavigationLink(value: SurfaceRoute.visual(path: path)) {
                                VisualThumbnail(surfaces: surfaces, path: path)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        SectionHeader(title: section.title, count: section.images.count)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .surfaceState(
            isEmpty: surfaces.images.isEmpty,
            isLoading: surfaces.isLoadingImages,
            error: surfaces.imagesError,
            hasLoaded: surfaces.hasLoadedImages,
            retry: { surfaces.loadImages(force: true) },
            failureTitle: "Could not list the workspace",
            failureIcon: "photo.badge.exclamationmark"
        ) {
            ContentUnavailableView(
                "No images", systemImage: "photo",
                description: Text("This workspace has no pictures in it."))
        }
        .navigationTitle("Visuals")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { surfaces.loadImages(force: true) }
        .task { surfaces.loadImages() }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Text(verbatim: "\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) image in \(title)")
    }
}

private struct VisualThumbnail: View {
    let surfaces: WorkspaceSurfaces
    let path: WorkspaceRelativePath

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
            if let image = surfaces.imageBytes(for: path).flatMap(UIImage.init(data:)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) {
            Text(verbatim: path.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // The grid is lazy, so this runs when the cell first comes on screen —
        // which is exactly when the bytes are worth fetching.
        .task { surfaces.loadImage(path) }
        .accessibilityLabel(path.rawValue)
    }
}

/// One image, full width, zoomable. Read-only like everything else here.
struct VisualDetailView: View {
    let surfaces: WorkspaceSurfaces
    let path: WorkspaceRelativePath

    @State private var scale: CGFloat = 1

    var body: some View {
        Group {
            if let image = surfaces.imageBytes(for: path).flatMap(UIImage.init(data:)) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .frame(maxWidth: .infinity)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, min(6, $0.magnification)) }
                        )
                        .accessibilityLabel(path.rawValue)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(path.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Pinching is the only way to zoom with a finger, so the same
            // range needs keys behind it: a gesture no keyboard can perform is
            // a control only some of the room can reach.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        zoom(by: 1.25)
                    } label: {
                        Label("Zoom in", systemImage: "plus.magnifyingglass")
                    }
                    .keyboardShortcut("+", modifiers: .command)
                    Button {
                        zoom(by: 0.8)
                    } label: {
                        Label("Zoom out", systemImage: "minus.magnifyingglass")
                    }
                    .keyboardShortcut("-", modifiers: .command)
                    Button {
                        scale = 1
                    } label: {
                        Label("Reset zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .disabled(scale == 1)
                    .keyboardShortcut("0", modifiers: .command)
                } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .accessibilityLabel("Zoom")
            }
        }
        .task { surfaces.loadImage(path) }
    }

    /// The same 1–6 range the pinch clamps to, so a key and a finger cannot
    /// leave the image at two different limits.
    private func zoom(by factor: CGFloat) {
        scale = max(1, min(6, scale * factor))
    }
}
