import ShidouProtocol
import ShidouSession
import SwiftUI

/// Where the Surfaces Sheet is pointing.
///
/// The desktop's right panel carries a dynamic set of open tabs; the IA
/// decision dropped that for a fixed four-section sheet, so this is a plain
/// navigation path rather than a tab model. Each section pushes its own
/// detail, which is what makes a transcript link able to open the sheet
/// *already* at a file.
enum SurfaceRoute: Hashable {
    case files
    case file(path: WorkspaceRelativePath, line: Int?)
    case changes
    case change(index: Int)
    case visuals
    case visual(path: WorkspaceRelativePath)
    case backgroundWork
    case work(key: BackgroundWorkKey)
}

/// The four read-only surfaces, in their own navigation stack.
///
/// One view serves both presentations: an iPhone shows it in a sheet, an iPad
/// shows it in `.inspector()`. Nothing here knows which — the caller owns the
/// container, this owns the content.
struct SurfacesView: View {
    let session: AgentSession
    let model: SessionRuntimeModel
    let store: SessionStore
    @Binding var path: [SurfaceRoute]

    private var surfaces: WorkspaceSurfaces? { store.surfaces(for: session) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let surfaces {
                    root(surfaces)
                } else {
                    ContentUnavailableView(
                        "No workspace",
                        systemImage: "folder.badge.questionmark",
                        description: Text("This task has no project directory to read.")
                    )
                }
            }
            .navigationTitle("Panel")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SurfaceRoute.self) { route in
                destination(route)
            }
        }
    }

    private func root(_ surfaces: WorkspaceSurfaces) -> some View {
        List {
            Section {
                NavigationLink(value: SurfaceRoute.files) {
                    Label("Files", systemImage: "folder")
                }
                NavigationLink(value: SurfaceRoute.changes) {
                    LabeledContent {
                        if let snapshot = store.workspace(for: session),
                            snapshot.additions > 0 || snapshot.deletions > 0
                        {
                            Text(verbatim: "+\(snapshot.additions) −\(snapshot.deletions)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Changes", systemImage: "plusminus")
                    }
                }
                NavigationLink(value: SurfaceRoute.visuals) {
                    Label("Visuals", systemImage: "photo.on.rectangle")
                }
                NavigationLink(value: SurfaceRoute.backgroundWork) {
                    LabeledContent {
                        if model.backgroundWork.liveCount > 0 {
                            Text("^[\(model.backgroundWork.liveCount) running](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Background Work", systemImage: "gearshape.2")
                    }
                }
            } footer: {
                Text(verbatim: surfaces.cwd)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func destination(_ route: SurfaceRoute) -> some View {
        if let surfaces {
            switch route {
            case .files:
                FileTreeView(surfaces: surfaces)
            case .file(let path, let line):
                FileReaderView(surfaces: surfaces, path: path, line: line)
            case .changes:
                ChangesView(surfaces: surfaces, session: session, store: store)
            case .change(let index):
                DiffFileView(surfaces: surfaces, index: index)
            case .visuals:
                VisualsView(surfaces: surfaces)
            case .visual(let path):
                VisualDetailView(surfaces: surfaces, path: path)
            case .backgroundWork:
                BackgroundWorkView(session: session, model: model, store: store)
            case .work(let key):
                BackgroundWorkDetailView(session: session, model: model, store: store, key: key)
            }
        }
    }
}

extension SurfaceRoute {
    /// The path that opens the sheet already at a transcript link's target.
    /// A file outside the workspace has no route here: the surfaces read one
    /// workspace, and the daemon host's wider filesystem is not one of them.
    static func path(for route: TranscriptLinkRoute) -> [SurfaceRoute]? {
        guard case .projectFile(let path, let line) = route else { return nil }
        return [.files, .file(path: WorkspaceRelativePath(path), line: line)]
    }
}
