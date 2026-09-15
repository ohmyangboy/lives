import Foundation

/// Source-aware output sizing. Legacy canvas quality remains readable in drafts;
/// callers opt into automatic sizing without changing the macOS wire protocol.
public enum OutputResolution {
    /// 按档位限制封面短边；不放大低清封面，不改变原有调用方的默认预算。
    public static func cover(for project: ProjectDocument, maximumShortEdge: Int) -> CanvasSize {
        let size = cover(for: project)
        let factor = min(1, Double(max(2, maximumShortEdge)) / Double(min(size.width, size.height)))
        return CanvasSize(width: max(2, Int((Double(size.width) * factor).rounded(.down))),
                          height: max(2, Int((Double(size.height) * factor).rounded(.down))))
    }

    /// Resolves the user's selected quality tier while keeping Pro checks in
    /// the platform store. Legacy 720p drafts continue to render unchanged.
    public static func resolve(for project: ProjectDocument, pro: Bool) -> CanvasSize {
        // Wallpaper output intentionally matches the current device canvas;
        // quality tiers must not silently change its screen-fitting dimensions.
        if project.canvas.aspectRatio == .wallpaper {
            return CanvasGeometry.size(for: project.canvas)
        }
        switch project.canvas.quality {
        case .p480, .p720, .p1080:
            return CanvasGeometry.size(for: project.canvas)
        case .automatic:
            return automatic(for: project, pro: pro)
        case .p4k:
            return automatic(for: project, pro: pro)
        }
    }

    /// 静态封面独立预算；低清格子不限制其他格子的有效细节。
    public static func cover(for project: ProjectDocument) -> CanvasSize {
        if project.canvas.aspectRatio == .wallpaper { return CanvasGeometry.size(for: project.canvas) }
        var settings = project.canvas
        settings.quality = .p1080
        let reference = CanvasGeometry.size(for: settings)
        let w = Double(reference.width), h = Double(reference.height)
        let template = TemplateCatalog.definition(for: project.templateID)
        var factor = 0.0
        for placement in project.placements {
            guard let asset = project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let slot = template.slots.first(where: { $0.id == placement.slotID }) else { continue }
            let original = placement.usesOriginalPhoto(asset: asset)
            let sw = Double(original ? asset.width : asset.motionWidth)
            let sh = Double(original ? asset.height : asset.motionHeight)
            guard sw > 0, sh > 0 else { continue }
            let zoom = placement.crop.scale.isFinite ? min(3, max(1, placement.crop.scale)) : 1
            factor = max(factor, min(sw / (w * slot.width * zoom), sh / (h * slot.height * zoom)))
        }
        factor = min(factor > 0 ? factor : 1, sqrt(24_000_000 / (w * h)), 8192 / max(w, h))
        return CanvasSize(width: max(2, Int((w * factor + 0.000001).rounded(.down))),
                          height: max(2, Int((h * factor + 0.000001).rounded(.down))))
    }

    public static func automatic(for project: ProjectDocument, pro: Bool) -> CanvasSize {
        var settings = project.canvas
        settings.quality = .p1080
        let reference = CanvasGeometry.size(for: settings)
        let width = Double(reference.width), height = Double(reference.height)
        let shortLimit = pro ? 2160.0 : 1080.0
        let longLimit = pro ? 3840.0 : 1920.0
        let limit = min(shortLimit / min(width, height), longLimit / max(width, height))
        var factor = 1.0
        let template = TemplateCatalog.definition(for: project.templateID)
        for placement in project.placements {
            guard let source = project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let slot = template.slots.first(where: { $0.id == placement.slotID }) else { continue }
            let sourceWidth = source.kind.isMotion ? source.motionWidth : source.width
            let sourceHeight = source.kind.isMotion ? source.motionHeight : source.height
            guard sourceWidth > 0, sourceHeight > 0 else { continue }
            let zoom = placement.crop.scale.isFinite ? min(3, max(1, placement.crop.scale)) : 1
            // 按最清晰的已使用格子预算，低清格子允许插值；至少保持高清档。
            let candidate = min(Double(max(2, sourceWidth)) / (width * slot.width * zoom),
                                Double(max(2, sourceHeight)) / (height * slot.height * zoom))
            factor = max(factor, candidate)
        }
        factor = min(factor, limit)
        func even(_ value: Double) -> Int { max(2, Int((value / 2 + 0.000001).rounded(.down)) * 2) }
        return CanvasSize(width: even(width * factor), height: even(height * factor))
    }
}
