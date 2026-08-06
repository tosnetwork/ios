import XCTest

final class TOSWalletUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TOS_RPC_URL"] = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        app.launch()
    }

    func testOnboardingExposesCoreWalletEntryPoints() {
        XCTAssertTrue(app.staticTexts["TOS Wallet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Create New Wallet"].exists)
        XCTAssertTrue(app.buttons["Import Existing Wallet"].exists)
        XCTAssertTrue(app.links["Terms of Use"].exists)
    }

    func testCreateWalletRequiresPasscodeConfirmationBeforeBackup() {
        let create = app.buttons["Create New Wallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()

        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["0"].exists)

        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234")
        let backupTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Back up your recovery")
        ).firstMatch
        XCTAssertTrue(backupTitle.waitForExistence(timeout: 5))
    }

    func testImportWalletOpensRecoveryPhraseFlow() {
        let importWallet = app.buttons["Import Existing Wallet"]
        XCTAssertTrue(importWallet.waitForExistence(timeout: 15))
        importWallet.tap()

        let existingWallet = app.cells.containing(.staticText, identifier: "Existing Wallet").firstMatch
        XCTAssertTrue(existingWallet.waitForExistence(timeout: 5))
        existingWallet.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Enter recovery phrase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Paste"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Continue"].exists)
    }

    private func enterPasscode(_ passcode: String) {
        for digit in passcode {
            app.buttons[String(digit)].tap()
        }
    }
}
