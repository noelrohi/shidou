---
name: swiftui-expert-skill
description: Write, review, or refactor SwiftUI code; record or analyze Instruments traces for Apple apps.
---

# SwiftUI

Use the references relevant to the change, not the whole index.

- Prefer native SwiftUI APIs; bridge to UIKit/AppKit when needed.
- Follow the project's data-flow conventions without imposing an architecture.
- Performance is a Shidou product requirement. Measure suspected bottlenecks
  and fix those within the requested scope.
- Adopt Liquid Glass only when explicitly requested.
- Check deployment targets before using version-specific APIs. Consult the API
  migration references when choosing a replacement or handling a deprecation,
  not as a prerequisite to unrelated edits.

## Instruments

- Recording: read [trace-recording.md](references/trace-recording.md), then use
  `scripts/record_trace.py`. Confirm the target device kind; the SwiftUI lane is
  empty on iOS Simulator, so use Time Profiler there. System-wide recording
  requires explicit consent.
- Analysis: read [trace-analysis.md](references/trace-analysis.md), then use
  `scripts/analyze_trace.py`. Resolve a user-requested time window before
  analyzing. Cite trace evidence and investigate who invalidates expensive
  views. A source file is optional. Edit code only if the request includes it.

Resolve script paths relative to this skill directory.

## Topic references

| Topic | Reference |
| --- | --- |
| State ownership, bindings, Observation | [state-management.md](references/state-management.md) |
| View composition | [view-structure.md](references/view-structure.md) |
| Invalidation and hot paths | [performance-patterns.md](references/performance-patterns.md) |
| Lists and ForEach identity | [list-patterns.md](references/list-patterns.md) |
| Layout | [layout-best-practices.md](references/layout-best-practices.md) |
| Sheets and navigation | [sheet-navigation-patterns.md](references/sheet-navigation-patterns.md) |
| Scroll position and geometry | [scroll-patterns.md](references/scroll-patterns.md) |
| Keyboard focus | [focus-patterns.md](references/focus-patterns.md) |
| Animation basics | [animation-basics.md](references/animation-basics.md) |
| Transitions | [animation-transitions.md](references/animation-transitions.md) |
| Phase and keyframe animation | [animation-advanced.md](references/animation-advanced.md) |
| Accessibility | [accessibility-patterns.md](references/accessibility-patterns.md) |
| Charts | [charts.md](references/charts.md) |
| Chart accessibility | [charts-accessibility.md](references/charts-accessibility.md) |
| Image decoding and downsampling | [image-optimization.md](references/image-optimization.md) |
| Liquid Glass | [liquid-glass.md](references/liquid-glass.md) |
| macOS scenes | [macos-scenes.md](references/macos-scenes.md) |
| macOS windows and toolbars | [macos-window-styling.md](references/macos-window-styling.md) |
| macOS views and AppKit interop | [macos-views.md](references/macos-views.md) |
| Text | [text-patterns.md](references/text-patterns.md) |
| Localization | [localization.md](references/localization.md) |
| API replacements | [latest-apis.md](references/latest-apis.md) |
| Whether to migrate soft-deprecated APIs | [soft-deprecation.md](references/soft-deprecation.md) |
| Previews | [previews.md](references/previews.md) |
