<h1 align="center">TimelineKit</h1>

<p align="center">
  <strong>Modular Swift video timeline editor — V8</strong><br />
  <em>value-type editing model · undo/redo · AVFoundation/Core Image render pipeline · iOS / macOS / CLI / MCP</em>
</p>

<p align="center">
  <a href="#quick-start"><img src="https://img.shields.io/badge/Quick_Start-2ea44f?style=for-the-badge" alt="Quick Start" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License" /></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2-FA7343?style=flat&logo=swift&logoColor=white" alt="Swift 6.2" />
  <img src="https://img.shields.io/badge/iOS-18+-000000?style=flat&logo=apple&logoColor=white" alt="iOS 18+" />
  <img src="https://img.shields.io/badge/macOS-15+-000000?style=flat&logo=apple&logoColor=white" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/V8-modular-8A2BE2?style=flat" alt="V8 modular" />
</p>
---

## Status

TimelineKit is extracted from the DreamAI app and rebuilt as a standalone
open-source package under V8. It is actively shaped for external use.

- Swift tools 6.2, iOS 18+, macOS 15+.
- Editor UI and video export flow are iOS-first. macOS UI support is a shell
  (planned for future delivery).
- No test target yet.

## Modules (V8)

TimelineKit is split into layered modules. Each module declares its platform
dependencies explicitly — you can depend on only the layers you need.

### Dependency Graph

```
TimelineKitCore          (Foundation + CoreGraphics)
  ↑
TimelineKitRender        (+ AVFoundation, CoreMedia, CoreImage, Metal)
  ↑
TimelineKitUIShared      (+ no new platform frameworks)
  ↑                ↑
TimelineKitUIiOS   TimelineKitUIMac    (+ SwiftUI, UIKit / AppKit)
  ↑
TimelineKit              (umbrella — re-exports all of the above)
```

Executables: `TimelineKitCLI` and `TimelineKitMCP` sit on top of Core + Render +
UIShared.

### `TimelineKitCore` — Pure data model & algorithms

Zero UI or AVFoundation dependencies. Foundation and CoreGraphics only.

- **`EditorTimeline`** — canonical in-memory editing model. Pure value type
  (Sendable, Hashable, Codable). Contains canvas, tracks, materials pool,
  transitions, and metadata.
- **`EditorTrack`** / **`EditorSegment`** — track and clip model with absolute
  time positioning, z-ordering, keyframe-based animation, and typed segment
  content (video, image, text, subtitle, audio).
- **`EditorAsset`** / **`MaterialsPool`** — asset registry referenced by UUID.
- **`TimeRange`** / **`EditorCanvas`** — geometry and canvas primitives.
- **`TimelineDocument`** — `@MainActor @Observable` wrapper over
  `EditorTimeline` with undo/redo (max 50), split/trim/move/copy-paste, text
  style, z-order, and track management.
- **Animation system** — `EasingCurve`, `KeyframeEvaluator`,
  `AnimationPresetRegistry`, `TransitionPresetRegistry`,
  `ImageAnimationPresetRegistry`, `AnimationMacro`.
- **Conversion** — `TimelineExporter` serializes `EditorTimeline` →
  `ServerTimelineSchema` JSON; `DraftCodable` handles enum-with-associated-value
  persistence.
- **No imports of** SwiftUI, UIKit, AppKit, AVFoundation, or Photos.

### `TimelineKitRender` — UI-less rendering engine

Depends on `TimelineKitCore` plus AVFoundation, CoreMedia, CoreImage, and Metal.
No SwiftUI / UIKit / AppKit.

- **`CompositionBuilder`** — builds `AVComposition` from `EditorTimeline`.
- **`UnifiedCompositor`** — `AVVideoCompositionInstructionProtocol` for custom
  frame compositing in AVFoundation export.
- **`TimelineRenderer`** — MainActor, Metal-backed `CIContext` frame renderer
  (LayerResolver → layer compositors → CVPixelBuffer).
- **Layer renderers** — `VideoLayerComposer`, `ImageLayerComposer`,
  `TextLayerComposer`, `AnimationComposer`, `TransitionComposer`,
  `ColorAdjustmentCompositor`, plus `StaticImageRenderer` and
  `VideoFrameProvider`.
- **Runtime** — `LayerResolver`, `TimelineClock` (real-time playback driver),
  `LayerContent`.
- **Utilities** — `ThumbnailProvider`, `WaveformProvider`, `AssetCache`,
  `ExportEncodingProfile`, `SentinelAsset`.

### `TimelineKitUIShared` — Cross-platform edit session

Depends on Core + Render. No platform-specific UI frameworks.

- **`EditorStore`** — `@MainActor @Observable` state container. Wraps
  `TimelineDocument`, adds AVPlayer playback, composition coordination,
  `DraftStore` persistence, and media import/export.
- **`TimelineCoordinatorProtocol`** — protocol decoupling `EditorStore` from
  platform composition coordinators.
- **`DraftStore`** — local JSON draft persistence per draftID with auto-save,
  launch restore, and portable URL handling.
- **`VideoExporter`** — exports `EditorTimeline` to MP4, saves to Photos
  library, with progress reporting and cancellation.
- **`TimelineImporter`** — `ServerTimelineSchema` → `EditorTimeline` conversion
  (sync or async with real audio duration probing).
- **Services** — `AudioExtractor`, `AudioImporter`, `TTSService`.

### `TimelineKitUIiOS` — iOS editor views

Depends on UIShared + Render + SwiftUI.

- **`ClipEditorView`** — public SwiftUI entry point. Three-layer layout:
  Preview → Tracks → Toolbar. Creates `EditorStore`, `CompositionCoordinator`,
  and `DraftStore`.
- **`CompositionCoordinator`** — owns AVPlayer, debounces timeline changes,
  rebuilds AVPlayerItem, manages TimelineClock + TimelineRenderer for
  image-only main tracks.
- **Views** — `EditorPreviewView`, `TrackCanvasView`, `EditorControlBar`,
  `EditorBottomToolbar`, `FullScreenPreviewView`, plus editing panels for
  text, audio, color adjustment, image animation, transitions, TTS, segment
  replace, video trim, and export config.

### `TimelineKitUIMac` — macOS shell

Depends on UIShared + Render + SwiftUI. Shell target for future macOS editor
delivery. No view files yet.

### `TimelineKit` — Umbrella (backward compatibility)

Re-exports Core, Render, UIShared, and UIiOS via `@_exported import`. Existing
code that imports `TimelineKit` continues to compile. New integrations should
prefer importing the specific sub-module they need.

### Executables

| Target | Description |
|---|---|
| `TimelineKitCLI` | CLI tool. Commands: `inspect`, `import-media`, `export-json`, `render`, `thumbnail`, `waveform`, `validate`. All output is stable JSON on stdout. |
| `TimelineKitMCP` | MCP (Model Context Protocol) server. JSON-RPC over stdin/stdout. Exposes timeline tools for AI agent integration. |

## Architecture

TimelineKit is built around one canonical in-memory model:

```
EditorTimeline
├── canvas: EditorCanvas
├── tracks: [EditorTrack]
├── materials: MaterialsPool
├── transitions: [EditorTransition]
└── metadata: EditorMetadata
```

Core design rules:

- All timeline times are absolute seconds from origin.
- Assets live in `MaterialsPool`; tracks and segments reference assets by UUID.
- Transitions are standalone objects, not embedded in clips.
- `EditorTimeline` is a pure value type — undo restores a struct copy.
- Keyframes are the primary animation representation; presets expand into
  keyframe data.

## Directory Structure

```
Sources/
├── TimelineKitCore/       Pure data model & algorithms (no UI/AVFoundation)
│   ├── Animation/         Easing, keyframe eval, preset registries, macros
│   ├── Conversion/        ServerTimelineSchema, TimelineExporter, DraftCodable
│   ├── Models/            EditorTimeline, EditorTrack, EditorSegment, EditorAsset, TimeRange...
│   └── Persistence/       DraftCodable serialization
│
├── TimelineKitRender/     UI-less rendering engine
│   ├── Rendering/         CompositionBuilder, compositors, providers, AssetCache
│   └── Runtime/           TimelineRenderer, TimelineClock, LayerResolver, LayerContent
│
├── TimelineKitUIShared/   Platform-independent edit session
│   ├── Conversion/        TimelineImporter
│   ├── Export/            VideoExporter
│   ├── Persistence/       DraftStore
│   └── Services/          AudioExtractor, AudioImporter, TTSService
│
├── TimelineKitUIiOS/      iOS editor views
│   └── Views/             ClipEditorView, TrackCanvasView, panels, CompositionCoordinator
│
├── TimelineKitUIMac/      macOS editor shell (stub)
│
├── TimelineKit/           Umbrella — re-exports all sub-modules
│
├── TimelineKitCLI/        CLI executable (timelinekit)
└── TimelineKitMCP/        MCP server executable (timelinekit-mcp)
```

Design notes and versioned specs live in [`docs/`](docs/). Start with:

- [`docs/architecture.md`](docs/architecture.md)
- [`docs/data-model.md`](docs/data-model.md)
- [`docs/conversion-spec.md`](docs/conversion-spec.md)
- [`docs/README.md`](docs/README.md)

## Requirements

- Swift 6.2+
- Xcode with iOS 18 SDK / macOS 15 SDK
- Apple platforms with AVFoundation, Core Image, SwiftUI, Observation, and
  Photos

## Installation

Add the package through Swift Package Manager:

```swift
.package(url: "https://github.com/tuxi/TimelineKit.git", branch: "main")
```

### Choose your dependency

```swift
// Umbrella (backward compat) — imports everything
.product(name: "TimelineKit", package: "TimelineKit")

// Targeted — only what you need
.product(name: "TimelineKitCore", package: "TimelineKit")    // data model only
.product(name: "TimelineKitRender", package: "TimelineKit")  // headless rendering
.product(name: "TimelineKitUIiOS", package: "TimelineKit")   // iOS editor views
```

For local development, open the demo project:

```
Examples/VideoEditorDemo/VideoEditorDemo.xcodeproj
```

## Quick Start

Import server timeline JSON into the editable model:

```swift
import TimelineKit  // or import TimelineKitCore + TimelineKitUIShared

let timeline = try TimelineImporter.importing(from: jsonData, taskID: taskID)
let draftID = DraftStore.save(timeline)
let store = EditorStore(timeline: timeline)
```

Present the editor in an iOS SwiftUI app:

```swift
import TimelineKitUIiOS

ClipEditorView(store: store) { draftID, timeline in
    // Persist or sync with app state.
}
```

Restore a saved draft:

```swift
if let restored = DraftStore.load(draftID: draftID) {
    let store = EditorStore(timeline: restored)
}
```

Perform undoable mutations:

```swift
store.updateTextContent(segmentID: textSegmentID, text: "New title")
store.trimSegment(id: clipID, newTargetRange: TimeRange(start: 2.0, duration: 4.0))
store.undo()
```

Import local media:

```swift
let timeline = try await TimelineImporter.importingMedia(
    from: mediaURLs,
    canvas: EditorCanvas(width: 720, height: 1280, fps: 30),
    imageDuration: 3
)
```

Export to MP4:

```swift
let exporter = VideoExporter()
await exporter.export(timeline: store.timeline)
if let url = exporter.savedVideoURL { /* use exported MP4 */ }
```

Headless rendering without UI frameworks:

```swift
import TimelineKitCore
import TimelineKitRender

let timeline: EditorTimeline = ...
let renderer = TimelineRenderer(timeline: timeline)
let frame = await renderer.renderFrame(at: 1.5)  // CVPixelBuffer
```

CLI usage:

```bash
swift run timelinekit inspect --input timeline.json
swift run timelinekit render --input timeline.json --time 2.0 --output frame.png
swift run timelinekit export-json --input timeline.json --output exported.json
```

MCP server:

```bash
swift run timelinekit-mcp
# Reads JSON-RPC requests from stdin, writes responses to stdout.
```

## Timeline JSON Conversion

`TimelineImporter` normalizes the server-side `ServerTimelineSchema` into the
editable `EditorTimeline` model by:

- expanding scene-relative offsets into absolute `TimeRange` values,
- routing layers into video, overlay, text, subtitle, and audio tracks,
- storing transitions independently from clips,
- importing BGM and voice-over into audio tracks,
- preserving source metadata for later export or debugging.

Use `TimelineExporter` to serialize the edited timeline back to the server
schema.

## Current Limitations

- Some historical docs still reference the original DreamAI/DreamLog context.
- No automated test target yet.
- `VideoExporter` and `ClipEditorView` are iOS-first; macOS UI is a stub.
- `TimelineKitUIMac` has no view implementations yet.

## License

TimelineKit is released under the MIT License. See [LICENSE](LICENSE).
