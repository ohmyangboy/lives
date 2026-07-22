import Foundation

enum MediaConstraints {
    static let outputDurationMilliseconds = 3_000
    static let minimumSourceDurationMilliseconds = 2_500

    struct SegmentDurations: Equatable {
        let contentMilliseconds: Int
        let paddingMilliseconds: Int
    }

    static func segmentDurations(
        sourceDurationMilliseconds: Int,
        startTimeMilliseconds: Int,
        outputDurationMilliseconds: Int = MediaConstraints.outputDurationMilliseconds
    ) -> SegmentDurations {
        let available = max(0, sourceDurationMilliseconds - max(0, startTimeMilliseconds))
        let content = min(outputDurationMilliseconds, available)
        return SegmentDurations(
            contentMilliseconds: content,
            paddingMilliseconds: max(0, outputDurationMilliseconds - content)
        )
    }
}
