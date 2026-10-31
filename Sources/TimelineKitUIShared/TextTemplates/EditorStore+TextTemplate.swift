import Foundation
import TimelineKitCore

extension EditorStore {

    /// Inserts a template as a ready-to-edit segment on the matching track.
    ///
    /// The segment is created with the template's full `TextStyle`, so it looks
    /// finished immediately; only the words need editing. Returns `nil` when no
    /// text or subtitle track could host it.
    ///
    /// - Parameters:
    ///   - template: Catalog entry to insert.
    ///   - time: Timeline start; defaults to the playhead.
    ///   - targetTrackID: Preferred host track. Ignored when the track kind does
    ///     not match the template.
    @discardableResult
    public func insertTextTemplate(
        _ template: TextTemplate,
        at time: Double? = nil,
        targetTrackID: UUID? = nil
    ) -> UUID? {
        let start = max(0, time ?? selection.playheadTime)
        let placeholderAssetID = UUID()
        let placeholderAsset = EditorAsset(id: placeholderAssetID, type: .placeholder)
        let segmentID = UUID()
        let range = TimeRange(start: start, duration: max(0.1, template.duration))
        // Template sizes are authored for a 720-wide canvas; rescale so the
        // inserted title keeps its intended share of the frame.
        let style = template.style.scaledForCanvas(width: Double(timeline.canvas.width))

        let content: SegmentContent
        switch template.kind {
        case .title:
            content = .text(SegmentContent.TextContent(
                text: template.defaultText,
                style: style,
                position: template.position,
                anchor: template.anchor
            ))
        case .caption:
            content = .subtitle(SegmentContent.SubtitleContent(
                text: template.defaultText,
                style: style,
                positionY: template.subtitlePositionY,
                maxCharsPerLine: template.maxCharsPerLine
            ))
        }

        let segment = EditorSegment(
            id: segmentID,
            materialID: placeholderAssetID,
            sourceRange: nil,
            targetRange: range,
            content: content
        )

        timeline.materials.add(placeholderAsset)

        let hostTrackID: UUID?
        if let targetTrackID, timeline.track(id: targetTrackID)?.kind == template.trackKind {
            addSegment(toTrack: targetTrackID, segment: segment)
            hostTrackID = targetTrackID
        } else {
            hostTrackID = addSegmentAutoTrack(kind: template.trackKind, segment: segment)
        }

        guard hostTrackID != nil else {
            timeline.materials.remove(id: placeholderAssetID)
            return nil
        }

        selection.selectOnly(segmentID)
        return segmentID
    }

    /// Inserts a template and records it in the recents list.
    @discardableResult
    public func insertTextTemplate(
        _ template: TextTemplate,
        at time: Double? = nil,
        targetTrackID: UUID? = nil,
        recents: RecentTextTemplates
    ) -> UUID? {
        let segmentID = insertTextTemplate(template, at: time, targetTrackID: targetTrackID)
        if segmentID != nil {
            recents.record(template.id)
        }
        return segmentID
    }
}
