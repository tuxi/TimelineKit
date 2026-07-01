/// TimelineKit — Video clip editor core extracted from DreamAI.
///
/// All types defined in this package are automatically available to importers.
/// This file serves as the module documentation entry point.
///
/// ## Quick Start
///
/// ```swift
/// // 1. Import server JSON into an editable timeline.
/// let editorTimeline = try TimelineImporter.importing(from: timelineJSONData, taskID: taskID)
/// let draftID = DraftStore.save(editorTimeline)
/// let store = EditorStore(timeline: editorTimeline)
///
/// // 2. Present the editor (iOS only).
/// ClipEditorView(store: store) { draftID, timeline in
///     // Persist the draft ID or sync the edited timeline with your app state.
/// }
///
/// // 3. Reopen the local editable draft directly.
/// let restored = DraftStore.load(draftID: draftID)
///
/// // 4. Perform mutations with automatic undo support.
/// store.deleteSegment(id: segmentID)
/// store.updateTextContent(segmentID: id, text: "New text")
/// store.undo()
/// ```
///
/// ## Key Types
/// - `EditorTimeline`   — The canonical in-memory editing model
/// - `EditorStore`      — @Observable state container with undo/redo
/// - `TimelineImporter` — Converts server JSON → EditorTimeline
/// - `TimelineExporter` — Converts EditorTimeline → server JSON for upload/debug/compatibility
/// - `DraftStore`       — Stores the canonical local editable EditorTimeline draft
/// - `ClipEditorView`   — SwiftUI entry point (iOS only)
///
/// ## Design Principles
/// 1. All times are absolute seconds from timeline origin (no relative offsets)
/// 2. Assets live in MaterialsPool; tracks reference by UUID
/// 3. Transitions are independent objects, not attached to clips
/// 4. EditorTimeline is a pure value type — undo is a struct copy
