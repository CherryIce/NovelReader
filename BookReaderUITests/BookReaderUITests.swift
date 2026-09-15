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
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertTrue(tabBar.buttons["书架"].exists)
        XCTAssertTrue(tabBar.buttons["搜索"].exists)
        XCTAssertTrue(tabBar.buttons["设置"].exists)

        tabBar.buttons["搜索"].tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 2))

        tabBar.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
