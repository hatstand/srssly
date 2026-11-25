import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The first frame should already show articles from the local store:
    /// no splash, no spinner, no waiting for the network.
    @MainActor
    func testFirstFrameShowsStoredArticles() {
        let app = XCUIApplication()
        app.launchArguments = ["-SrsslySampleData"]
        app.launch()

        let firstRow = app.descendants(matching: .any)["article-row"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.activityIndicators.firstMatch.exists, "Launch should never show a loading spinner")
    }

    /// Tapping an article opens the reader.
    @MainActor
    func testOpeningAnArticleShowsTheReader() {
        let app = XCUIApplication()
        app.launchArguments = ["-SrsslySampleData"]
        app.launch()

        let firstRow = app.descendants(matching: .any)["article-row"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
    }

    /// Swiping left in the reader moves to the next article in the list.
    @MainActor
    func testSwipingMovesBetweenArticles() {
        let app = XCUIApplication()
        app.launchArguments = ["-SrsslySampleData"]
        app.launch()

        let firstRow = app.descendants(matching: .any)["article-row"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.tap()
        let pager = app.descendants(matching: .any)["reader-pager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let first = pager.value as? String
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, "")

        pager.swipeLeft()
        let moved = NSPredicate { _, _ in (pager.value as? String) != first }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

        pager.swipeRight()
        let back = NSPredicate { _, _ in (pager.value as? String) == first }
        expectation(for: back, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    /// Records launch time. Set a baseline in Xcode (Report navigator) to make
    /// this fail on regressions; on CI it just records.
    @MainActor
    func testLaunchPerformance() {
        let app = XCUIApplication()
        app.launchArguments = ["-SrsslySampleData"]
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
    }
}
