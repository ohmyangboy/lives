import CoreGraphics
import Foundation

public enum TemplateID: String, Codable, CaseIterable, Sendable {
    case single
    case stack2 = "stack-2"
    case side2 = "side-2"
    case grid4 = "grid-4"
    case stack3 = "stack-3"
    case side3 = "side-3"
    case heroLeft = "hero-left"
    case heroTop = "hero-top"
    case weighted3 = "weighted-3"
}

public enum AspectRatioID: String, Codable, CaseIterable, Sendable {
    case portrait916 = "9:16"
    case portrait45 = "4:5"
    case portrait57 = "5:7"
    case portrait34 = "3:4"
    case portrait35 = "3:5"
    case portrait23 = "2:3"
    case square = "1:1"
    case landscape32 = "3:2"
    case landscape53 = "5:3"
    case landscape43 = "4:3"
    case landscape75 = "7:5"
    case landscape54 = "5:4"
    case landscape169 = "16:9"
    case wallpaper
    case custom
}

public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case p480 = "480p"
    case p1080 = "1080p"
    /// Legacy value kept so existing macOS/iOS drafts remain readable.
    case p720 = "720p"
    case automatic = "automatic"
    case p4k = "4K"

    public var shortEdge: Int {
        switch self {
        case .p480: 480
        case .p720: 720
        case .p1080, .automatic: 1080
        case .p4k: 2160
        }
    }

    public var requiresPro: Bool { self == .automatic || self == .p4k }
}

public enum WatermarkMode: String, Codable, CaseIterable, Sendable {
    case lives
    case none
    case custom

    public var requiresPro: Bool { self != .lives }
}

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case bottomLeft, bottomCenter, bottomRight
}

public enum WatermarkIconShape: String, Codable, CaseIterable, Sendable {
    case square, rounded, circle

    public var cornerRatio: Double {
        switch self {
        case .square: return 0
        case .rounded: return 3.0 / 14.0
        case .circle: return 0.5
        }
    }
}

/// 预览与导出共用的水印文字样式；尺寸以 360pt 参考画布为基准。
public enum WatermarkTypography {
    public static let fontName = "PingFangSC-Medium"
    public static let shadowRadius = 0.8
    public static let shadowOffset = 0.5
    public static let shadowOpacity = 0.32

    public static func tracking(for text: String, fontSize: Double) -> Double {
        text.unicodeScalars.allSatisfy { $0.isASCII } ? fontSize * 0.02 : 0
    }
}

public enum WatermarkIconPosition: String, Codable, CaseIterable, Sendable {
    case leading, trailing
}

/// 水印底部居中时的光学布局参数；间距不参与视觉重心计算。
public enum WatermarkLayout {
    public static let iconOpticalWeight = 0.45

    /// 返回相对几何居中点的水平修正量，正值向右。
    public static func opticalCenterOffset(
        textWidth: Double,
        iconSize: Double,
        spacing: Double,
        iconPosition: WatermarkIconPosition
    ) -> Double {
        guard textWidth > 0, iconSize > 0 else { return 0 }
        let groupWidth = textWidth + iconSize + max(0, spacing)
        let gap = max(0, spacing)
        let iconCenter: Double
        let textCenter: Double
        switch iconPosition {
        case .leading:
            iconCenter = iconSize / 2
            textCenter = iconSize + gap + textWidth / 2
        case .trailing:
            textCenter = textWidth / 2
            iconCenter = textWidth + gap + iconSize / 2
        }
        let textWeight = 1 - iconOpticalWeight
        let opticalCenter = iconOpticalWeight * iconCenter + textWeight * textCenter
        return groupWidth / 2 - opticalCenter
    }
}

public struct WatermarkSettings: Codable, Equatable, Sendable {
    public var mode: WatermarkMode
    public var text: String
    public var opacity: Double
    public var customIconData: Data?
    public var position: WatermarkPosition
    public var iconPosition: WatermarkIconPosition
    public var iconShape: WatermarkIconShape
    public var sizeScale: Double

    public var effectiveSizeScale: Double {
        guard sizeScale.isFinite else { return 1 }
        return min(2, max(0.5, sizeScale))
    }

    public var effectiveOpacity: Double {
        guard opacity.isFinite else { return 1 }
        return min(1, max(0.1, opacity))
    }

    public init(mode: WatermarkMode = .lives, text: String = "lives", opacity: Double = 1,
                customIconData: Data? = nil, position: WatermarkPosition = .bottomCenter,
                iconShape: WatermarkIconShape = .rounded, sizeScale: Double = 1, iconPosition: WatermarkIconPosition = .leading) {
        self.mode = mode
        self.text = text.isEmpty ? "lives" : String(text.prefix(32))
        self.opacity = opacity.isFinite ? min(1, max(0.1, opacity)) : 1
        self.customIconData = customIconData
        self.position = position
        self.iconPosition = iconPosition
        self.iconShape = iconShape
        self.sizeScale = sizeScale.isFinite ? min(2, max(0.5, sizeScale)) : 1
    }

    private enum CodingKeys: String, CodingKey { case mode, text, opacity, customIconData, position, iconShape, sizeScale, iconPosition }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decodeIfPresent(WatermarkMode.self, forKey: .mode) ?? .lives,
                  text: try values.decodeIfPresent(String.self, forKey: .text) ?? "lives",
                  opacity: try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
                  customIconData: try values.decodeIfPresent(Data.self, forKey: .customIconData),
                  position: try values.decodeIfPresent(WatermarkPosition.self, forKey: .position) ?? .bottomCenter,
                  iconShape: try values.decodeIfPresent(WatermarkIconShape.self, forKey: .iconShape) ?? .rounded,
                  sizeScale: try values.decodeIfPresent(Double.self, forKey: .sizeScale) ?? 1,
                  iconPosition: try values.decodeIfPresent(WatermarkIconPosition.self, forKey: .iconPosition) ?? .leading)
    }

    public static let `default` = WatermarkSettings()
}

public struct CustomRatio: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CanvasSettings: Codable, Equatable, Sendable {
    public var aspectRatio: AspectRatioID
    public var quality: ExportQuality
    public var customRatio: CustomRatio?
    public var watermark: WatermarkSettings

    private enum CodingKeys: String, CodingKey {
        case aspectRatio
        case quality
        case customRatio
        case watermark
    }

    public init(
        aspectRatio: AspectRatioID = .portrait34,
        quality: ExportQuality = .p1080,
        customRatio: CustomRatio? = nil,
        watermark: WatermarkSettings = .default
    ) {
        self.aspectRatio = aspectRatio
        self.quality = quality
        self.customRatio = customRatio
        self.watermark = watermark
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio = try values.decodeIfPresent(AspectRatioID.self, forKey: .aspectRatio) ?? .portrait34
        quality = try values.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .p1080
        customRatio = try values.decodeIfPresent(CustomRatio.self, forKey: .customRatio)
        watermark = try values.decodeIfPresent(WatermarkSettings.self, forKey: .watermark) ?? .default
    }
}

public struct CanvasSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum CanvasGeometry {
    public static let customRatioBounds = (min: 1.0 / 3.0, max: 3.0)

    public static func normalize(_ ratio: CustomRatio) -> CustomRatio {
        let width = max(1, ratio.width)
        let height = max(1, ratio.height)
        let value = Double(width) / Double(height)
        if value > customRatioBounds.max {
            return CustomRatio(width: max(1, Int((Double(height) * customRatioBounds.max).rounded())), height: height)
        }
        if value < customRatioBounds.min {
            return CustomRatio(width: width, height: max(1, Int((Double(width) / customRatioBounds.min).rounded())))
        }
        return CustomRatio(width: width, height: height)
    }

    public static func size(for settings: CanvasSettings) -> CanvasSize {
        if settings.aspectRatio == .wallpaper {
            let wallpaper = normalize(settings.customRatio ?? CustomRatio(width: 1080, height: 1920))
            func even(_ value: Int) -> Int { max(2, value - value % 2) }
            return CanvasSize(width: even(wallpaper.width), height: even(wallpaper.height))
        }
        let ratio: (width: Int, height: Int)
        switch settings.aspectRatio {
        case .portrait916: ratio = (9, 16)
        case .portrait45: ratio = (4, 5)
        case .portrait57: ratio = (5, 7)
        case .portrait34: ratio = (3, 4)
        case .portrait35: ratio = (3, 5)
        case .portrait23: ratio = (2, 3)
        case .square: ratio = (1, 1)
        case .landscape32: ratio = (3, 2)
        case .landscape53: ratio = (5, 3)
        case .landscape43: ratio = (4, 3)
        case .landscape75: ratio = (7, 5)
        case .landscape54: ratio = (5, 4)
        case .landscape169: ratio = (16, 9)
        case .wallpaper, .custom:
            let custom = normalize(settings.customRatio ?? CustomRatio(width: 3, height: 4))
            ratio = (custom.width, custom.height)
        }
        let short = settings.quality.shortEdge
        let long = min(short * 3, Int((Double(short) * Double(max(ratio.width, ratio.height)) / Double(min(ratio.width, ratio.height))).rounded()))
        let evenLong = long.isMultiple(of: 2) ? long : long - 1
        return ratio.width <= ratio.height
            ? CanvasSize(width: short, height: max(short, evenLong))
            : CanvasSize(width: max(short, evenLong), height: short)
    }
}

public struct CropPosition: Codable, Equatable, Sendable {
    public var normalizedCenterX: Double
    public var normalizedCenterY: Double
    public var scale: Double

    public init(normalizedCenterX: Double = 0.5, normalizedCenterY: Double = 0.5, scale: Double = 1) {
        self.normalizedCenterX = min(1, max(0, normalizedCenterX))
        self.normalizedCenterY = min(1, max(0, normalizedCenterY))
        self.scale = min(3, max(1, scale))
    }
}

public enum SourceAssetKind: String, Codable, CaseIterable, Sendable {
    case video
    case photo
    case livePhoto

    public var isMotion: Bool {
        switch self {
        case .video, .livePhoto: true
        case .photo: false
        }
    }
}

/// Runtime resource URLs resolved by the platform adapter. PhotoKit stays out
/// of LivesCore; iOS and macOS only provide local files at this seam.
public enum ResolvedMediaSource: Sendable, Equatable {
    case video(URL)
    case photo(URL)
    case livePhoto(photoURL: URL, pairedVideoURL: URL)

    public var motionURL: URL? {
        switch self {
        case .video(let url), .livePhoto(_, let url): url
        case .photo: nil
        }
    }

    public var photoURL: URL? {
        switch self {
        case .video: nil
        case .photo(let url), .livePhoto(let url, _): url
        }
    }
}

public struct SourceAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var relativePath: String
    public var durationMs: Int
    public var width: Int
    public var height: Int
    public var codec: String
    public var kind: SourceAssetKind
    /// For a Live Photo this is the paired motion resource. It is nil for
    /// ordinary videos and photos.
    public var pairedRelativePath: String?
    public var hasAudio: Bool
    /// The key-photo time in the paired video, when the source exposed it.
    public var nativeCoverTimeMs: Int?
    /// Motion dimensions can differ from the still image dimensions of a Live
    /// Photo. Old video records default these to width/height.
    public var motionWidth: Int
    public var motionHeight: Int

    private enum CodingKeys: String, CodingKey {
        case id, displayName, relativePath, durationMs, width, height, codec
        case kind, pairedRelativePath, hasAudio, nativeCoverTimeMs
        case motionWidth, motionHeight
    }

    public init(
        id: UUID = UUID(), displayName: String, relativePath: String,
        durationMs: Int, width: Int, height: Int, codec: String,
        kind: SourceAssetKind = .video,
        pairedRelativePath: String? = nil,
        hasAudio: Bool = false,
        nativeCoverTimeMs: Int? = nil,
        motionWidth: Int? = nil,
        motionHeight: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.durationMs = max(0, durationMs)
        self.width = max(0, width)
        self.height = max(0, height)
        self.codec = codec
        self.kind = kind
        self.pairedRelativePath = pairedRelativePath
        self.hasAudio = hasAudio
        self.nativeCoverTimeMs = nativeCoverTimeMs.map { min(max(0, durationMs - 34), max(0, $0)) }
        self.motionWidth = max(0, motionWidth ?? width)
        self.motionHeight = max(0, motionHeight ?? height)
    }

    public init(
        id: UUID = UUID(), displayName: String, relativePath: String,
        width: Int, height: Int, contentType: String = "image"
    ) {
        self.init(
            id: id,
            displayName: displayName,
            relativePath: relativePath,
            durationMs: 0,
            width: width,
            height: height,
            codec: contentType,
            kind: .photo,
            hasAudio: false,
            motionWidth: 0,
            motionHeight: 0
        )
    }

    public init(
        id: UUID = UUID(), displayName: String,
        photoRelativePath: String, pairedVideoRelativePath: String,
        durationMs: Int, photoWidth: Int, photoHeight: Int,
        motionWidth: Int, motionHeight: Int, codec: String,
        hasAudio: Bool, nativeCoverTimeMs: Int? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            relativePath: photoRelativePath,
            durationMs: durationMs,
            width: photoWidth,
            height: photoHeight,
            codec: codec,
            kind: .livePhoto,
            pairedRelativePath: pairedVideoRelativePath,
            hasAudio: hasAudio,
            nativeCoverTimeMs: nativeCoverTimeMs,
            motionWidth: motionWidth,
            motionHeight: motionHeight
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        durationMs = max(0, try values.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0)
        width = max(0, try values.decodeIfPresent(Int.self, forKey: .width) ?? 0)
        height = max(0, try values.decodeIfPresent(Int.self, forKey: .height) ?? 0)
        codec = try values.decodeIfPresent(String.self, forKey: .codec) ?? "unknown"
        // A short-lived schema-v2 build wrote the paired path before it
        // persisted `kind`. Infer the stronger type for those drafts so a
        // previously imported Live Photo cannot silently become a video (or
        // a static image) after relaunch.
        pairedRelativePath = try values.decodeIfPresent(String.self, forKey: .pairedRelativePath)
        if let decodedKind = try values.decodeIfPresent(SourceAssetKind.self, forKey: .kind) {
            kind = decodedKind
        } else if let pairedRelativePath, !pairedRelativePath.isEmpty {
            kind = .livePhoto
        } else {
            kind = .video
        }
        hasAudio = try values.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        let maximumNativeTime = max(0, durationMs - 34)
        nativeCoverTimeMs = try values.decodeIfPresent(Int.self, forKey: .nativeCoverTimeMs)
            .map { min(maximumNativeTime, max(0, $0)) }
        motionWidth = max(0, try values.decodeIfPresent(Int.self, forKey: .motionWidth) ?? width)
        motionHeight = max(0, try values.decodeIfPresent(Int.self, forKey: .motionHeight) ?? height)
    }
}

public enum CoverSource: String, Codable, Sendable {
    case originalPhoto, videoFrame, legacy
}

public enum RenderDynamicRange: String, Codable, Sendable {
    case preserveHDR, sdr
}

public struct Placement: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceAssetID: UUID
    public var slotID: String
    public var startTimeMs: Int
    /// 标识尚未初始化的新选段；旧草稿的已有选段始终保留。
    public var segmentStartInitialized: Bool
    public var crop: CropPosition
    public var audioEnabled: Bool
    public var coverTimeMs: Int
    public var coverSource: CoverSource
    public var rotation: Int

    public var isTransposed: Bool {
        let r = (rotation % 360 + 360) % 360
        return r == 90 || r == 270
    }

    public func usesOriginalPhoto(asset: SourceAsset) -> Bool {
        if asset.kind == .photo { return true }
        guard asset.kind == .livePhoto else { return false }
        switch coverSource {
        case .originalPhoto: return true
        case .videoFrame: return false
        case .legacy:
            return asset.nativeCoverTimeMs.map { abs($0 - (startTimeMs + coverTimeMs)) <= 100 } ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceAssetID, slotID, startTimeMs, segmentStartInitialized
        case crop, audioEnabled, coverTimeMs, coverSource, rotation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceAssetID = try values.decode(UUID.self, forKey: .sourceAssetID)
        slotID = try values.decode(String.self, forKey: .slotID)
        startTimeMs = try values.decode(Int.self, forKey: .startTimeMs)
        segmentStartInitialized = try values.decodeIfPresent(Bool.self, forKey: .segmentStartInitialized)
            ?? true
        crop = try values.decode(CropPosition.self, forKey: .crop)
        audioEnabled = try values.decode(Bool.self, forKey: .audioEnabled)
        coverTimeMs = try values.decode(Int.self, forKey: .coverTimeMs)
        coverSource = try values.decodeIfPresent(CoverSource.self, forKey: .coverSource) ?? .legacy
        rotation = try values.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
    }

    public init(
        id: UUID = UUID(), sourceAssetID: UUID, slotID: String,
        startTimeMs: Int = 0, segmentStartInitialized: Bool = true,
        crop: CropPosition = CropPosition(),
        audioEnabled: Bool = false, coverTimeMs: Int = 1500, coverSource: CoverSource = .legacy,
        rotation: Int = 0
    ) {
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.slotID = slotID
        self.startTimeMs = max(0, startTimeMs)
        self.segmentStartInitialized = segmentStartInitialized
        self.crop = crop
        self.audioEnabled = audioEnabled
        self.coverSource = coverSource
        self.coverTimeMs = max(0, (coverTimeMs / 100) * 100)
        self.rotation = (rotation % 360 + 360) % 360
    }
}

public struct ProjectDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2
    public let id: UUID
    public var schemaVersion: Int
    public var name: String
    public var templateID: TemplateID
    public var canvas: CanvasSettings
    public var assets: [SourceAsset]
    public var placements: [Placement]
    public var updatedAt: Date
    public var outputDurationMs: Int
    /// 动态锁屏的动作曲线。自由拼图不做时间压缩，因此该值只在锁屏导出生效。
    public var motionCurve: WallpaperMotionCurve

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, templateID, canvas, assets, placements, updatedAt, outputDurationMs, motionCurve
    }

    public init(
        id: UUID = UUID(), name: String = "未命名作品", templateID: TemplateID = .single,
        canvas: CanvasSettings = CanvasSettings(), assets: [SourceAsset] = [],
        placements: [Placement] = [], updatedAt: Date = Date(), outputDurationMs: Int = 3000,
        motionCurve: WallpaperMotionCurve = .uniform
    ) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.templateID = templateID
        self.canvas = canvas
        self.assets = assets
        self.placements = placements
        self.updatedAt = updatedAt
        self.outputDurationMs = outputDurationMs
        self.motionCurve = motionCurve
        ProjectTimeline.normalizeCovers(&self)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Version 1 had video-only SourceAsset records. SourceAsset's decoder
        // supplies .video defaults; promote readable legacy drafts to v2 on
        // the next save while preserving future versions for validation.
        schemaVersion = storedVersion <= Self.currentSchemaVersion ? Self.currentSchemaVersion : storedVersion
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "未命名作品"
        templateID = try values.decodeIfPresent(TemplateID.self, forKey: .templateID) ?? .single
        canvas = try values.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? CanvasSettings()
        assets = try values.decodeIfPresent([SourceAsset].self, forKey: .assets) ?? []
        placements = try values.decodeIfPresent([Placement].self, forKey: .placements) ?? []
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        outputDurationMs = try values.decodeIfPresent(Int.self, forKey: .outputDurationMs) ?? 3000
        // 旧草稿没有该字段：匀速保持它们原本的导出时间安排。
        motionCurve = try values.decodeIfPresent(WallpaperMotionCurve.self, forKey: .motionCurve) ?? .uniform
        ProjectTimeline.normalizeCovers(&self)
    }
}

/// Controls how audio is handled during a render. The default keeps the
/// per-placement switches in the project document intact; `.muted` is an
/// ephemeral export override and never changes those switches.
public enum RenderAudioPolicy: String, Codable, Equatable, Sendable {
    case perPlacement
    case muted
}

public struct RenderRequest: Codable, Equatable, Sendable {
    public let project: ProjectDocument
    public let canvasSize: CanvasSize
    public let audioPolicy: RenderAudioPolicy
    public let coverSize: CanvasSize
    public let dynamicRange: RenderDynamicRange
    public let purpose: RenderPurpose

    private enum CodingKeys: String, CodingKey {
        case project
        case canvasSize
        case audioPolicy, coverSize, dynamicRange, purpose
    }

    public init(
        project: ProjectDocument,
        canvasSize: CanvasSize? = nil,
        audioPolicy: RenderAudioPolicy = .perPlacement,
        coverSize: CanvasSize? = nil,
        dynamicRange: RenderDynamicRange = .sdr,
        purpose: RenderPurpose = .livePhoto
    ) {
        self.project = project
        self.canvasSize = canvasSize ?? CanvasGeometry.size(for: project.canvas)
        self.audioPolicy = audioPolicy
        self.coverSize = coverSize ?? self.canvasSize
        self.dynamicRange = dynamicRange
        self.purpose = purpose
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decode(ProjectDocument.self, forKey: .project)
        canvasSize = try values.decode(CanvasSize.self, forKey: .canvasSize)
        coverSize = try values.decodeIfPresent(CanvasSize.self, forKey: .coverSize) ?? canvasSize
        dynamicRange = try values.decodeIfPresent(RenderDynamicRange.self, forKey: .dynamicRange) ?? .sdr
        purpose = try values.decodeIfPresent(RenderPurpose.self, forKey: .purpose) ?? .livePhoto
        // RenderRequest was persisted before the global mute override existed.
        // Missing data must retain the historical per-placement behavior.
        audioPolicy = try values.decodeIfPresent(RenderAudioPolicy.self, forKey: .audioPolicy) ?? .perPlacement
    }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public let durationMs: Int
    public let width: Int
    public let height: Int
    public let codec: String
    public let hasAudio: Bool
    public let nativeCoverTimeMs: Int?

    public init(durationMs: Int, width: Int, height: Int, codec: String, hasAudio: Bool, nativeCoverTimeMs: Int? = nil) {
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.codec = codec
        self.hasAudio = hasAudio
        self.nativeCoverTimeMs = nativeCoverTimeMs
    }
}

public struct TemplateSlot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let labelKey: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(id: String, labelKey: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.labelKey = labelKey
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TemplateDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: TemplateID
    public let nameKey: String
    public let requiredAssetCount: Int
    public let slots: [TemplateSlot]

    public init(id: TemplateID, nameKey: String, requiredAssetCount: Int, slots: [TemplateSlot]) {
        self.id = id
        self.nameKey = nameKey
        self.requiredAssetCount = requiredAssetCount
        self.slots = slots
    }

    public func rect(for slotID: String, canvas: CGSize) throws -> CGRect {
        guard let slot = slots.first(where: { $0.id == slotID }) else {
            throw LivesCoreError.invalidSlot(slotID)
        }
        return CGRect(x: slot.x * canvas.width, y: slot.y * canvas.height,
                      width: slot.width * canvas.width, height: slot.height * canvas.height)
    }
}

public enum TemplateCatalog {
    public static let all: [TemplateDefinition] = [
        TemplateDefinition(id: .single, nameKey: "template.single", requiredAssetCount: 1,
                           slots: [slot("full", "slot.main", 0, 0, 1, 1)]),
        TemplateDefinition(id: .stack2, nameKey: "template.stack2", requiredAssetCount: 2,
                           slots: [slot("top", "slot.top", 0, 0, 1, 0.5), slot("bottom", "slot.bottom", 0, 0.5, 1, 0.5)]),
        TemplateDefinition(id: .side2, nameKey: "template.side2", requiredAssetCount: 2,
                           slots: [slot("left", "slot.left", 0, 0, 0.5, 1), slot("right", "slot.right", 0.5, 0, 0.5, 1)]),
        TemplateDefinition(id: .stack3, nameKey: "template.stack3", requiredAssetCount: 3,
                           slots: [slot("top", "slot.top", 0, 0, 1, 1.0 / 3.0), slot("middle", "slot.middle", 0, 1.0 / 3.0, 1, 1.0 / 3.0), slot("bottom", "slot.bottom", 0, 2.0 / 3.0, 1, 1.0 / 3.0)]),
        TemplateDefinition(id: .side3, nameKey: "template.side3", requiredAssetCount: 3,
                           slots: [slot("left", "slot.left", 0, 0, 1.0 / 3.0, 1), slot("center", "slot.center", 1.0 / 3.0, 0, 1.0 / 3.0, 1), slot("right", "slot.right", 2.0 / 3.0, 0, 1.0 / 3.0, 1)]),
        TemplateDefinition(id: .heroLeft, nameKey: "template.heroLeft", requiredAssetCount: 3,
                           slots: [slot("hero-left", "slot.hero", 0, 0, 2.0 / 3.0, 1), slot("right-top", "slot.top", 2.0 / 3.0, 0, 1.0 / 3.0, 0.5), slot("right-bottom", "slot.bottom", 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.5)]),
        TemplateDefinition(id: .heroTop, nameKey: "template.heroTop", requiredAssetCount: 3,
                           slots: [slot("hero-top", "slot.hero", 0, 0, 1, 2.0 / 3.0), slot("bottom-left", "slot.left", 0, 2.0 / 3.0, 0.5, 1.0 / 3.0), slot("bottom-right", "slot.right", 0.5, 2.0 / 3.0, 0.5, 1.0 / 3.0)]),
        TemplateDefinition(id: .weighted3, nameKey: "template.weighted3", requiredAssetCount: 3,
                           slots: [slot("large", "slot.large", 0, 0, 1, 0.5), slot("medium", "slot.medium", 0, 0.5, 1, 0.3), slot("small", "slot.small", 0, 0.8, 1, 0.2)]),
        TemplateDefinition(id: .grid4, nameKey: "template.grid4", requiredAssetCount: 4,
                           slots: [
                            slot("top-left", "slot.topLeft", 0, 0, 0.5, 0.5),
                            slot("top-right", "slot.topRight", 0.5, 0, 0.5, 0.5),
                            slot("bottom-left", "slot.bottomLeft", 0, 0.5, 0.5, 0.5),
                            slot("bottom-right", "slot.bottomRight", 0.5, 0.5, 0.5, 0.5),
                           ]),
    ]

    public static func definition(for id: TemplateID) -> TemplateDefinition {
        all.first(where: { $0.id == id })!
    }

    private static func slot(_ id: String, _ labelKey: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> TemplateSlot {
        TemplateSlot(id: id, labelKey: labelKey, x: x, y: y, width: width, height: height)
    }
}

public enum LivesCoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFileType
    case sourceTooShort
    case invalidLivePhoto
    case invalidProject(String)
    case invalidSlot(String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType: return "暂不支持这个素材格式"
        case .sourceTooShort: return "视频至少需要 1 秒"
        case .invalidLivePhoto: return "Live Photo 缺少匹配的照片或动态资源"
        case .invalidProject(let value): return value
        case .invalidSlot(let value): return "找不到画格：\(value)"
        case .renderFailed(let value): return value
        }
    }
}

public enum ProjectValidation {
    public static let outputDurationMs = 3_000
    public static let minimumSourceDurationMs = 1_000

    public static func validate(_ project: ProjectDocument) throws {
        let definition = TemplateCatalog.definition(for: project.templateID)
        guard (100...ProjectTimeline.durationBounds(for: project).upperBound).contains(project.outputDurationMs), project.outputDurationMs % 100 == 0 else {
            throw LivesCoreError.invalidProject("Live 时长超出有效范围，精度必须为 0.1 秒")
        }
        guard project.schemaVersion == ProjectDocument.currentSchemaVersion else {
            throw LivesCoreError.invalidProject("项目版本不受支持")
        }
        guard project.placements.count == definition.requiredAssetCount else {
            throw LivesCoreError.invalidProject("素材数量与模板不匹配")
        }
        guard Set(project.placements.map(\.slotID)).count == definition.requiredAssetCount else {
            throw LivesCoreError.invalidProject("模板画格不能重复")
        }
        let assetIDs = Set(project.assets.map(\.id))
        for placement in project.placements {
            guard assetIDs.contains(placement.sourceAssetID), definition.slots.contains(where: { $0.id == placement.slotID }) else {
                throw LivesCoreError.invalidProject("画格素材引用无效")
            }
            guard let asset = project.assets.first(where: { $0.id == placement.sourceAssetID }) else {
                throw LivesCoreError.invalidProject("画格素材引用无效")
            }
            switch asset.kind {
            case .photo:
                guard asset.width > 0, asset.height > 0 else {
                    throw LivesCoreError.invalidProject("照片尺寸无效")
                }
            case .video:
                guard asset.durationMs >= minimumSourceDurationMs else {
                    throw LivesCoreError.sourceTooShort
                }
            case .livePhoto:
                guard asset.durationMs > 0,
                      asset.width > 0, asset.height > 0,
                      asset.motionWidth > 0, asset.motionHeight > 0,
                      let paired = asset.pairedRelativePath,
                      !paired.isEmpty else {
                    throw LivesCoreError.invalidLivePhoto
                }
            }
        }
    }

    public static func contentDurationMs(sourceDurationMs: Int, startTimeMs: Int, outputDurationMs: Int = 3000) -> Int {
        min(outputDurationMs, max(0, sourceDurationMs - max(0, startTimeMs)))
    }

    public static func paddingDurationMs(sourceDurationMs: Int, startTimeMs: Int, outputDurationMs: Int = 3000) -> Int {
        max(0, outputDurationMs - contentDurationMs(sourceDurationMs: sourceDurationMs, startTimeMs: startTimeMs, outputDurationMs: outputDurationMs))
    }
}
