import XCTest
@testable import LivesCore

final class CropGeometryTests: XCTestCase {
    func testEveryTemplateAndRatioStaysCoveredAtAllCropExtremes() throws {
        for ratio in AspectRatioID.allCases {
            let canvas = CanvasGeometry.size(for: CanvasSettings(aspectRatio: ratio))
            for template in TemplateCatalog.all {
                for slot in template.slots {
                    let target = try template.rect(for: slot.id, canvas: CGSize(width: canvas.width, height: canvas.height))
                    for source in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1000, height: 1000)] {
                        for scale in [1.0, 1.5, 3.0] {
                            for x in [0.0, 0.5, 1.0] {
                                for y in [0.0, 0.5, 1.0] {
                                    let rect = CropGeometry.drawnRect(source: source, target: target, crop: CropPosition(normalizedCenterX: x, normalizedCenterY: y, scale: scale))
                                    XCTAssertLessThanOrEqual(rect.minX, target.minX + 0.001)
                                    XCTAssertLessThanOrEqual(rect.minY, target.minY + 0.001)
                                    XCTAssertGreaterThanOrEqual(rect.maxX, target.maxX - 0.001)
                                    XCTAssertGreaterThanOrEqual(rect.maxY, target.maxY - 0.001)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testZoomingBackToFitRecentersTheNonScrollableAxis() {
        let crop = CropPosition(normalizedCenterX: 0, normalizedCenterY: 1, scale: 1)
        let safe = CropGeometry.clamped(crop, source: CGSize(width: 640, height: 360), target: CGSize(width: 200, height: 200))
        XCTAssertEqual(safe.normalizedCenterY, 0.5)
        XCTAssertEqual(safe.normalizedCenterX, 0.28125)
    }
}
