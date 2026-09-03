import CoreGraphics

/// Source-center coordinates, shared by editor, playback, cover and movie rendering.
public enum CropGeometry {
    public static func drawnSize(source: CGSize, target: CGSize, scale: Double) -> CGSize {
        let fill = max(target.width / max(1, source.width), target.height / max(1, source.height)) * min(3, max(1, scale))
        return CGSize(width: source.width * fill, height: source.height * fill)
    }

    public static func clamped(_ crop: CropPosition, source: CGSize, target: CGSize) -> CropPosition {
        let drawn = drawnSize(source: source, target: target, scale: crop.scale)
        let minX = min(0.5, target.width / max(1, drawn.width) / 2)
        let minY = min(0.5, target.height / max(1, drawn.height) / 2)
        return CropPosition(normalizedCenterX: min(1 - minX, max(minX, crop.normalizedCenterX)),
                            normalizedCenterY: min(1 - minY, max(minY, crop.normalizedCenterY)), scale: crop.scale)
    }

    public static func drawnRect(source: CGSize, target: CGRect, crop: CropPosition) -> CGRect {
        let safe = clamped(crop, source: source, target: target.size)
        let drawn = drawnSize(source: source, target: target.size, scale: safe.scale)
        return CGRect(x: target.midX - drawn.width * safe.normalizedCenterX,
                      y: target.midY - drawn.height * safe.normalizedCenterY,
                      width: drawn.width, height: drawn.height)
    }

    public static func videoTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, target: CGRect, crop: CropPosition) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let drawn = drawnRect(source: oriented.size, target: target, crop: crop)
        let factor = drawn.width / max(1, oriented.width)
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(translationX: drawn.minX, y: drawn.minY))
    }
}
