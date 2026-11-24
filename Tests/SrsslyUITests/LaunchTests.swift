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
