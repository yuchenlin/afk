import XCTest
@testable import AFKCore

final class LogoMarkTests: XCTestCase {
    func testMarkFitsInsideTargetAndMatchesSVGBounds() {
        let target = CGRect(x: 100, y: 100, width: 824, height: 824)
        let full = LogoMark.path(fitting: target).boundingBoxOfPath
        XCTAssertTrue(target.contains(full))
        // Same placement as the SVG: mark bounds scaled by 824/1024 and flipped (y up).
        let s: CGFloat = 824 / 1024
        XCTAssertEqual(full.minX, 100 + 305 * s, accuracy: 0.5)
        XCTAssertEqual(full.width, 414 * s, accuracy: 0.5)
        XCTAssertEqual(full.maxY, 100 + (1024 - 332) * s, accuracy: 0.5)

        let tight = LogoMark.path(fitting: CGRect(x: 0, y: 0, width: 18, height: 18), source: LogoMark.markBounds).boundingBoxOfPath
        XCTAssertEqual(max(tight.width, tight.height), 18, accuracy: 0.05, "the tight mark fills the box")
    }

    func testMenuBarImagesAreTemplates() {
        for active in [false, true] {
            let image = LogoMark.menuBarImage(active: active)
            XCTAssertTrue(image.isTemplate, "adapts to light/dark menu bars")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        }
    }
}
