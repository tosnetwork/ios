import XCTest

final class TOSWalletUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "1"
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

    func testCreateWalletRejectsMismatchedPasscodeConfirmation() {
        openCreatePasscode()
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))

        enterPasscode("1235")
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 5))
    }

    func testPasscodeBackspaceRemovesOnlyTheLastDigit() {
        openCreatePasscode()
        enterPasscode("123")
        app.buttons["passcode.backspace"].tap()
        enterPasscode("4")

        XCTAssertTrue(app.staticTexts["Create passcode"].exists)
        XCTAssertFalse(app.staticTexts["Re-enter passcode"].exists)

        enterPasscode("5")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
    }

    func testImportWalletOpensRecoveryPhraseFlow() {
        let importWallet = app.buttons["Import Existing Wallet"]
        XCTAssertTrue(importWallet.waitForExistence(timeout: 15))
        importWallet.tap()

        let existingWallet = app.cells.containing(.staticText, identifier: "Existing Wallet").firstMatch
        XCTAssertTrue(existingWallet.waitForExistence(timeout: 5))
        assertV1ImportOptionsAreHidden()
        existingWallet.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Enter recovery phrase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Paste"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Continue"].exists)
    }

    func testCreateWalletCompletesAndPersistsAcrossRelaunch() {
        createNativeWalletToHome()

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
    }

    func testReceiveOpensNativeTOSAddressWithoutDeferredAssets() {
        createNativeWalletToHome()

        let receive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Receive")
        ).firstMatch
        receive.tap()

        let receiveTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Receive TOS")
        ).firstMatch
        XCTAssertTrue(receiveTitle.waitForExistence(timeout: 10))
        let address = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[UE]Q[A-Za-z0-9_-]{46}")
        ).firstMatch
        XCTAssertTrue(address.exists)
        let copy = app.descendants(matching: .any)["Copy"]
        XCTAssertTrue(copy.exists)
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 5))
        for unsupported in ["TRC20", "Jetton", "NFT", "TON"] {
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported receive asset is visible: \(unsupported)")
        }
    }

    private func createNativeWalletToHome() {
        openCreatePasscode()
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234")

        let later = app.descendants(matching: .any)["Later"]
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        XCTAssertTrue(app.staticTexts["Customize your Wallet"].waitForExistence(timeout: 5))
        let customizeContinue = app.descendants(matching: .any)["Continue"]
        XCTAssertTrue(customizeContinue.waitForExistence(timeout: 10))
        customizeContinue.tap()

        let creationFailure = app.alerts["Wallet creation failed"]
        if creationFailure.waitForExistence(timeout: 2) {
            let message = creationFailure.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            XCTFail(message)
        }

        assertNativeWalletHome()
    }

    private func assertV1ImportOptionsAreHidden() {
        let unsupportedOptions = [
            "Watch-only Wallet", "Ledger", "Signer", "Keystone", "Testnet", "TRON",
        ]
        for option in unsupportedOptions {
            XCTAssertFalse(app.staticTexts[option].exists, "Unsupported V1 option is visible: \(option)")
        }
    }

    private func enterPasscode(_ passcode: String) {
        for digit in passcode {
            app.buttons[String(digit)].tap()
        }
    }

    private func openCreatePasscode() {
        let create = app.buttons["Create New Wallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 5))
    }

    private func assertNativeWalletHome() {
        let send = app.descendants(matching: .any)["Send"]
        guard send.waitForExistence(timeout: 20) else {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Missing wallet home hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Wallet home did not appear")
            return
        }
        let receive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Receive")
        ).firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Wallet"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["History"].exists)
        for unsupported in ["Scan", "Swap", "Buy", "Stake", "Browser", "Collectibles"] {
            XCTAssertFalse(app.buttons[unsupported].exists, "Unsupported V1 home action is visible: \(unsupported)")
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported V1 tab is visible: \(unsupported)")
        }
    }

}
