# Mermaid transcript rendering on iOS

Research date: 2026-09-04. Sources are official documentation, upstream source, and current app source at the linked revisions.

## Recommendation

Keep Mermaid rendering on iOS, but do not ship the current renderer without bounded failure recovery. The branch chose the right shape: one lazy, local `WKWebView` renders serially, transcript rows receive cached `UIImage`s, and source remains available. This avoids a web view per row and preserves offline use.

Before shipping, add a native timeout that discards and rebuilds a stuck web view, handle `webViewWebContentProcessDidTerminate`, and do not permanently cache transient WebKit failures as invalid diagrams. These are release blockers because one hung render currently holds the shared queue forever.

## What the primary sources establish

GitHub treats fenced Mermaid as normal Markdown content in issues, discussions, pull requests, wikis, and Markdown files. It also warns that Mermaid versions differ, so clients need an explicit version policy. [GitHub Docs](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)

Mermaid is a browser renderer, not a small parser with an interchangeable native drawing layer. Its API creates SVG in the DOM, diagram renderers measure geometry with APIs such as `getBBox()`, and then the API serializes and sanitizes the SVG. The official integration API is `mermaid.render(id, source)`. [usage docs](https://mermaid.js.org/config/usage.html#api-usage), [render source](https://github.com/mermaid-js/mermaid/blob/fe0e2375348eb23ddc85c71c721010b6db2478ea/packages/mermaid/src/mermaidAPI.ts#L477-L682), [`getBBox()` viewport sizing](https://github.com/mermaid-js/mermaid/blob/fe0e2375348eb23ddc85c71c721010b6db2478ea/packages/mermaid/src/rendering-util/setupViewPortForSVG.ts#L23-L35)

Mermaid's default `securityLevel: "strict"` encodes HTML labels, disables clicks, and sanitizes non-loose SVG output with DOMPurify. `sandbox` adds an iframe but Mermaid still labels it beta in the usage docs. Strict mode is a sensible base, not a complete resource limit. Published Mermaid advisories include both XSS and render-time denial of service. The latter matters even when the result becomes a bitmap. [security-level schema](https://github.com/mermaid-js/mermaid/blob/fe0e2375348eb23ddc85c71c721010b6db2478ea/packages/mermaid/src/schemas/config.schema.yaml#L305-L328), [sanitization source](https://github.com/mermaid-js/mermaid/blob/fe0e2375348eb23ddc85c71c721010b6db2478ea/packages/mermaid/src/mermaidAPI.ts#L637-L650), [Gantt infinite-loop advisory](https://github.com/mermaid-js/mermaid/security/advisories/GHSA-6m6c-36f7-fhxh), [architecture XSS advisory](https://github.com/mermaid-js/mermaid/security/advisories/GHSA-8gwm-58g9-j8pw)

The bundled Shidou version, 11.17.2, is the current upstream release inspected for this note and includes the fixes named by those advisories. Pinning is good, but the 3.57 MB uncompressed bundle becomes an owned dependency that needs scheduled updates and license review. Mermaid's bundle includes many dependencies. OpenClaw's build notes explicitly require auditing the source map, retained license comments, and separate dependency notices on every update. [Mermaid 11.17.2 release](https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4011.17.2), [Mermaid package dependencies](https://github.com/mermaid-js/mermaid/blob/fe0e2375348eb23ddc85c71c721010b6db2478ea/packages/mermaid/package.json), [OpenClaw maintenance notes](https://github.com/openclaw/openclaw/blob/a04977803d21cccb9fbfb277982014e16115fc1a/packages/mermaid-renderer/README.md)

## Does `WKWebView` have to be attached?

There is no documented Apple contract saying a `WKWebView` must belong to a UIKit view hierarchy for JavaScript SVG text measurement. Apple documents `takeSnapshot` as capturing the visible viewport, and `loadFileURL` grants read access to the chosen file or directory. Neither API states an attachment precondition. [Apple `takeSnapshot`](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot%28with%3Acompletionhandler%3A%29), [Apple `loadFileURL`](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl%28_%3Aallowingreadaccessto%3A%29)

Two different attachment questions are easy to conflate:

1. Mermaid must attach its temporary SVG to the page DOM before measurement. Its own `render` implementation appends the render container to `document.body`, then removes it after serialization. Shidou satisfies this inside its loaded page. [Mermaid render source](https://github.com/mermaid-js/mermaid/blob/fe0e2375348eb23ddc85c71c721010b6db2478ea/packages/mermaid/src/mermaidAPI.ts#L522-L566)
2. The containing `WKWebView` may need a UIKit window on some iOS/WebKit versions to paint or finish asynchronous rendering. This is observed behavior, not an API guarantee. WebKit's own snapshot pixel-correctness test hosts the web view in a `UIWindow`, while simpler error and size tests use detached views. [WebKit snapshot tests](https://github.com/WebKit/WebKit/blob/1bf94f1c0c462bef841fca9877c167bf4bc769b3/Tools/TestWebKitAPI/Tests/WebKit/WKWebView/WKWebViewSnapshot.mm#L264-L304)

Current apps also disagree, which confirms that attachment is a compatibility choice rather than a universal rule. OpenClaw snapshots a renderer it does not explicitly add to a view hierarchy. OpenSession creates a dedicated, noninteractive window and says this is required for reliable rasterization. NotesTakingiOS exposes an invisible renderer through `UIViewRepresentable`, so SwiftUI hosts it. [OpenClaw renderer](https://github.com/openclaw/openclaw/blob/a04977803d21cccb9fbfb277982014e16115fc1a/apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMermaidRenderer.swift), [OpenSession renderer and host window](https://github.com/tellahq/opensession/blob/4f22934d1f638c3e88e6f271a40d06c2f53ed2d6/packages/clients/ios/OS1/Mermaid/MermaidRenderer.swift#L239-L305), [NotesTakingiOS host](https://github.com/hwdavr/NotesTakingiOS/blob/22a958554058dd0f4f6d4fe5b0dba7660fbb99da/NotesTakingAppiOS/Views/Editor/Components/MermaidRendererHost.swift)

For Shidou, retain attachment because commit `97c4c26e` records a real iOS 26 hang when detached. Treat it as a tested WebKit workaround. A dedicated renderer window tied to the foreground scene is cleaner than adding a permanently retained view at `x = -10_000` to whichever app window happens to be found.

## Common app architecture

The current source sample has three patterns:

- OpenClaw and OpenSession use one shared renderer, serialize requests, snapshot to bitmap, cache results, and keep source as the failure fallback. Both bound work with timeouts and recover by replacing the web view. This is the closest match to Shidou. [OpenClaw renderer](https://github.com/openclaw/openclaw/blob/a04977803d21cccb9fbfb277982014e16115fc1a/apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatMermaidRenderer.swift), [OpenSession renderer](https://github.com/tellahq/opensession/blob/4f22934d1f638c3e88e6f271a40d06c2f53ed2d6/packages/clients/ios/OS1/Mermaid/MermaidRenderer.swift)
- cmux renders the complete Markdown document in one visible `WKWebView` and runs a bundled Mermaid library within that page. That fits document preview, but not Shidou's native, virtualized transcript rows. [cmux iOS Markdown view](https://github.com/manaflow-ai/cmux/blob/1db4b011ceef08e2ef48e35cb3c49a1e0df2fd4d/Packages/iOS/CmuxAgentChatUI/Sources/CmuxAgentChatUI/Markdown/MarkdownWebContentView.swift), [cmux shell](https://github.com/manaflow-ai/cmux/blob/1db4b011ceef08e2ef48e35cb3c49a1e0df2fd4d/Resources/markdown-viewer/shell.html)
- NotesTakingiOS renders through one hosted bridge, then displays returned SVG in a separate JavaScript-disabled web view. This keeps vector output and SVG semantics but introduces a web view per visible diagram. [renderer](https://github.com/hwdavr/NotesTakingiOS/blob/22a958554058dd0f4f6d4fe5b0dba7660fbb99da/NotesTakingAppiOS/Data/Mermaid/WKWebViewMermaidRenderer.swift), [SVG view](https://github.com/hwdavr/NotesTakingiOS/blob/22a958554058dd0f4f6d4fe5b0dba7660fbb99da/NotesTakingAppiOS/Views/Editor/Components/MermaidSVGView.swift)

No inspected app implements Mermaid grammar and layout natively. Reimplementing Mermaid in Swift would inherit many diagram grammars and layout engines, then drift from GitHub and Shidou's other clients. A remote renderer would reduce app size but lose offline use and send transcript content to another service.

## Review of this branch

`apps/ios/Shidou/Sources/MermaidRenderer.swift` gets the main decisions right:

- One lazily created renderer and no web view in transcript rows.
- Serial rendering around Mermaid's document-global state.
- Local files, a nonpersistent data store, a strict CSP with networking disabled, blocked navigation, `securityLevel: "strict"`, untrusted source passed as a JavaScript argument, and disabled popup creation.
- Source and height limits, an edge limit, decoded-byte cache accounting, failure fallback, and an accessibility-hidden private renderer.
- Offline operation. Apple says a nonpersistent store keeps website data in memory and writes none to disk. [Apple `nonPersistent()`](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent%28%29)

The remaining gaps are concrete:

1. `callAsyncJavaScript` and `takeSnapshot` have no timeout. A render-time infinite loop or dead content process can hold `busy` forever. Add a native deadline, tear down the web view on timeout, and resume the queue. A page timer cannot interrupt synchronous JavaScript. OpenClaw and OpenSession both use native deadlines and process-termination recovery.
2. Every error is cached as `.failure`. A missing window, interrupted navigation, snapshot error, or terminated WebKit process then becomes a permanent invalid-diagram result for that key. Cache syntax and size failures only. Retry transient platform failures.
3. The renderer has no `webViewWebContentProcessDidTerminate` recovery and keeps `loaded = true` after process loss.
4. The cache is FIFO, not LRU, because hits do not refresh `order`. This is acceptable at 24 entries but differs from the apparent intent.
5. The displayed bitmap has only the generic label "Mermaid diagram". Mermaid emits `aria-roledescription` and supports `accTitle` and `accDescr` for every diagram type, but rasterization discards those semantics. Return the SVG title and description from JavaScript and use them as the SwiftUI accessibility label and value. Keep the source disclosure as the fallback. [Mermaid accessibility docs](https://mermaid.js.org/config/accessibility.html)
6. Maintenance needs an explicit update check and exact bundled-license audit. `Mermaid-LICENSE.txt` covers Mermaid itself, while the classic browser bundle contains separately licensed dependencies.

## Decision

Keep the feature. The implementation cost is justified because Mermaid fences are established transcript content, the renderer is fully local, and its bitmap boundary suits a long native transcript. The branch is close, but timeout, process recovery, and transient-error handling should land before the iOS Delivery Channel ships it. Accessibility metadata and dependency-notice automation should follow in the same change if practical.
