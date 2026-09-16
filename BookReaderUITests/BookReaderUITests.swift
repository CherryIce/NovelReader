//
//  BookReaderUITests.swift
//  BookReaderUITests
//
//  Created by hubin on 2026/5/21.
//

import XCTest

final class BookReaderUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testPrimaryTabsNavigate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertTrue(tabBar.buttons["书架"].exists)
        XCTAssertTrue(tabBar.buttons["笔记"].exists)
        XCTAssertTrue(tabBar.buttons["统计"].exists)
        XCTAssertTrue(tabBar.buttons["设置"].exists)

        tabBar.buttons["笔记"].tap()
        XCTAssertTrue(app.navigationBars["笔记"].waitForExistence(timeout: 2))

        tabBar.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 2))

        app.staticTexts["隐私协议"].tap()
        let privacyNavigationBar = app.navigationBars["隐私协议"]
        XCTAssertTrue(privacyNavigationBar.waitForExistence(timeout: 2))
        XCTAssertTrue(tabBar.waitForNonExistence(timeout: 2))

        privacyNavigationBar.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 2))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
