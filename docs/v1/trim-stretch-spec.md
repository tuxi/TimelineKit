# Trim & Stretch Rules — Main Track vs Attachment Track

Authoritative spec for all handle-drag behaviour. Implementation **must** match exactly.

Benchmark reference: 剪映 / Final Cut Pro / LumaFusion main-track ripple trim interaction.

---

## Universal invariants (never violated)

1. Segments may never overlap on any track.
2. All duration calculations use `targetRange.duration`; `sourceRange.duration` is ignored in rendering (always stale after re-trim).
3. Stretching only adjusts logical time boundaries via `sourceRange`; the source asset is **never cut or transcoded**.
4. Right-handle cap = `segmentTimelineStart + (assetNativeDuration − sourceRange.start)`.  Drag stops dead at this boundary — no static frames, no black screens.

---

## Drag interaction model (universal)

### During drag (`.changed` — live preview)

- **Only the current segment block's frame updates** in real-time.  The block
  follows the finger: left-handle drag left → block visually extends left;
  right-handle drag right → block visually extends right.
- **No other blocks on any track move.**  Successors, predecessors, overlay,
  audio, subtitle — all stay where they are.
- **No store mutation for the main track** (`onTrimPreview = nil`).
  Attachment tracks still call `previewTrimRange` for compositor preview.
- **Auto-scroll**: when the touch reaches within 60 pt of the visible scroll-view
  edge, the timeline viewport scrolls automatically (max 8 pt/frame,
  proportional to edge depth).  Left-edge → scroll left; right-edge →
  scroll right.

### On commit (`.ended` — release)

- `trimSegment` runs on the store **synchronously**.
- Main track: the store converts visual left-extension into the **pre-roll
  consumption model** (see below).  The track is re-packed: contiguous from
  t=0, no gaps, no overlaps.
- Immediately after the store mutation, `relayoutSegments` redraws every block
  from the final timeline data.  No waiting for SwiftUI observation cycles.
- All tracks are aligned; the render/compositor sees the final state.

---

## Main track

### Core property
Magnetic ripple — segments are always contiguous from t = 0, no gaps, no overlaps.

### Right-handle (extend right)

- During drag: block's right edge follows the finger rightward.  Successors
  stay put.  Auto-scroll when handle reaches viewport right edge.
- **Cap**: `timeline_start + (nativeDuration − sourceRange.start)`.
- On commit: `targetRange` updated in-place.  All successor segments shift
  right by `growthDelta = newEnd − oldEnd`.  Project total duration grows.

### Left-handle (extend left — pre-roll consumption model)

The left-handle drag has two phases with different coordinate systems:

**Phase 1 — visual drag preview (`.changed`)**
- The block's left edge moves left with the finger (intuitive feedback).
- `clampedRange(isLeading: true, dt:)` with dt < 0:
  - `newStart = trimStartRange.start + dt` (moves left, clamped to trimLeftBound)
  - Right end stays fixed; duration = end − newStart (increases).
- The block frame is repositioned: x = layout.x(for: newStart).
- No other blocks move.  `onTrimPreview` is nil for main track.

**Phase 2 — store commit (`trimSegment`)**
- The store detects left-extension (`newTargetRange.start < oldStart`) and
  converts to the pre-roll model:
  - **`finalRange.start` is anchored at `oldStart`** — the left edge snaps
    back to where it was, keeping the track contiguous.
  - **`finalRange.duration`** keeps the same increased duration from the
    gesture — the block grows to the **right**.
  - **`sourceRange.start`** decreases by `delta` (= oldStart − proposedStart),
    so the compositor reads earlier pre-roll content from the source asset.
  - **Successors** shift right by `growthDelta = finalRange.end − oldEnd`.
  - **Predecessors** are NEVER modified (no squish, no rolling edit).
- Project total duration grows by `delta`.
- Constraint (`.began`): `delta ≤ sourceRange.start` (video) — can't exceed
  available pre-roll.  Images have no pre-roll (handle locked if
  sourceRange.start = 0).
- **First segment** works identically — `targetRange.start` stays at 0,
  block grows right, successors shift right.

### Left-handle (inward trim — shrink from left)

- During drag: block's left edge moves right (dt > 0), shrinking the block.
- On commit: `targetRange.start` moves right, duration shrinks.
- No successor/predecessor changes.  No sourceRange change.
- Constraint: `duration ≥ MIN_SEGMENT_DURATION`.

---

## Attachment tracks (audio, subtitle, sticker, effect)

No ripple, no magnetic snapping.  Segments are fully independent.

- `onTrimPreview` calls `store.previewTrimRange` during drag for real-time
  compositor preview.
- Auto-scroll applies (same edge-zone logic).

### Right-handle (extend right)
- Allowed only when there is **no right sibling** in the same track.
- Cap: same formula as main track (`nativeDuration − sourceRange.start`).

### Left-handle (extend left)
- Allowed only when there is **no left sibling** in the same track.
- Cap: `sourceRange.start` (video); unlimited for images.
- On commit, `sourceRange.start` decreases by `delta` so the compositor reads the pre-roll section.

### Left-handle (inward trim — shrink from left)
- Always allowed (no neighbour interaction).

---

## sourceRange.start update rules

| Operation | Who updates sourceRange.start |
|---|---|
| Right-handle extend | unchanged |
| Left-handle extend (main or attachment) | `newSrcStart = max(0, oldSrcStart − delta)` passed through `onTrimCommit` and written in `trimSegment` |
| Left-handle inward trim | unchanged (in-point doesn't move) |
| Material replacement with clip in-point | `replaceSegmentMaterial(clipInTime:)` sets `sourceRange.start = clipInTime` |

---

## Auto-scroll specification

| Property | Value |
|---|---|
| Edge zone width | 60 pt from visible bounds |
| Max scroll speed | 8 pt per `.changed` tick |
| Speed curve | Linear ramp: speed = (edgeDist / edgeZone) × maxSpeed |
| Left-edge drag | Scroll right (contentOffset.x decreases) |
| Right-edge drag | Scroll left (contentOffset.x increases) |
| Bounds | Clamped to [0, contentSize.width − bounds.width] |

---

## Implementation files

| Concern | File |
|---|---|
| Gesture bounds (`trimLeftBound`, `trimRightBound`) | `TrackCanvasView.swift` — `SegmentBlockView.handleTrimPan(.began)` |
| Clamp & preview range calculation | `TrackCanvasView.swift` — `SegmentBlockView.clampedRange(isLeading:dt:)` |
| Block frame update during drag | `TrackCanvasView.swift` — `SegmentBlockView.applyTrimPreview(isLeading:dt:)` |
| Store pre-roll conversion + ripple | `EditorStore.swift` — `trimSegment(id:newTargetRange:newSourceRangeStart:)` |
| Post-commit immediate relayout | `ClipEditorViewController.swift` — `canvas.onTrimCommit` |
| Auto-scroll | `TrackCanvasView.swift` — `handleAutoScroll(touchInWindow:)` |
| sourceRange.start propagation to blocks | `TrackCanvasView.swift` — `TrackRowView.update()` and `buildSegments()` |
| Rendering in-point | `CompositionBuilder.swift` — `srcRange(for:)` |
