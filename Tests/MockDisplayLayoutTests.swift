import CoreGraphics
import XCTest

@testable import ExternalDisplayDemo

/// `MockDisplayLayout` 的两态摆放。纯几何，不需要屏幕也不需要硬件。
final class MockDisplayLayoutTests: XCTestCase {

    private let aspect: CGFloat = 16.0 / 9.0

    // MARK: - 竖屏

    func testPortraitFillsWidthAndCentersVertically() {
        let container = CGRect(x: 20, y: 60, width: 350, height: 628)
        let rect = MockDisplayLayout.rect(in: container, aspect: aspect)

        XCTAssertEqual(rect.width, 350, accuracy: 0.01)
        XCTAssertEqual(rect.height, 350 / aspect, accuracy: 0.01)
        XCTAssertEqual(rect.midX, container.midX, accuracy: 0.01)
        XCTAssertEqual(rect.midY, container.midY, accuracy: 0.01)
    }

    func testPortraitSquareContainerStillFillsWidth() {
        // 接近方形的竖屏容器（iPad 分屏）：仍然宽度顶满，高度按比例算，不切到 PIP。
        let container = CGRect(x: 0, y: 0, width: 300, height: 300)
        let rect = MockDisplayLayout.rect(in: container, aspect: aspect)

        XCTAssertEqual(rect.width, 300, accuracy: 0.01)
        XCTAssertEqual(rect.height, 300 / aspect, accuracy: 0.01)
        XCTAssertEqual(rect.midY, container.midY, accuracy: 0.01)
    }

    // MARK: - 横屏

    func testLandscapeBecomesBottomRightPIP() {
        let container = CGRect(x: 20, y: 60, width: 804, height: 270)
        let rect = MockDisplayLayout.rect(in: container, aspect: aspect)

        XCTAssertEqual(rect.height, 270 * MockDisplayLayout.pipHeightRatio, accuracy: 0.01)
        XCTAssertEqual(rect.width / rect.height, aspect, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, container.maxX - 16, accuracy: 0.01)
        XCTAssertEqual(rect.maxY, container.maxY - 16, accuracy: 0.01)
    }

    func testLandscapePIPIsSmallerThanPortraitBand() {
        // 横屏 PIP 不该比竖屏那条宽条还大 —— 否则"保留但让位"这个前提不成立。
        let portrait = MockDisplayLayout.rect(
            in: CGRect(x: 20, y: 60, width: 350, height: 628),
            aspect: aspect
        )
        let landscape = MockDisplayLayout.rect(
            in: CGRect(x: 20, y: 60, width: 804, height: 270),
            aspect: aspect
        )

        XCTAssertLessThan(landscape.height, portrait.height)
    }

    func testLandscapeClampsToContainerWidth() {
        // 超宽比 + 窄容器：按高度算出来的 PIP 会顶出右边界，必须按宽度收。
        let container = CGRect(x: 0, y: 0, width: 200, height: 190)
        let rect = MockDisplayLayout.rect(in: container, aspect: 3)

        XCTAssertLessThanOrEqual(rect.width, container.width - 32 + 0.01)
        XCTAssertEqual(rect.maxX, container.maxX - 16, accuracy: 0.01)
        XCTAssertEqual(rect.width / rect.height, 3, accuracy: 0.001)
    }

    // MARK: - 退化输入

    func testInvalidAspectReturnsContainer() {
        let container = CGRect(x: 1, y: 2, width: 300, height: 200)
        XCTAssertEqual(MockDisplayLayout.rect(in: container, aspect: 0), container)
    }

    func testEmptyContainerReturnsItself() {
        let container = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(MockDisplayLayout.rect(in: container, aspect: aspect), container)
    }

    // MARK: - 判据

    func testLandscapeDetectionUsesAspectNotDevice() {
        XCTAssertTrue(MockDisplayLayout.isLandscape(CGRect(x: 0, y: 0, width: 844, height: 390)))
        XCTAssertFalse(MockDisplayLayout.isLandscape(CGRect(x: 0, y: 0, width: 390, height: 844)))
        XCTAssertFalse(MockDisplayLayout.isLandscape(CGRect(x: 0, y: 0, width: 300, height: 300)))
    }
}
