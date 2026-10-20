# ClipEditorView: host-owned Agent integration

Status: iOS editor API. The macOS workbench does not expose the library-driven
initializer yet; the deprecated macOS `ClipEditorView(store:)` bridge is unchanged.

## Final signature

```swift
public enum EditorPersistenceMode: Sendable, Equatable {
    case draftStore
    case library
}

public init(
    libraryStore: TimelineLibraryStore,
    project: LibraryProject,
    editorStore: EditorStore? = nil,
    persistence: EditorPersistenceMode = .draftStore,
    editorAccessory: ((EditorStore) -> AnyView)? = nil,
    onProjectSave: ((LibraryProject) -> Void)? = nil,
    onPersistenceError: ((Error) -> Void)? = nil,
    onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil,
    onExport: ((Data, URL, UIImage) -> Void)? = nil
)
```

The deprecated compatibility initializer remains:

```swift
@available(*, deprecated, message: "Pass a TimelineLibraryStore and LibraryProject instead.")
public init(
    store: EditorStore,
    onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil,
    onExport: ((Data, URL, UIImage) -> Void)? = nil
)
```

It stays until Dreamlog removes its five old call sites. It always uses
`.draftStore` and the temporary embedded-library bridge.

## Ownership

- If `editorStore` is supplied, the view uses that exact instance for rendering,
  playback, mutation, undo, and persistence. It is never copied or recreated.
- The host should create it from the project that was just loaded:

```swift
let editorStore = EditorStore(timeline: project.timeline)
```

- `editorStore.timeline.id` should equal `project.timeline.id` at open time.
  `LibraryProject.id` is the `.tlkproj` file identity and may be a different UUID;
  do not assume `project.id == project.timeline.id`.
- Use `.id(project.id)` when switching between projects in the same navigation
  position. `ClipEditorView` keeps its `@State` store for the lifetime of the
  view identity; a new project must get a new view identity.
- The host applies an Agent result to the same document:

```swift
editorStore.document.applyExternalTimeline(result.timeline, label: "Agent 剪辑")
```

That registers one undo unit and bumps `compositionVersion`; the view refreshes
from the same `EditorStore`.

## Persistence modes

### `.library`

- `saveDraftAndNotify()` never calls `DraftStore.save`.
- It saves `LibraryProject(id: activeProjectID, name: existingName, timeline: store.timeline)` to `.tlkproj`.
- It calls `onProjectSave(savedProject)` after a successful save.
- It calls `onPersistenceError(error)` on failure.
- `onDraftSave` is not called in this mode.
- `DraftStore.bind` auto-save is not started.

### `.draftStore`

- Preserves the previous behavior: write DraftStore, call `onDraftSave`, and
  also write the active library project when one exists.
- `onProjectSave` is not called.
- This mode is for the old compatibility bridge and existing draft-only callers.

The initializer defaults to `.draftStore` for source compatibility. New
library-driven callers must pass `persistence: .library`; otherwise the legacy
DraftStore + `.tlkproj` double-write remains.

## Agent accessory

`editorAccessory` is rendered in the trailing navigation toolbar and receives
the same `EditorStore`. The intended shape is a host-owned button that presents
its own sheet/inspector:

```swift
ClipEditorView(
    libraryStore: libraryStore,
    project: project,
    editorStore: editorStore,
    persistence: .library,
    editorAccessory: { store in
        AnyView(AgentToolbarButton(store: store))
    },
    onProjectSave: { saved in
        // Update the project list / metadata sidecar if needed.
    },
    onPersistenceError: { error in
        // Show an error; do not report a successful save.
    }
)
```

The editor does not add another `NavigationStack` or full-screen wrapper. The
accessory view owns its own presentation state and can use the same store.

## Save and undo boundaries

- Editor close is the save boundary: `onDisappear` and the close button call the
  same save path.
- The save path compares `AgentEditPlan.timelineVersion(for:)`; an unchanged
  timeline is not written and does not invoke `onProjectSave`.
- In `.library` mode, `.tlkproj` is the only timeline source.
- `onProjectSave` fires after the project file write succeeds. The callback may
  be omitted when the timeline has not changed.
- Agent apply remains one undo unit; manual edits after apply are separate undo
  units.
- The host must not also call `DraftStore.save` in `.library` mode.
