import Foundation
import LivesCore

/// Keeps the macOS JSON protocol stable while making the canonical project
/// rules live in LivesCore.  The existing renderer can migrate incrementally;
/// every macOS render is already rejected by the same template/source checks
/// used by the iOS editor.
enum SharedCoreBridge {
    static func validate(_ project: RenderProject) throws {
        guard let templateID = TemplateID(rawValue: project.templateId) else {
            throw ServiceError(code: "INVALID_PROJECT", message: "项目模板不受支持", recovery: "请更新应用后重试")
        }

        let assets: [SourceAsset] = project.clips.map { clip in
            SourceAsset(
                id: stableID(for: clip.id),
                displayName: URL(fileURLWithPath: clip.sourcePath).lastPathComponent,
                relativePath: clip.sourcePath,
                durationMs: clip.sourceDurationMs,
                width: 0,
                height: 0,
                codec: "unknown"
            )
        }
        let assetIDs = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, stableID(for: $0.id)) })
        let placements = project.clips.enumerated().compactMap { index, clip -> Placement? in
            guard let sourceID = assetIDs[clip.id],
                  TemplateCatalog.definition(for: templateID).slots.indices.contains(index) else { return nil }
            return Placement(
                sourceAssetID: sourceID,
                slotID: clip.targetSlotId,
                startTimeMs: clip.startTimeMs,
                crop: CropPosition(
                    normalizedCenterX: clip.crop.normalizedCenterX,
                    normalizedCenterY: clip.crop.normalizedCenterY,
                    scale: clip.crop.scale
                ),
                audioEnabled: clip.audioEnabled,
                coverTimeMs: clip.coverTimeMs
            )
        }
        let shortEdge = min(project.canvas.width, project.canvas.height)
        let quality: ExportQuality = shortEdge == 720 ? .p720 : .p1080
        let document = ProjectDocument(
            id: UUID(uuidString: project.id) ?? UUID(),
            name: "macOS project",
            templateID: templateID,
            canvas: CanvasSettings(
                aspectRatio: .custom,
                quality: quality,
                customRatio: CustomRatio(width: project.canvas.width, height: project.canvas.height)
            ),
            assets: assets,
            placements: placements
        )
        do {
            try ProjectValidation.validate(document)
        } catch let error as LivesCoreError {
            throw ServiceError(code: "INVALID_PROJECT", message: error.localizedDescription, recovery: "请返回编辑器并重新生成")
        }
    }

    private static func stableID(for value: String) -> UUID {
        if let uuid = UUID(uuidString: value) { return uuid }
        // RenderProject IDs are normally UUIDs.  For older callers, derive a
        // deterministic UUID-shaped value without changing the wire protocol.
        var bytes = Array(value.utf8.prefix(16))
        bytes += repeatElement(UInt8(0), count: max(0, 16 - bytes.count))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: uuidString) ?? UUID()
    }
}
