# AgentEditPlan — shared deterministic edit API

Status: MVP. This document describes the command layer currently implemented in
`TimelineKitCore`. It intentionally contains no agent runtime, LLM client,
network access, billing, or project-store policy.

## Ownership and targets

| Layer | Responsibility |
|---|---|
| `TimelineKitCore` | `AgentEditPlan`, command execution, validation, preview/apply, revision hash, execution-store protocol |
| App | Supplies the project timeline, source-fingerprint resolver, persistent `AgentExecutionStore`, and one undo transaction after a successful apply |
| `TimelineKitCLI` / `TimelineKitMCP` | Stateless adapters exposing the same Core API over a JSON file |

The App should depend on the `TimelineKitCore` product (or the `TimelineKit`
umbrella product, which re-exports Core) — never on CLI/MCP — for editing. The
Dreamlog Xcode project currently links the `TimelineKit` umbrella product; both
paths expose `AgentEditPlan` and `AgentEditEngine`. CLI and MCP are adapters, not
a second implementation.

## Time mapping

- Source time is measured in seconds from the start of the source material.
- Target time is measured in seconds from the timeline origin.
- All ranges are half-open `[start, end)`.
- JSON uses TimelineKit's existing `TimeRange` encoding: `{ "start": 2.0, "duration": 3.0 }`, equivalent to `[2.0, 5.0)`.
- `roughCut` accepts only 1x speed. It does not retime, reverse, or apply speed ramps.
- `trim` converts `targetDuration` to source duration using `sourceDuration = targetDuration * speed`.

## Plan shape

```json
{
  "planID": "roughcut-001",
  "externalPlanID": "dreamai-plan-42",
  "externalPlanHash": "approved-by-dreamai",
  "baseTimelineVersion": "269888a3364f4dba",
  "expectedSourceFingerprints": {
    "9076576C-27F0-4867-9B56-73E9AC2CEC2F": "a1b2c3d4e5f60789"
  },
  "commands": [
    {
      "type": "roughCut",
      "materialID": "9076576C-27F0-4867-9B56-73E9AC2CEC2F",
      "sourceRanges": [
        { "start": 2.0, "duration": 3.0 },
        { "start": 10.0, "duration": 4.0 }
      ],
      "segmentIDs": [
        "11111111-1111-1111-1111-111111111111",
        "22222222-2222-2222-2222-222222222222"
      ]
    },
    {
      "type": "addSubtitle",
      "segmentID": "33333333-3333-3333-3333-333333333333",
      "text": "Hello",
      "targetStart": 1.0,
      "duration": 1.5
    }
  ]
}
```

`expectedSourceFingerprints` is a JSON object keyed by asset UUID string. An
empty object means no source check was requested. The decoder also accepts the
old alternating `[UUID, fingerprint]` array emitted by the first prototype, but
the encoder always emits an object. The App can pass a resolver to
`preview`/`apply`; Core calls it with the `EditorAsset`.

Fingerprint formats are deliberately separate:

| Source | Format | Notes |
|---|---|---|
| Core default resolver | 16 lowercase hex chars | FNV-1a of local file bytes; reads `asset.localURL` only |
| DreamAI/Dreamlog external `source_fingerprint` | `sha256:` + lowercase hex | Must come from the App/evidence pipeline |

They are not interchangeable. Dreamlog must pass a resolver that returns the
same value stored in `expectedSourceFingerprints` (for example the SHA-256 of
the source file or the content fingerprint recorded in `VideoEvidence`). If the
resolver returns `nil`, Core reports `sourceFingerprintMismatch(..., actual:
"missing")` and does not apply.

## Supported commands

| Command | Fields | Notes |
|---|---|---|
| `trim` | `segmentID`, `sourceStart?`, `targetStart`, `duration` | For video/audio, `sourceStart` defaults to the current in-point; the source duration is derived from the target duration and speed |
| `delete` | `segmentID` | Main-track deletion repacks the backbone |
| `move` | `segmentID`, `targetStart` | Does not re-time media |
| `split` | `segmentID`, `at`, `newSegmentID?` | Caller may supply the right-hand UUID; omitted means a deterministic Core-derived UUID |
| `addSubtitle` | `segmentID?`, `text`, `targetStart`, `duration` | Creates a placeholder material and a deterministic subtitle track |
| `roughCut` | `materialID`, ordered `sourceRanges`, `segmentIDs` | Replaces the single main-track source clip with contiguous clips |

Multiple `addSubtitle` commands are valid in one plan. They are executed in
order in the same atomic batch. An explicit `segmentID` is recommended for
cross-plan identity; when omitted, Core derives a deterministic UUID from
`text + targetStart + duration`, so preview and apply still match. Subtitles
that do not overlap reuse the first compatible subtitle track; an overlapping
subtitle creates a deterministic track using its resolved segment ID.

## roughCut safety contract

`roughCut` is accepted only when all of the following are true:

- The material exists, is a video asset, and has `nativeDuration`.
- The main track has exactly one segment.
- That segment is the only segment referencing the material.
- The segment is 1x and covers the full source. `sourceRange == nil` and an explicit `[0, nativeDuration)` are both accepted.
- The timeline has no transitions; the source segment has no keyframes or animations.
- Source ranges are non-empty, non-negative, inside `[0, nativeDuration]`, ordered, and non-overlapping.
- `segmentIDs.count == sourceRanges.count`; IDs are unique, do not collide with other segments, and are caller-provided.
- The result is contiguous on the main track starting at `0`, with target duration equal to source duration for each range.

Unsupported cases return `AgentEditError.invalidPlan`; they are never silently
approximated.

## Revision, preview, transaction, undo

- `baseTimelineVersion` is a local FNV-1a hash of a canonical JSON timeline snapshot.
- `AgentEditPlan.timelineVersion(for:)` first applies semantic canonicalization: a `sourceRange` covering the full native material is treated as `nil`. Therefore `.tlkproj` may store either representation without creating a second revision. Hosts that want to persist the normalized form can call `AgentEditPlan.canonicalTimeline(_:)`.
- `preview` validates the same revision and source fingerprints as `apply`. A stale or fingerprint-mismatched plan cannot produce an applicable preview.
- Commands run on a copy (`TimelineDocument` created from the input timeline). If any command fails, no partial timeline is returned.
- `apply` returns the complete resulting `EditorTimeline`; it does not mutate the caller's value.
- `TimelineDocument.applyExternalTimeline(_:label:)` replaces the whole timeline and registers one undo unit. `EditorStore` exposes the same method. The App should call it with the result from `AgentEditEngine.apply`; do not assign `store.timeline` directly, because that bypasses undo.
- `TimelineDocument` still owns only in-memory undo/redo. The App owns project persistence and decides when to call `saveThrowing`.
- There is no persistent revision counter in the timeline JSON. The version is derived from content, so callers must recompute it after any edit.

## Idempotency

`apply` is keyed by `executionID` through `AgentExecutionStore`:

1. If a stored result exists for the ID, Core verifies the same `planID` and local `planHash`, then returns the stored timeline with `replayed = true`.
2. If the ID is reused for a different plan, Core throws `executionConflict`.
3. On first apply, Core calls `executionStore.record(result)`. If that throws, Core does not report success.
4. On success, Core returns `replayed = false` and `didApply = true`.

`AgentExecutionStore.result(for:)` and `record(_:)` are throwing. A host should
throw on journal I/O or corruption rather than returning `nil`; `nil` means
"no record exists" and permits a fresh apply.

`record` is the host commit hook. A Dreamlog implementation should, in order:

1. Persist the timeline with a throwing write (`DraftStore.saveThrowing` or the host's project store).
2. Register one undo unit with `editorStore.applyExternalTimeline(result.timeline)`.
3. Persist the execution record, including `executionID`, `planID`, local `planHash`, external IDs, resulting `timelineVersion`, and the result payload needed for replay.
4. Return normally.

The host may use a pending/applied marker for crash recovery. If the App crashes
after the Core apply but before the result is returned, a restart should look up
`executionID`: if the saved timeline/undo marker matches the stored result,
return the stored result; if it cannot determine whether the apply was saved,
report `needs_reconciliation` rather than re-running Core.

Adapters must write the project only when `result.didApply == true`. A replay
returns the first result but must not rewrite the project.

The protocol is the persistence boundary. `InMemoryAgentExecutionStore` is a
reference implementation only. The CLI/MCP adapters currently use an in-memory
store, so their replay guarantee is process-local; cross-process exactly-once
behavior requires the App's project store.

## External approval identity

- `externalPlanID` and `externalPlanHash` are carried through to preview/apply output.
- They are excluded from TimelineKit's local `planHash`.
- The local `planHash` is a normalized command snapshot for optimistic concurrency; it is not a cryptographic signature and must not be compared with DreamAI's approval hash.
- `externalPlanHash` is not verified by Core.

## Error model

`AgentEditError` covers:

- `invalidPlan(String)` — unsupported or inconsistent command/state
- `staleTimeline(expected:actual:)` — revision mismatch
- `sourceFingerprintMismatch(assetID:expected:actual:)` — missing or changed source
- `executionConflict(executionID:)` — execution ID reused for a different plan

## Adapter surface

CLI:

```bash
timelinekit apply-plan timeline.json --plan plan.json --execution-id exec-1
timelinekit apply-plan timeline.json --plan plan.json --dry-run
```

MCP:

- Standard tool: `timelinekit.apply_edits`
- Compatibility alias: `timelinekit.apply_edit_plan`
- Both have the same schema and handler.
- Required schema fields: `path`, `plan`
- Apply-only field: `execution_id`
- Preview-only field: `dry_run`

The old operation-array MCP tool that previously occupied the
`timelinekit.apply_edits` name has been removed. New callers must use the
`AgentEditPlan` schema above.

## Dreamlog host integration shape

```swift
import TimelineKitCore
import TimelineKitUIShared

// 1. Build the Core plan. source_ranges are converted to TimeRange(start,
//    duration: end - start); IDs are generated once and reused on retry.
let plan = AgentEditPlan(
    planID: "plan-" + externalPlanID,
    baseTimelineVersion: AgentEditPlan.timelineVersion(for: editorStore.timeline),
    commands: mappedCommands,
    expectedSourceFingerprints: [materialID: externalFingerprint],
    externalPlanID: externalPlanID,
    externalPlanHash: externalPlanHash
)

// 2. Preview with the same resolver used by apply.
let preview = try AgentEditEngine.preview(
    plan: plan,
    timeline: editorStore.timeline,
    sourceFingerprint: { asset in externalFingerprint(for: asset) }
)

// 3. Apply. record() is the host commit hook; if any step throws, Core
//    propagates the failure instead of reporting a successful apply.
let store = DreamlogExecutionStore(editorStore: editorStore, journal: journal)
let result = try await AgentEditEngine.apply(
    plan: plan,
    timeline: editorStore.timeline,
    executionID: executionID,
    executionStore: store,
    sourceFingerprint: { asset in externalFingerprint(for: asset) }
)

@MainActor
final class DreamlogExecutionStore: AgentExecutionStore {
    private let editorStore: EditorStore
    private let journal: ExecutionJournal

    init(editorStore: EditorStore, journal: ExecutionJournal) {
        self.editorStore = editorStore
        self.journal = journal
    }

    func result(for executionID: String) async throws -> AgentExecutionResult? {
        try journal.result(for: executionID)
    }

    func record(_ result: AgentExecutionResult) async throws {
        try DraftStore.saveThrowing(result.timeline)
        editorStore.applyExternalTimeline(result.timeline, label: "Agent 剪辑")
        try journal.record(result)
    }
}
```

The exact `ExecutionJournal` implementation belongs to Dreamlog; Core only
requires the throwing lookup/record protocol. The sample intentionally does not
put project paths, UI state, or undo policy into TimelineKitCore.
