import Photos
import XCTest
@testable import LivePhotoService

final class PhotoAuthorizationTests: XCTestCase {
    func testOnlyDeniedStatusDirectsUserToPrivacySettings() {
        XCTAssertNil(PhotoAuthorization.error(for: .authorized))
        XCTAssertEqual(PhotoAuthorization.error(for: .denied)?.code, "PHOTO_PERMISSION_DENIED")
        XCTAssertEqual(PhotoAuthorization.error(for: .restricted)?.code, "PHOTO_PERMISSION_RESTRICTED")
        XCTAssertEqual(PhotoAuthorization.error(for: .notDetermined)?.code, "PHOTO_PERMISSION_UNAVAILABLE")
        XCTAssertEqual(PhotoAuthorization.error(for: .limited)?.code, "PHOTO_PERMISSION_UNAVAILABLE")
    }
}
