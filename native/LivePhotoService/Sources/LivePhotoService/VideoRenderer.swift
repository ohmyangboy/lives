import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum VideoRenderer {
    static func adaptiveBitRate(width: Int, height: Int) -> Int {
        let referencePixels = 1080.0 * 1920.0
        let outputPixels = Double(width * height)
        return max(4_000_000, min(12_000_000, Int(12_000_000 * outputPixels / referencePixels)))
    }

    static func render(
        project: RenderProject,
        outputURL: URL,
        contentIdentifier: String,
        cancellations: CancellationRegistry,
        progress: @escaping (Double) async -> Void
    ) async throws {
        let composition = AVMutableComposition()
        let canvasSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        var compositionAudioTracks: [AVMutableCompositionTrack] = []

        for clip in project.clips.reversed() {
            try await cancellations.check(project.id)
            let asset = AVURLAsset(url: URL(fileURLWithPath: clip.sourcePath))
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first,
                  let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ServiceError(code: "VIDEO_READ_FAILED", message: "无法读取一段视频", recovery: "请替换对应素材")
            }
            let start = CMTime(value: CMTimeValue(clip.startTimeMs), timescale: 1000)
            let duration = CMTime(value: CMTimeValue(project.canvas.durationMs), timescale: 1000)
            try compositionTrack.insertTimeRange(CMTimeRange(start: start, duration: duration), of: sourceTrack, at: .zero)

            let size = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)
            let target = try TemplateLayout.rect(for: clip.targetSlotId, templateId: project.templateId, canvas: canvasSize)
            let transform = TemplateLayout.aspectFillTransform(
                naturalSize: size,
                preferredTransform: preferredTransform,
                target: target,
                centerX: clip.crop.normalizedCenterX,
                centerY: clip.crop.normalizedCenterY,
                userScale: clip.crop.scale
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            layer.setTransform(transform, at: .zero)
            // AVFoundation expects the crop rectangle in the source track's
            // clean-aperture coordinate space. Convert the target cell back
            // through the aspect-fill transform before applying the crop.
            let sourceCrop = TemplateLayout.sourceCropRectangle(
                target: target,
                transform: transform,
                naturalSize: size
            )
            layer.setCropRectangle(sourceCrop, at: .zero)
            layerInstructions.append(layer)

            if clip.audioEnabled,
               let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudioTrack.insertTimeRange(CMTimeRange(start: start, duration: duration), of: sourceAudioTrack, at: .zero)
                compositionAudioTracks.append(compositionAudioTrack)
            }
        }

        guard !layerInstructions.isEmpty else {
            throw ServiceError(code: "INVALID_PROJECT", message: "项目中没有可用视频", recovery: "请先添加视频")
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(project.canvas.durationMs), timescale: 1000))
        instruction.layerInstructions = layerInstructions
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.canvas.fps))

        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw ServiceError(code: "RENDER_FAILED", message: "无法建立视频合成任务", recovery: "请重试或更换素材")
        }
        reader.add(readerOutput)

        let audioReader: AVAssetReader?
        let audioOutput: AVAssetReaderAudioMixOutput?
        if compositionAudioTracks.isEmpty {
            audioReader = nil
            audioOutput = nil
        } else {
            let reader = try AVAssetReader(asset: composition)
            let audioMix = AVMutableAudioMix()
            // Several independently enabled cells are mixed at a lower level
            // so a collage stays comfortable instead of clipping.
            let volume: Float = compositionAudioTracks.count > 1 ? 0.58 : 1
            audioMix.inputParameters = compositionAudioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(volume, at: .zero)
                return parameters
            }
            let output = AVAssetReaderAudioMixOutput(audioTracks: compositionAudioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
            ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ServiceError(code: "RENDER_FAILED", message: "无法建立音频合成任务", recovery: "请改为静音或更换素材")
            }
            reader.add(output)
            audioReader = reader
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let contentMetadata = AVMutableMetadataItem()
        contentMetadata.identifier = .quickTimeMetadataContentIdentifier
        contentMetadata.value = contentIdentifier as NSString
        writer.metadata = [contentMetadata]

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: project.canvas.width,
                AVVideoHeightKey: project.canvas.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: adaptiveBitRate(width: project.canvas.width, height: project.canvas.height),
                    AVVideoExpectedSourceFrameRateKey: project.canvas.fps,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ServiceError(code: "RENDER_FAILED", message: "系统无法使用 H.264 编码", recovery: "请释放系统资源后重试")
        }
        writer.add(videoInput)

        let audioInput: AVAssetWriterInput?
        if audioOutput == nil {
            audioInput = nil
        } else {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ServiceError(code: "RENDER_FAILED", message: "系统无法写入 Live Photo 音频", recovery: "请改为静音后重试")
            }
            writer.add(input)
            audioInput = input
        }

        let (metadataInput, metadataAdaptor) = try makeStillImageMetadataInput()
        guard writer.canAdd(metadataInput) else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法写入 Live Photo 时间信息", recovery: "请重试")
        }
        writer.add(metadataInput)

        guard writer.startWriting(), reader.startReading(), audioReader?.startReading() ?? true else {
            throw writer.error ?? reader.error ?? audioReader?.error ?? ServiceError(code: "RENDER_FAILED", message: "无法开始生成视频", recovery: "请重试")
        }
        writer.startSession(atSourceTime: .zero)

        let audioWritingTask: Task<Void, Error>?
        if let audioOutput, let audioInput {
            audioWritingTask = Task {
                while let sample = audioOutput.copyNextSampleBuffer() {
                    try await cancellations.check(project.id)
                    while !audioInput.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    guard audioInput.append(sample) else {
                        throw writer.error ?? ServiceError(code: "RENDER_FAILED", message: "写入音频失败", recovery: "请改为静音后重试")
                    }
                }
                audioInput.markAsFinished()
            }
        } else {
            audioWritingTask = nil
        }

        let stillItem = AVMutableMetadataItem()
        stillItem.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        stillItem.dataType = "com.apple.metadata.datatype.int8"
        stillItem.value = NSNumber(value: Int8(0))
        let coverTime = CMTime(value: CMTimeValue(project.coverTimeMs), timescale: 1000)
        let metadataGroup = AVTimedMetadataGroup(items: [stillItem], timeRange: CMTimeRange(start: coverTime, duration: CMTime(value: 1, timescale: 30)))
        guard metadataAdaptor.append(metadataGroup) else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法写入 Live Photo 封面时间", recovery: "请重试")
        }
        metadataInput.markAsFinished()

        let durationSeconds = Double(project.canvas.durationMs) / 1000
        while reader.status == .reading {
            try await cancellations.check(project.id)
            if videoInput.isReadyForMoreMediaData {
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                guard videoInput.append(sample) else { throw writer.error ?? ServiceError(code: "RENDER_FAILED", message: "写入视频帧失败", recovery: "请重试") }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                await progress(min(0.92, max(0.02, seconds / durationSeconds)))
            } else {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        videoInput.markAsFinished()
        try await audioWritingTask?.value
        if reader.status == .failed { throw reader.error ?? ServiceError(code: "RENDER_FAILED", message: "读取视频帧失败", recovery: "请更换素材") }
        if audioReader?.status == .failed { throw audioReader?.error ?? ServiceError(code: "RENDER_FAILED", message: "读取音频失败", recovery: "请改为静音后重试") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ServiceError(code: "RENDER_FAILED", message: "视频生成失败", recovery: "请重试") }
        await progress(1)
    }

    private static func makeStillImageMetadataInput() throws -> (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor) {
        let specification: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
        ]]
        var formatDescription: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specification as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法创建 Live Photo 元数据轨", recovery: "请重试")
        }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
        return (input, AVAssetWriterInputMetadataAdaptor(assetWriterInput: input))
    }
}
