import AVFoundation
import ImageIO
import XCTest
@testable import LivesCore

final class CropRenderTests: XCTestCase {
    func testExtremeCropsNeverExposeBlackOrBleedAcrossSlots() async throws {
        try await verifyPair(names: ["red.mp4", "green.mp4"])
    }

    func testRotatedInputsStayClippedToTheirSlots() async throws {
        try await verifyPair(names: ["red-rotated.mov", "green-rotated.mov"])
    }

    private func verifyPair(names: [String]) async throws {
        guard let root = ProcessInfo.processInfo.environment["LIVES_CROP_FIXTURES"] else {
            throw XCTSkip("设置 LIVES_CROP_FIXTURES 指向 red.mp4/green.mp4 合成测试素材")
        }
        let urls = names.map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        let assets = urls.map { SourceAsset(displayName: $0.lastPathComponent, relativePath: $0.path, durationMs: 3000, width: 640, height: 360, codec: "avc1") }
        let placements = [
            Placement(sourceAssetID: assets[0].id, slotID: "top", crop: CropPosition(normalizedCenterX: 0, normalizedCenterY: 0)),
            Placement(sourceAssetID: assets[1].id, slotID: "bottom", crop: CropPosition(normalizedCenterX: 1, normalizedCenterY: 1))
        ]
        let document = ProjectDocument(templateID: .stack2, canvas: CanvasSettings(quality: .p720), assets: assets, placements: placements)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let pair = try await LivesMediaEngine.render(request: RenderRequest(project: document), resolvedURLs: Dictionary(uniqueKeysWithValues: zip(assets.map(\.id), urls)), outputDirectory: output)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil))
        let cover = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        assertSlots(cover)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: pair.videoURL))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        assertSlots(frame.image)
    }

    private func assertSlots(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for y in [2, h/4, h/2-3, h/2+3, h*3/4, h-3] {
            for x in [2, w/2, w-3] {
                let i = (y*w+x)*4
                let red = Int(bytes[i]), green = Int(bytes[i+1])
                if y < h/2 {
                    XCTAssertGreaterThan(red, 180, "封面/视频上画格不能出现黑边或被下画格覆盖：\(x),\(y)", file:file,line:line)
                    XCTAssertLessThan(green, 70, file:file,line:line)
                } else {
                    XCTAssertGreaterThan(green, 180, "封面/视频下画格不能出现黑边：\(x),\(y)", file:file,line:line)
                    XCTAssertLessThan(red, 70, file:file,line:line)
                }
            }
        }
    }
}
