import XCTest
@testable import LivePhotoService

final class SharedCoreBridgeTests: XCTestCase {
    func testMacProjectUsesLivesCoreValidation() throws {
        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "single",
            canvas: .init(width: 1080, height: 1920, fps: 30, durationMs: 3000),
            clips: [
                .init(
                    id: UUID().uuidString,
                    sourcePath: "/tmp/fixture.mov",
                    sourceDurationMs: 4000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "full",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
            ],
            coverTimeMs: 1500
        )

        XCTAssertNoThrow(try SharedCoreBridge.validate(project))
    }

    func testMacProjectRejectsUnknownTemplateThroughServiceError() {
        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "not-a-template",
            canvas: .init(width: 1080, height: 1920, fps: 30, durationMs: 3000),
            clips: [],
            coverTimeMs: 1500
        )

        XCTAssertThrowsError(try SharedCoreBridge.validate(project)) { error in
            let serviceError = error as? ServiceError
            XCTAssertEqual(serviceError?.code, "INVALID_PROJECT")
        }
    }
}
