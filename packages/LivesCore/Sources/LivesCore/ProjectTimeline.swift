import Foundation

/// 所有时间均为毫秒。左右柄传绝对素材时间，平移传新的起点。
public enum SegmentEdge: Sendable {
    case leading, trailing, move
}

public enum ProjectTimeline {
    public static let minimumDurationMs = 1000
    public static let maximumDurationMs = 3_900
    public static let exportDurationBounds: ClosedRange<Int> = minimumDurationMs...maximumDurationMs

    public static func maximumStartMs(sourceDurationMs: Int) -> Int {
        max(0, sourceDurationMs - 34) / 100 * 100
    }

    /// 新建动态素材的默认选段起点：让可移动的选段窗口落在素材中段。
    /// 素材不足一个输出时长时没有可移动范围，因此从 0 开始。
    public static func defaultStartTimeMs(sourceDurationMs: Int, outputDurationMs: Int) -> Int {
        let maximum = max(0, sourceDurationMs - max(0, outputDurationMs))
        return maximum / 2
    }

    /// 只初始化明确标记为待初始化的选段，保留旧草稿和用户主动选择的 0 起点。
    @discardableResult
    public static func initializeDefaultStartTimes(_ project: inout ProjectDocument) -> Bool {
        var changed = false
        for index in project.placements.indices {
            guard !project.placements[index].segmentStartInitialized,
                  let asset = project.assets.first(where: {
                      $0.id == project.placements[index].sourceAssetID
                  }) else { continue }
            if asset.kind.isMotion {
                project.placements[index].startTimeMs = defaultStartTimeMs(
                    sourceDurationMs: asset.durationMs,
                    outputDurationMs: project.outputDurationMs
                )
            }
            project.placements[index].segmentStartInitialized = true
            changed = true
        }
        if changed { normalizeCovers(&project) }
        return changed
    }

    public static func maximumCoverMs(sourceDurationMs: Int, startTimeMs: Int, outputDurationMs: Int) -> Int {
        max(0, min(outputDurationMs - 100, sourceDurationMs - startTimeMs - 34)) / 100 * 100
    }

    /// 当前拼图内动态素材的原始时长决定下限；上限统一为 3.9 秒。
    public static func durationBounds(for project: ProjectDocument) -> ClosedRange<Int> {
        let used = Set(project.placements.map(\.sourceAssetID))
        guard let shortest = project.assets.filter({ used.contains($0.id) && $0.kind.isMotion && $0.durationMs > 0 })
            .map(\.durationMs).min() else { return minimumDurationMs...maximumDurationMs }
        let minimum = min(maximumDurationMs, max(100, Int(ceil(Double(shortest) / 100)) * 100))
        return minimum...maximumDurationMs
    }

    public static func defaultDurationMs(in bounds: ClosedRange<Int>) -> Int {
        min(bounds.upperBound, max(bounds.lowerBound, 3000))
    }

    public static func canExport(durationMs: Int, pro _: Bool, bounds: ClosedRange<Int> = ProjectTimeline.exportDurationBounds) -> Bool {
        bounds.contains(durationMs) && durationMs % 100 == 0
    }

    public static func normalizeCovers(_ project: inout ProjectDocument) {
        guard project.outputDurationMs >= 100 else { return }
        for index in project.placements.indices {
            let placement = project.placements[index]
            guard let asset = project.assets.first(where: { $0.id == placement.sourceAssetID }) else { continue }
            let maximum = asset.kind == .photo ? project.outputDurationMs - 100 : maximumCoverMs(
                sourceDurationMs: asset.durationMs, startTimeMs: placement.startTimeMs,
                outputDurationMs: project.outputDurationMs
            )
            project.placements[index].coverTimeMs = min(maximum, max(0, placement.coverTimeMs / 100 * 100))
        }
    }

    public static func adjust(_ project: inout ProjectDocument, slotID: String, edge: SegmentEdge, valueMs: Double, bounds: ClosedRange<Int> = ProjectTimeline.exportDurationBounds) {
        guard valueMs.isFinite,
              let index = project.placements.firstIndex(where: { $0.slotID == slotID }),
              let asset = project.assets.first(where: { $0.id == project.placements[index].sourceAssetID }),
              asset.kind != .photo, asset.durationMs > 0 else { return }
        let minimumDurationMs = bounds.lowerBound
        let maximumDurationMs = bounds.upperBound
        let old = project.placements[index]
        let end = old.startTimeMs + project.outputDurationMs
        let maximumStart = maximumStartMs(sourceDurationMs: asset.durationMs)
        let value = Int((min(Double(maximumStart + maximumDurationMs), max(0, valueMs)) / 100).rounded()) * 100
        switch edge {
        case .leading:
            // 旧草稿的起点可能不是 100ms 的整数倍；按时长量化，保留固定右端。
            let minimum = max(minimumDurationMs, Int(ceil(Double(end - maximumStart) / 100)) * 100)
            let maximum = min(maximumDurationMs, end / 100 * 100)
            guard minimum <= maximum else { return }
            let duration = min(maximum, max(minimum, Int(((Double(end) - min(Double(end + maximumDurationMs), max(0, valueMs))) / 100).rounded()) * 100))
            let start = end - duration
            project.placements[index].startTimeMs = start
            project.outputDurationMs = duration
            project.placements[index].coverTimeMs = max(0, old.startTimeMs + old.coverTimeMs - start)
        case .trailing:
            let duration = Int(((min(Double(old.startTimeMs + maximumDurationMs), max(0, valueMs)) - Double(old.startTimeMs)) / 100).rounded()) * 100
            project.outputDurationMs = min(maximumDurationMs, max(minimumDurationMs, duration))
        case .move:
            project.placements[index].startTimeMs = min(maximumStart, value)
        }
        project.placements[index].segmentStartInitialized = true
        normalizeCovers(&project)
    }
}
