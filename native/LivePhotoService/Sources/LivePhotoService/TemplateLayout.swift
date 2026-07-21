import CoreGraphics
import Foundation

enum TemplateLayout {
    static func rect(for slotId: String, templateId: String, canvas: CGSize) throws -> CGRect {
        let normalized: CGRect
        switch (templateId, slotId) {
        case ("single", "full"):
            normalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        case ("stack-2", "top"):
            normalized = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case ("stack-2", "bottom"):
            normalized = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case ("side-2", "left"):
            normalized = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case ("side-2", "right"):
            normalized = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case ("stack-3", "top"):
            normalized = CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3.0)
        case ("stack-3", "middle"):
            normalized = CGRect(x: 0, y: 1.0 / 3.0, width: 1, height: 1.0 / 3.0)
        case ("stack-3", "bottom"):
            normalized = CGRect(x: 0, y: 2.0 / 3.0, width: 1, height: 1.0 / 3.0)
        case ("side-3", "left"):
            normalized = CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)
        case ("side-3", "center"):
            normalized = CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case ("side-3", "right"):
            normalized = CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case ("hero-left", "hero-left"):
            normalized = CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
        case ("hero-left", "right-top"):
            normalized = CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 0.5)
        case ("hero-left", "right-bottom"):
            normalized = CGRect(x: 2.0 / 3.0, y: 0.5, width: 1.0 / 3.0, height: 0.5)
        case ("hero-top", "hero-top"):
            normalized = CGRect(x: 0, y: 0, width: 1, height: 2.0 / 3.0)
        case ("hero-top", "bottom-left"):
            normalized = CGRect(x: 0, y: 2.0 / 3.0, width: 0.5, height: 1.0 / 3.0)
        case ("hero-top", "bottom-right"):
            normalized = CGRect(x: 0.5, y: 2.0 / 3.0, width: 0.5, height: 1.0 / 3.0)
        case ("weighted-3", "large"):
            normalized = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case ("weighted-3", "medium"):
            normalized = CGRect(x: 0, y: 0.5, width: 1, height: 0.3)
        case ("weighted-3", "small"):
            normalized = CGRect(x: 0, y: 0.8, width: 1, height: 0.2)
        default:
            throw ServiceError(code: "INVALID_PROJECT", message: "模板与素材位置不匹配", recovery: "请重新选择模板")
        }
        return CGRect(x: normalized.minX * canvas.width, y: normalized.minY * canvas.height, width: normalized.width * canvas.width, height: normalized.height * canvas.height)
    }

    static func aspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        target: CGRect,
        centerX: Double,
        centerY: Double,
        userScale: Double
    ) -> CGAffineTransform {
        let sourceRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(sourceRect.width), height: abs(sourceRect.height))
        let scale = max(target.width / displaySize.width, target.height / displaySize.height) * max(1, userScale)
        let renderedWidth = displaySize.width * scale
        let renderedHeight = displaySize.height * scale
        let overflowX = max(0, renderedWidth - target.width)
        let overflowY = max(0, renderedHeight - target.height)
        let x = target.minX - overflowX * min(1, max(0, centerX))
        let y = target.minY - overflowY * min(1, max(0, centerY))

        var transform = preferredTransform
        transform = transform.concatenating(CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(translationX: x, y: y))
        return transform
    }

    static func sourceCropRectangle(
        target: CGRect,
        transform: CGAffineTransform,
        naturalSize: CGSize
    ) -> CGRect {
        let sourceBounds = CGRect(origin: .zero, size: naturalSize)
        let sourceCrop = target.applying(transform.inverted()).standardized
        return sourceCrop.intersection(sourceBounds)
    }
}
