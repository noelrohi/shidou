import XCTest
@testable import Shidou

@MainActor
final class MermaidRendererTests: XCTestCase {
    func testBundledFlowchartFinishesRendering() async {
        let store = MermaidStore()
        let finished = expectation(description: "Mermaid render finishes")
        var result: Result<UIImage, Error>?

        let render = Task { @MainActor in
            do {
                result = .success(
                    try await store.image(
                        source: """
                        flowchart LR
                            A[User prompt] --> B[Shidou]
                            B --> C{Need tools?}
                            C -->|Yes| D[Run tools]
                            D --> B
                            C -->|No| E[Final answer]
                        """,
                        width: 320,
                        appearance: .dark
                    )
                )
            } catch {
                result = .failure(error)
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 8)
        render.cancel()

        switch result {
        case .success(let image):
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        case .failure(let error):
            XCTFail("Mermaid render failed: \(error)")
        case nil:
            XCTFail("Mermaid render remained loading")
        }
    }
}
