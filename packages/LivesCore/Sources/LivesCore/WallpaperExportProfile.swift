import Foundation
import CoreGraphics
import CoreMedia

public enum RenderPurpose: String, Codable, Equatable, Sendable {
    case livePhoto
    case lockScreenWallpaper
}

/// 锁屏导出的动作曲线。四档都保持 2 秒 → 1 秒的平均压缩比，
/// 只改变选段内的快慢分布，总时长与帧数不随档位变化。
public enum WallpaperMotionCurve: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 匀速：与历史导出完全一致，作为对照基线。
    case uniform
    /// 缓入：起手慢、收尾快。
    case easeIn
    /// 缓出：起手快、收尾慢。
    case easeOut
    /// 缓入缓出：两头慢、中间快；动态锁屏的默认档。
    case easeInOut

    public var id: String { rawValue }

    /// 曲线与匀速的混合强度。保留正的下界速度，避免首尾出现零长度的采样区间，
    /// 同时让 s(t) 在 [0, 1] 上严格单调。
    static let strength = 0.85

    /// 归一化进度：f(0) = 0，f(1) = 1，且在 [0, 1] 上严格单调递增。
    public func progress(_ u: Double) -> Double {
        let t = min(max(u, 0), 1)
        switch self {
        case .uniform: return t
        case .easeIn: return (1 - Self.strength) * t + Self.strength * t * t
        case .easeOut: return (1 - Self.strength) * t + Self.strength * t * (2 - t)
        case .easeInOut: return (1 - Self.strength) * t + Self.strength * t * t * (3 - 2 * t)
        }
    }

    /// 输出时间轴上的时刻映射到编辑选段内的源时间，二者同为 timescale 刻度。
    /// 归一化基准是固定的输出时长，因此四档曲线的起止点都落在选段首尾。
    public func sourceTicks(atOutputTicks outTicks: Int64, editTicks: Int64) -> Int64 {
        guard editTicks > 0, WallpaperExportProfile.durationTicks > 0 else { return 0 }
        let u = Double(outTicks) / Double(WallpaperExportProfile.durationTicks)
        return Int64((Double(editTicks) * progress(u)).rounded())
    }
}

/// 时间与元数据沿用 G08–G11；全画幅显示和关键帧对齐需单独真机验收。
/// 时间使用有理数，不能经毫秒或帧率舍入。
public enum WallpaperExportProfile {
    public static let timescale: Int32 = 600
    /// 编辑器保留 2 秒选段，导出时按 2 倍速压缩到 1 秒。
    public static let editDurationMs = 2_000
    public static let outputDurationMs = 1_000
    /// 平均压缩比；预览按它播放，实际快慢分布由所选动作曲线决定。
    public static let playbackRate: Float = 2
    /// 1 秒输出固定 60 帧，与锁屏 Live 壁纸的 60 帧经验值一致。
    public static let frameRate: Int32 = 60
    public static let frameDurationTicks: Int64 = Int64(timescale / frameRate)
    public static let durationTicks: Int64 = Int64(outputDurationMs) * Int64(timescale) / 1000
    /// 封面锚点：输出时间轴第 29 帧，保持与 1.5 秒输出相同的归一化位置。
    public static let coverTick: Int64 = 290
    public static let frameTicks: [Int64] = Array(stride(from: Int64(0), to: durationTicks, by: Int(frameDurationTicks)))
    public static let frameDurations: [Int64] = zip(frameTicks, Array(frameTicks.dropFirst()) + [durationTicks]).map { $1 - $0 }
    public static let videoSize = CanvasSize(width: 1920, height: 1440)
    public static let coverSize = CanvasSize(width: 5712, height: 4284)
    public static let displaySize = CGSize(width: 1440, height: 1920)
    public static let visibleRect = CGRect(origin: .zero, size: displaySize)
    public static let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1440, ty: 0)

    public static func contentRect(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(visibleRect.width / size.width, visibleRect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: visibleRect.midX - fitted.width / 2, y: visibleRect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// 把每格选中的源画面对齐到共同封面时刻；越界部分由渲染器延展边界帧。
    /// 返回源时间轴上“输出起点”相对原片的偏移。锁屏输出先把编辑段压到固定
    /// 输出时长，因此封面时刻要按所选动作曲线先映射回选段内时间。
    public static func sourceOffsetTicks(startTimeMs: Int, coverTimeMs: Int, durationMs: Int,
                                         curve: WallpaperMotionCurve = .uniform) -> Int64 {
        let selectedMs = min(max(0, startTimeMs + coverTimeMs), max(0, durationMs - 34))
        let editTicks = Int64(editDurationMs) * Int64(timescale) / 1000
        let sourceCoverTick = curve.sourceTicks(atOutputTicks: coverTick, editTicks: editTicks)
        return Int64(selectedMs) * Int64(timescale) / 1000 - sourceCoverTick
    }

    public static var frameCount: Int { frameTicks.count }

    public static var outputDuration: CMTime {
        CMTime(value: durationTicks, timescale: timescale)
    }

    public static func hasMotion(in project: ProjectDocument) -> Bool {
        project.placements.contains { placement in
            project.assets.contains { $0.id == placement.sourceAssetID && $0.kind != .photo }
        }
    }
}

/// 输出几何来自当前画布；编码继续保留竖向旋转，图片使用对应的 Orientation=6。
public struct WallpaperOutputGeometry: Equatable, Sendable {
    public let display: CanvasSize
    public var encoded: CanvasSize { CanvasSize(width: display.height, height: display.width) }
    public var displaySize: CGSize { CGSize(width: display.width, height: display.height) }
    public var rotation: CGAffineTransform { CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(display.width), ty: 0) }
    public init(canvas: CanvasSize) { display = canvas }
}
