# TimelineKit

TimelineKit is a Swift package for building an iOS-first video timeline editor.
It provides a value-type editing model, an observable editor store with undo/redo,
SwiftUI/UIKit editing views, timeline import/export utilities, draft persistence,
and an AVFoundation/Core Image based preview/export pipeline.

[中文说明](README.zh-CN.md)

## Status

TimelineKit is a new standalone Git repository extracted from the DreamAI app
(previously developed under the DreamLog/Dreamlog codebase). It is still being
shaped for standalone open-source use.

- Current package declaration: Swift tools 6.2, iOS 18+, macOS 15+.
- The editor UI and video export flow are primarily iOS-oriented.
- Model, conversion, animation, and persistence code are designed as reusable
  package internals.
- There is no test target yet.

## What It Includes

- **Canonical timeline model**: `EditorTimeline`, `EditorTrack`,
  `EditorSegment`, `EditorAsset`, `EditorTransition`, `TimeRange`,
  `KeyframeSet`, and typed segment content for video, image, text, subtitle,
  and audio.
- **Editor state store**: `EditorStore` is an `@Observable` main-actor store
  that owns timeline mutation, selection, playback coordination, undo/redo,
  trimming, moving, splitting, text edits, audio controls, transitions, and
  export configuration updates.
- **Editor UI**: `ClipEditorView` combines a SwiftUI preview/control shell with
  a UIKit timeline canvas for track gestures and dense timeline interaction.
- **Import/export conversion**: `TimelineImporter` and `TimelineExporter`
  convert between `ServerTimelineSchema` JSON and the editable
  `EditorTimeline` model.
- **Preview and rendering**: AVFoundation/Core Image rendering components build
  compositions, resolve layers, render images/video/text, handle transitions,
  and provide timeline runtime previews.
- **Export**: `VideoExporter` exports an `EditorTimeline` to MP4 with configurable
  resolution, frame rate, bitrate tier, and HDR downgrade handling.
- **Draft persistence**: `DraftStore` saves editable timelines locally and
  restores portable asset URLs across app launches.
- **Audio utilities**: audio import, audio extraction, waveform generation, and
  local text-to-speech support.

## Architecture Snapshot

TimelineKit is built around one canonical in-memory model:

```text
EditorTimeline
├── canvas: EditorCanvas
├── tracks: [EditorTrack]
├── materials: MaterialsPool
├── transitions: [EditorTransition]
└── metadata: EditorMetadata
```

The main design rules are:

- All timeline times are absolute seconds from timeline origin.
- Assets live in `MaterialsPool`; tracks and segments reference assets by UUID.
- Transitions are standalone objects, not embedded in clips.
- `EditorTimeline` is a pure value type, so undo/redo can restore whole timeline
  snapshots.
- Keyframes are the primary animation representation; presets are convenience
  inputs that can be expanded into keyframe data.

## Directory Guide

```text
Sources/TimelineKit/
├── Animation/      Animation presets, macro expansion, easing, keyframe eval
├── Conversion/     Server JSON schema plus import/export conversion
├── Export/         MP4 export orchestration
├── Models/         Timeline, tracks, segments, assets, canvas, transitions
├── Persistence/    Draft storage and asset download/cache helpers
├── Rendering/      Composition builder, compositors, providers, runtime pieces
├── Runtime/        Layer resolution, timeline clock, runtime renderer
├── Services/       Audio import/extract and text-to-speech helpers
├── Store/          EditorStore and mutation APIs
└── Views/          SwiftUI/UIKit editor surfaces
```

Design notes and versioned specs live in [`docs/`](docs/). Start with:

- [`docs/architecture.md`](docs/architecture.md)
- [`docs/data-model.md`](docs/data-model.md)
- [`docs/conversion-spec.md`](docs/conversion-spec.md)
- [`docs/README.md`](docs/README.md)

## Requirements

- Swift 6.2+
- Xcode with iOS 18 SDK / macOS 15 SDK
- Apple platforms with AVFoundation, Core Image, SwiftUI, Observation, and Photos

## Installation

When the package is published, add it through Swift Package Manager:

```swift
.package(url: "https://github.com/<owner>/TimelineKit.git", branch: "main")
```

Then add the product to your target:

```swift
.product(name: "TimelineKit", package: "TimelineKit")
```

For local development, open the package directory or the included demo project:

```text
TimelineKit/
Examples/VideoEditorDemo/VideoEditorDemo.xcodeproj
```

The demo app lets you pick photos or videos from the system photo library and
opens them through `TimelineImporter.importingMedia(from:)`.

## Quick Start

Import server timeline JSON into the editable model:

```swift
import TimelineKit

let timeline = try TimelineImporter.importing(from: jsonData, taskID: taskID)
let draftID = DraftStore.save(timeline)
let store = EditorStore(timeline: timeline)
```

Present the editor in an iOS SwiftUI app:

```swift
ClipEditorView(store: store) { draftID, timeline in
    // Persist the draft ID or sync the edited timeline with your app state.
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
store.trimSegment(
    id: clipID,
    newTargetRange: TimeRange(start: 2.0, duration: 4.0)
)
store.undo()
```

Import local media into a simple timeline:

```swift
let timeline = try await TimelineImporter.importingMedia(
    from: mediaURLs,
    canvas: EditorCanvas(width: 720, height: 1280, fps: 30),
    imageDuration: 3
)
```

Export a timeline:

```swift
let exporter = VideoExporter()
await exporter.export(timeline: store.timeline)

if let url = exporter.savedVideoURL {
    // Use the exported MP4 file URL.
}
```

## Timeline JSON Conversion

TimelineKit includes a Codable mirror of the server-side timeline format in
`ServerTimelineSchema`. The importer normalizes that schema into an editing
model by:

- expanding scene-relative offsets into absolute `TimeRange` values,
- routing layers into video, overlay, text, subtitle, and audio tracks,
- storing transitions independently from clips,
- importing BGM and voice-over into audio tracks,
- preserving source metadata for later export or debugging.

Use `TimelineExporter` when you need to serialize the edited timeline back to
the server/debug schema.

## Current Limitations

- Some historical docs still mention the original DreamAI/DreamLog integration
  context.
- The codebase currently has documentation-heavy version specs but no automated
  test target.
- `VideoExporter` and `ClipEditorView` are intended for iOS app integration.

## License

TimelineKit is released under the MIT License. See [LICENSE](LICENSE).
