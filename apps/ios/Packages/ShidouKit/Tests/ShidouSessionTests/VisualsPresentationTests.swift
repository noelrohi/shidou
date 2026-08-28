import ShidouProtocol
import XCTest

@testable import ShidouSession

final class VisualsPresentationTests: XCTestCase {
    private func entries(_ paths: [String], dirs: [String] = []) -> [FileEntry] {
        paths.map { FileEntry(path: $0, isDir: false) }
            + dirs.map { FileEntry(path: $0, isDir: true) }
    }

    func testKeepsOnlyTheSharedImageExtensions() {
        let listed = entries([
            "assets/logo.PNG", "assets/photo.jpeg", "docs/diagram.svg", "src/main.rs",
            "assets/icon.webp", "assets/old.bmp", "README",
        ], dirs: ["assets"])
        XCTAssertEqual(
            VisualsPresentation.images(in: listed).map(\.path),
            ["assets/icon.webp", "assets/logo.PNG", "assets/photo.jpeg", "docs/diagram.svg"]
        )
    }

    /// A dot in a directory name is not a file extension, and a directory
    /// entry is never a picture however it is named.
    func testDirectoriesAndDottedFoldersAreNotImages() {
        XCTAssertFalse(VisualsPresentation.isSupported(path: "v1.2/notes"))
        XCTAssertTrue(VisualsPresentation.isSupported(path: "v1.2/shot.png"))
        XCTAssertTrue(
            VisualsPresentation.images(in: entries([], dirs: ["assets/png"])).isEmpty)
    }

    func testSectionsGroupByFolderInPathOrder() {
        let images = VisualsPresentation.images(in: entries([
            "b/two.png", "a/one.png", "root.png", "a/three.png",
        ]))
        let sections = VisualsPresentation.sections(images)
        XCTAssertEqual(sections.map(\.folder), ["", "a", "b"])
        XCTAssertEqual(sections[0].title, ".", "the workspace root has no name of its own")
        XCTAssertEqual(sections[1].images.map(\.path), ["a/one.png", "a/three.png"])
    }

    func testWorkspacePathJoinsWithTheRootsOwnSeparator() {
        XCTAssertEqual(
            VisualsPresentation.workspacePath(root: "/src/shidou/", relativePath: "/assets/a.png"),
            "/src/shidou/assets/a.png"
        )
        XCTAssertEqual(
            VisualsPresentation.workspacePath(root: #"C:\src\shidou"#, relativePath: "a.png"),
            #"C:\src\shidou\a.png"#
        )
    }
}
