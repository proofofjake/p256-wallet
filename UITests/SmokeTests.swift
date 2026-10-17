import XCTest

/// End-to-end smoke test against live Base Sepolia, using a Simulator test key in place of a YubiKey.
/// Set `TEST_RUNNER_SCREENSHOT_DIR` when running `xcodebuild test` to save screenshots of each step.
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetWallet"]
        app.launch()
    }

    func testCreateWalletEstimateAndSign() throws {
        app.buttons["Use a test key on this device"].tap()

        let receive = app.buttons["Receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 30), "home screen did not appear")
        XCTAssertTrue(app.staticTexts["Assets"].exists)
        snapshot("1-home")

        receive.tap()
        XCTAssertTrue(app.navigationBars["Receive"].waitForExistence(timeout: 5))
        snapshot("2-receive")
        app.buttons["Done"].tap()

        // A contract call from the undeployed, unfunded account: estimation should still work and
        // report the shortfall instead of failing.
        app.buttons["Contract call"].tap()
        let target = app.textFields["0x…"].firstMatch
        target.tap()
        target.typeText("0x000000000000000000000000000000000000dEaD")
        app.buttons["Raw calldata"].tap()
        app.buttons["Review"].tap()
        let fee = app.staticTexts["Network fee"]
        XCTAssertTrue(fee.waitForExistence(timeout: 45), "fee estimate did not load")
        XCTAssertTrue(app.staticTexts["Includes one-time account deployment"].exists)
        snapshot("3-review")
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Sign message"].tap()
        let message = app.textFields.firstMatch
        message.tap()
        message.typeText("gm from P256 Wallet")
        app.buttons["Sign"].tap()
        XCTAssertTrue(app.buttons["Copy signature"].waitForExistence(timeout: 30), "signing did not complete")
        snapshot("4-signed")
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
