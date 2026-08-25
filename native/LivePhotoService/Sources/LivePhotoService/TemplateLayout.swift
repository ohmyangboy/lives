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
        let rawX = normalized.minX * canvas.width
        let rawY = normalized.minY * canvas.height
        let rawWidth = normalized.width * canvas.width
        let rawHeight = normalized.height * canvas.height

        let minX = normalized.minX <= 0.0001 ? 0 : rawX
        let minY = normalized.minY <= 0.0001 ? 0 : rawY
        let width = normalized.maxX >= 0.9999 ? (canvas.width - minX) : rawWidth
        let height = normalized.maxY >= 0.9999 ? (canvas.height - minY) : rawHeight

        return CGRect(x: minX, y: minY, width: width, height: height)
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
        canvas: CGSize,
        transform: CGAffineTransform,
        naturalSize: CGSize
    ) -> CGRect {
        let sourceBounds = CGRect(origin: .zero, size: naturalSize)
        let touchesLeft = target.minX <= 1.0
        let touchesTop = target.minY <= 1.0
        let touchesRight = target.maxX >= canvas.width - 1.0
        let touchesBottom = target.maxY >= canvas.height - 1.0

        let minX = touchesLeft ? target.minX - 10_000 : target.minX - 2.0
        let minY = touchesTop ? target.minY - 10_000 : target.minY - 2.0
        let maxX = touchesRight ? target.maxX + 10_000 : target.maxX + 2.0
        let maxY = touchesBottom ? target.maxY + 10_000 : target.maxY + 2.0

        let expandedTarget = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let rawCrop = expandedTarget.applying(transform.inverted()).standardized
        let clampedMinX = max(0, min(sourceBounds.width, rawCrop.minX))
        let clampedMinY = max(0, min(sourceBounds.height, rawCrop.minY))
        let clampedMaxX = max(clampedMinX, min(sourceBounds.width, rawCrop.maxX))
        let clampedMaxY = max(clampedMinY, min(sourceBounds.height, rawCrop.maxY))
        return CGRect(x: clampedMinX, y: clampedMinY, width: clampedMaxX - clampedMinX, height: clampedMaxY - clampedMinY)
    }
}
