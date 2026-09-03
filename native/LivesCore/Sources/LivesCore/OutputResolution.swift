import Foundation

/// Source-aware output sizing. Legacy canvas quality remains readable in drafts;
/// callers opt into automatic sizing without changing the macOS wire protocol.
public enum OutputResolution {
    /// Resolves the user's selected quality tier while keeping Pro checks in
    /// the platform store. Legacy 720p drafts continue to render unchanged.
    public static func resolve(for project: ProjectDocument, pro: Bool) -> CanvasSize {
        switch project.canvas.quality {
        case .p480, .p720, .p1080:
            return CanvasGeometry.size(for: project.canvas)
        case .automatic:
            return automatic(for: project, pro: pro)
        case .p4k:
            return automatic(for: project, pro: pro)
        }
    }

    public static func automatic(for project: ProjectDocument, pro: Bool) -> CanvasSize {
        var settings = project.canvas
        settings.quality = .p1080
        let reference = CanvasGeometry.size(for: settings)
        let width = Double(reference.width), height = Double(reference.height)
        let shortLimit = pro ? 2160.0 : 1080.0
        let longLimit = pro ? 3840.0 : 1920.0
        var factor = min(shortLimit / min(width, height), longLimit / max(width, height))
        let template = TemplateCatalog.definition(for: project.templateID)
        for placement in project.placements {
            guard let source = project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let slot = template.slots.first(where: { $0.id == placement.slotID }) else { continue }
            let sourceWidth = source.kind.isMotion ? source.motionWidth : source.width
            let sourceHeight = source.kind.isMotion ? source.motionHeight : source.height
            guard sourceWidth > 0, sourceHeight > 0 else { continue }
            let zoom = placement.crop.scale.isFinite ? min(3, max(1, placement.crop.scale)) : 1
            // Aspect-fill's scale must not exceed 1 source pixel per output pixel.
            factor = min(factor, Double(max(2, sourceWidth)) / (width * slot.width * zoom),
                         Double(max(2, sourceHeight)) / (height * slot.height * zoom))
        }
        func even(_ value: Double) -> Int { max(2, Int((value / 2 + 0.000001).rounded(.down)) * 2) }
        return CanvasSize(width: even(width * factor), height: even(height * factor))
    }
}
