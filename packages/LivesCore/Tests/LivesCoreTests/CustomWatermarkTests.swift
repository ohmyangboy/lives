import XCTest
import ImageIO
@testable import LivesCore

final class CustomWatermarkTests: XCTestCase {
    func testLegacyDraftBecomesOpaqueAndNewSettingsRoundTrip() throws {
        let legacy = Data(#"{"mode":"custom","text":"旧水印"}"#.utf8)
        var settings = try JSONDecoder().decode(WatermarkSettings.self, from: legacy)
        XCTAssertEqual(settings.opacity, 1)
        XCTAssertEqual(settings.position, .bottomCenter)
        XCTAssertEqual(settings.iconShape, .rounded)
        XCTAssertEqual(settings.sizeScale, 1)
        XCTAssertEqual(settings.iconPosition, .leading)
        XCTAssertNil(settings.customIconData)
        settings.customIconData = try iconPNG()
        settings.position = .bottomRight
        settings.iconShape = .circle
        settings.sizeScale = 1.75
        settings.iconPosition = .trailing
        settings.opacity = 0.35
        XCTAssertEqual(try JSONDecoder().decode(WatermarkSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testTrailingIconMovesAfterTextAndEmptyIconKeepsTextLayout() throws {
        let icon = try iconPNG()
        for position in WatermarkPosition.allCases {
            let leading = WatermarkSettings(mode: .custom, text: "Paper RSS", customIconData: icon, position: position)
            var trailing = leading
            trailing.iconPosition = .trailing
            func greenCenter(_ settings: WatermarkSettings) throws -> Double {
                let pixels = try render(settings)
                let green = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] > 200 && pixels[$0] < 30 }
                XCTAssertFalse(green.isEmpty)
                return green.map { Double(($0 / 4) % 360) }.reduce(0, +) / Double(green.count)
            }
            XCTAssertGreaterThan(try greenCenter(trailing), try greenCenter(leading) + 20)
            trailing.customIconData = nil
            var noIcon = trailing
            noIcon.iconPosition = .leading
            XCTAssertEqual(try render(trailing), try render(noIcon))
        }
    }

    func testWatermarkShadowRemainsVisibleOnWhiteAndFillOnBlack() throws {
        let pixels = try render(WatermarkSettings(mode: .custom, text: "lives 水印"))
        let offsets = stride(from: 0, to: pixels.count, by: 4)
        // 透明层以预乘 alpha 存储；叠到白底后，短阴影应提供背景分离。
        let darkOnWhite = offsets.filter { Int(pixels[$0]) + 255 - Int(pixels[$0 + 3]) < 230 }
        let lightOnBlack = offsets.filter { pixels[$0] > 230 && pixels[$0 + 3] > 230 }
        XCTAssertGreaterThan(darkOnWhite.count, 20)
        XCTAssertGreaterThan(lightOnBlack.count, 20)
        XCTAssertEqual(WatermarkTypography.tracking(for: "中文水印", fontSize: 14), 0)
        XCTAssertEqual(WatermarkTypography.tracking(for: "lives", fontSize: 14), 0.28, accuracy: 0.001)
    }

    func testSizeBoundsAndExportedIconScale() throws {
        XCTAssertEqual(WatermarkSettings(mode: .custom, sizeScale: 0.1).effectiveSizeScale, 0.5)
        XCTAssertEqual(WatermarkSettings(mode: .custom, sizeScale: 5).effectiveSizeScale, 2)
        XCTAssertEqual(WatermarkSettings(mode: .custom, sizeScale: .nan).effectiveSizeScale, 1)
        let icon = try iconPNG()
        let counts = try [0.5, 1.0, 2.0].map { scale in
            let pixels = try render(WatermarkSettings(mode: .custom, text: "水印", customIconData: icon,
                iconShape: .square, sizeScale: scale))
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] > 200 && pixels[$0] < 30 }.count
        }
        // 亚像素边缘会影响纯绿色像素计数，等效边长允许一个像素的抗锯齿误差。
        for (count, expectedSide) in zip(counts, [7.0, 14.0, 28.0]) {
            XCTAssertEqual(Double(count).squareRoot(), expectedSide, accuracy: 1.1)
        }
    }

    func testCustomIconCornerShapesChangeExportedPixels() throws {
        let icon = try iconPNG()
        let counts = try WatermarkIconShape.allCases.map { shape in
            let pixels = try render(WatermarkSettings(mode: .custom, text: "水印", customIconData: icon, iconShape: shape))
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] > 200 && pixels[$0] < 30 }.count
        }
        XCTAssertGreaterThan(counts[0], counts[1])
        XCTAssertGreaterThan(counts[1], counts[2])
    }

    func testCustomIconPositionsRenderAtAllAnchors() throws {
        let icon = try iconPNG()
        var centers: [Double] = []
        for position in WatermarkPosition.allCases {
            let settings = WatermarkSettings(mode: .custom, text: "水印", customIconData: icon, position: position)
            let pixels = try render(settings)
            let green = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] > 200 && pixels[$0] < 30 }
            XCTAssertGreaterThan(green.count, 20)
            XCTAssertTrue(green.contains { pixels[$0 + 3] == 255 })
            centers.append(green.map { Double(($0 / 4) % 360) }.reduce(0, +) / Double(green.count))
        }
        XCTAssertLessThan(centers[0], 35)
        XCTAssertGreaterThan(centers[1], 120)
        XCTAssertGreaterThan(centers[2], 280)
        let textOnly = try render(WatermarkSettings(mode: .custom, text: "水印"))
        XCTAssertFalse(stride(from: 0, to: textOnly.count, by: 4).contains { textOnly[$0 + 1] > 200 && textOnly[$0] < 30 })
        XCTAssertEqual(textOnly.max(), 255)
    }

    func testOpacityBoundsAndRenderedAlpha() throws {
        XCTAssertEqual(WatermarkSettings(mode: .custom, opacity: 0.02).effectiveOpacity, 0.1)
        XCTAssertEqual(WatermarkSettings(mode: .custom, opacity: 5).effectiveOpacity, 1)
        XCTAssertEqual(WatermarkSettings(mode: .custom, opacity: .nan).effectiveOpacity, 1)
        let opaque = try render(WatermarkSettings(mode: .custom, text: "水印"))
        XCTAssertGreaterThan(maxAlpha(opaque), 250)
        // 预乘 alpha 输出：50% 透明度的水印不应再出现完全不透明的像素。
        let half = try render(WatermarkSettings(mode: .custom, text: "水印", opacity: 0.5))
        XCTAssertGreaterThan(maxAlpha(half), 100, "半透明水印仍应可见")
        XCTAssertLessThan(maxAlpha(half), 160, "透明度必须真实作用于渲染输出")
        // 投影随透明度同步衰减，不能比水印本体更醒目。
        XCTAssertLessThanOrEqual(maxAlpha(half), maxAlpha(opaque))
    }

    func testLivesWatermarkHonorsLayoutAndTransparency() throws {
        XCTAssertEqual(WatermarkSettings(mode: .lives, sizeScale: 2).effectiveSizeScale, 2)
        XCTAssertEqual(WatermarkSettings(mode: .lives, opacity: 0.2).effectiveOpacity, 0.2)
        func whiteCenterX(_ settings: WatermarkSettings) throws -> Double {
            let pixels = try render(settings)
            let white = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 230 && pixels[$0 + 3] > 230 }
            XCTAssertFalse(white.isEmpty)
            return white.map { Double(($0 / 4) % 360) }.reduce(0, +) / Double(white.count)
        }
        let centered = try whiteCenterX(WatermarkSettings(mode: .lives))
        XCTAssertLessThan(try whiteCenterX(WatermarkSettings(mode: .lives, position: .bottomLeft)), centered - 20)
        XCTAssertGreaterThan(try whiteCenterX(WatermarkSettings(mode: .lives, position: .bottomRight)), centered + 20)
        let leading = try render(WatermarkSettings(mode: .lives))
        XCTAssertNotEqual(leading, try render(WatermarkSettings(mode: .lives, iconPosition: .trailing)))
        let half = try render(WatermarkSettings(mode: .lives, opacity: 0.5))
        XCTAssertGreaterThan(maxAlpha(half), 100, "半透明默认水印仍应可见")
        XCTAssertLessThan(maxAlpha(half), 160, "透明度必须作用于默认水印渲染")
    }

    func testWatermarkOpticalCenterUsesFortyFivePercentIconWeight() {
        XCTAssertEqual(WatermarkLayout.iconOpticalWeight, 0.45, accuracy: 0.001)
        let leading = WatermarkLayout.opticalCenterOffset(
            textWidth: 40, iconSize: 14, spacing: 4, iconPosition: .leading
        )
        let trailing = WatermarkLayout.opticalCenterOffset(
            textWidth: 40, iconSize: 14, spacing: 4, iconPosition: .trailing
        )
        XCTAssertEqual(leading, -trailing, accuracy: 0.001)
        XCTAssertGreaterThan(leading, 0)
        XCTAssertLessThan(trailing, 0)
    }

    private func maxAlpha(_ pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0 + 3]) }.max() ?? 0
    }

    private func render(_ settings: WatermarkSettings) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 360, height: 120, bitsPerComponent: 8,
            bytesPerRow: 1440, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        LivesMediaEngine.drawWatermark(settings: settings, canvas: CGSize(width: 360, height: 120), context: context)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 1440 * 120))
    }

    private func iconPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
