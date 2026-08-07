import CoreImage
import UIKit
import XCTest

final class TOSWalletUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureMnemonic = "mansion chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction voice"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try setProxyMode("normal", resetCounts: true)
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "1"
        app.launchEnvironment["TOS_RPC_URL"] = ProcessInfo.processInfo.environment["TOS_UI_RPC_URL"]
            ?? "http://127.0.0.1:18645"
        app.launchEnvironment["TOS_UI_TEST_SEND_RECIPIENT"] = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        app.launchEnvironment["TOS_UI_TEST_SEND_COMMENT"] = "TOS automated transfer"
        app.launch()
    }

    func testOnboardingExposesCoreWalletEntryPoints() {
        XCTAssertTrue(app.staticTexts["TOS Wallet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Create New Wallet"].exists)
        XCTAssertTrue(app.buttons["Import Existing Wallet"].exists)
        XCTAssertTrue(app.links["Terms of Use"].exists)

        let tosGalaxy = app.images["onboarding.tosGalaxy"]
        XCTAssertTrue(tosGalaxy.exists)
        XCTAssertLessThanOrEqual(tosGalaxy.frame.width, 136)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(tosGalaxy.frame))
        assertReachableControlsAreAccessible()
    }

    func testV1OnboardingLayoutAndContrastAcrossAppearanceAndTextSizes() {
        let configurations = [
            ("Light", "UICTContentSizeCategoryXS"),
            ("Light", "UICTContentSizeCategoryAccessibilityXXXL"),
            ("Dark", "UICTContentSizeCategoryXS"),
            ("Dark", "UICTContentSizeCategoryAccessibilityXXXL"),
        ]
        for (appearance, contentSize) in configurations {
            launchOnboarding(appearance: appearance, contentSize: contentSize)
            XCTAssertTrue(app.staticTexts["TOS Wallet"].waitForExistence(timeout: 15))
            assertVisibleElementsFitWindow()
            assertScreenshotHasReadableContrast(app.screenshot().image)
        }
    }

    func testBackgroundPrivacyShieldAppearsAndForegroundRestores() {
        XCUIDevice.shared.press(.home)
        app.activate()
        let hiddenShield = app.descendants(matching: .any)["app.privacyShield"]
        let shieldRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: hiddenShield
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shieldRemoved], timeout: 5), .completed)

        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "1"
        app.launchEnvironment["TOS_UI_TEST_KEEP_PRIVACY_SHIELD"] = "1"
        app.launch()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["app.privacyShield"].waitForExistence(timeout: 5))
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

    func testCancelledCreationLeavesNoPartialWallet() {
        openCreatePasscode()
        enterPasscode("12")
        let close = app.descendants(matching: .any)["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["Create New Wallet"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Create New Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Import Existing Wallet"].exists)
    }

    func testRecoveryPhraseBackupRejectsWrongWordAndCompletesWithExactWords() {
        openCreatePasscode()
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234")

        let continueControl = app.descendants(matching: .any)["Continue"].firstMatch
        XCTAssertTrue(continueControl.waitForExistence(timeout: 5))
        continueControl.tap()
        XCTAssertTrue(app.staticTexts["Recovery phrase"].waitForExistence(timeout: 5))
        assertReachableControlsAreAccessible()
        var phrase = [Int: String]()
        for index in 1 ... 24 {
            let word = app.descendants(matching: .any)["recovery.word.\(index)"]
            XCTAssertTrue(word.exists)
            phrase[index] = word.value as? String
        }
        XCTAssertEqual(phrase.count, 24)
        app.descendants(matching: .any)["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Backup Check"].waitForExistence(timeout: 5))
        assertReachableControlsAreAccessible()
        let inputs = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "backup.check.input.")
        ).allElementsBoundByIndex
        XCTAssertEqual(inputs.count, 3)
        var challengedIndexes = [Int]()
        for (offset, input) in inputs.enumerated() {
            let index = Int(input.identifier.split(separator: ".").last ?? "") ?? 0
            challengedIndexes.append(index)
            input.tap()
            input.typeText(offset == 0 ? "wrong" : phrase[index] ?? "")
        }
        app.descendants(matching: .any)["Continue"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Backup Check"].exists)

        let retryInputs = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "backup.check.input.")
        ).allElementsBoundByIndex
        XCTAssertEqual(retryInputs.count, 3)
        for input in retryInputs {
            let index = Int(input.identifier.split(separator: ".").last ?? "") ?? 0
            input.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            input.typeText(phrase[index] ?? "")
            XCTAssertEqual(input.value as? String, phrase[index])
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        app.descendants(matching: .any)["Continue"].firstMatch.tap()

        if !app.staticTexts["Customize your Wallet"].waitForExistence(timeout: 10) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Backup retry hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Correct recovery challenge answers were not accepted after a rejected attempt")
        }
        app.descendants(matching: .any)["Continue"].firstMatch.tap()
        assertNativeWalletHome()
        XCTAssertFalse(app.staticTexts["Back up your recovery phrase"].exists)

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
        XCTAssertFalse(app.staticTexts["Back up your recovery phrase"].exists)
    }

    func testSkippedBackupWarningPersistsAcrossRelaunch() {
        createNativeWalletToHome()
        XCTAssertTrue(app.staticTexts["Back up your recovery phrase"].exists)

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
        XCTAssertTrue(app.staticTexts["Back up your recovery phrase"].exists)
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
        assertReachableControlsAreAccessible()
    }

    func testValidFixturePhrasePastesAndStartsNativeImport() {
        launchRecoveryPhraseImport(phrase: fixtureMnemonic)
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234")

        XCTAssertTrue(app.staticTexts["Customize your Wallet"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["Continue"].tap()
        assertNativeWalletHome()

        app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Receive")
        ).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
    }

    func testFundedFixtureLoadsExactNativeBalanceAndIncomingHistory() throws {
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let expectedBalance = try rpcBalance(address: sender)
        importFixtureWalletToHome()
        let walletList = app.collectionViews["wallet.balance.list"]
        XCTAssertTrue(walletList.waitForExistence(timeout: 5))
        pullToRefresh(walletList)
        let renderedBalance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS[c] %@", formatDisplayTOS(expectedBalance), "TOS")
        ).firstMatch
        if !renderedBalance.waitForExistence(timeout: 20) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Funded home hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Funded home did not expose the live native balance")
        }

        app.descendants(matching: .any)["History"].tap()
        let amount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "TOS")).firstMatch
        if !amount.waitForExistence(timeout: 20) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Funded history hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Funded history did not expose the exact native amount")
        }
        XCTAssertFalse(app.staticTexts["Make your first transaction!"].exists)
        assertReachableControlsAreAccessible()
    }

    func testIncomingLocalChainTransferRefreshesBalanceAndHistory() throws {
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let balanceBefore = try rpcBalance(address: sender)
        let eventsBefore = try rpcEventIDs(address: sender)
        importFixtureWalletToHome()

        let transfer = try localnetTransfer(address: sender, amount: 2)
        XCTAssertEqual(transfer.before, balanceBefore)
        XCTAssertGreaterThan(transfer.after, balanceBefore + 1_999_900_000)
        XCTAssertLessThanOrEqual(transfer.after, balanceBefore + 2_000_000_000)
        XCTAssertTrue(waitForBalance(address: sender, timeout: 30) { $0 == transfer.after })

        let walletList = app.collectionViews["wallet.balance.list"]
        XCTAssertTrue(walletList.waitForExistence(timeout: 5))
        pullToRefresh(walletList)
        let expectedBalance = formatDisplayTOS(transfer.after)
        let renderedBalance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS[c] %@", expectedBalance, "TOS")
        ).firstMatch
        if !renderedBalance.waitForExistence(timeout: 15) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Incoming refresh hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Incoming transfer did not refresh the rendered native balance")
        }
        app.buttons["History"].tap()
        let historyAmount = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES[c] %@", ".*\\+.*2.*TOS.*")
        ).firstMatch
        if !historyAmount.waitForExistence(timeout: 20) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Incoming history hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Incoming transfer did not appear with its native amount in history")
        }
        let newEvents = try rpcEventIDs(address: sender).subtracting(eventsBefore)
        XCTAssertEqual(newEvents.count, 1)
    }

    func testOfflineLaunchShowsErrorAndReconnectRefreshesRPCData() throws {
        importFixtureWalletToHome()
        try setProxyMode("offline", resetCounts: true)

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(waitForAnyProxyCount(greaterThan: 0))
        XCTAssertTrue(app.staticTexts["TOS node unavailable. Pull to retry."].waitForExistence(timeout: 15))

        let failedCounts = try proxyCounts()
        let failedTotal = failedCounts.values.reduce(0, +)
        XCTAssertGreaterThan(failedTotal, 0)
        try setProxyMode("normal")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
        app.buttons["History"].tap()
        let historyCollection = app.collectionViews["history.list"]
        XCTAssertTrue(historyCollection.waitForExistence(timeout: 5))
        pullToRefresh(historyCollection)
        XCTAssertTrue(waitForProxyCount(method: "getAccountEvents", greaterThan: 0))

        app.buttons["Wallet"].tap()
        let walletCollection = app.collectionViews["wallet.balance.list"]
        XCTAssertTrue(walletCollection.waitForExistence(timeout: 5))
        pullToRefresh(walletCollection)
        XCTAssertTrue(waitForAnyProxyCount(greaterThan: failedTotal))

        app.buttons["History"].tap()
        XCTAssertFalse(app.staticTexts["TOS node unavailable. Pull to retry."].exists)

        let normalHistoryCount = try proxyCounts()["getAccountEvents", default: 0]
        try setProxyMode("malformed")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        app.buttons["History"].tap()
        XCTAssertTrue(waitForProxyCount(method: "getAccountEvents", greaterThan: normalHistoryCount))
        XCTAssertTrue(app.staticTexts["TOS node unavailable. Pull to retry."].waitForExistence(timeout: 10))
        try setProxyMode("normal")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        app.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "TOS")
        ).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["TOS node unavailable. Pull to retry."].exists)
    }

    func testRecoveryPhraseNormalization() {
        let decorated = "MANSION Chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction VOICE"
        launchRecoveryPhraseImport(phrase: decorated)
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 10))
    }

    func testRecoveryPhraseInvalidWordCountIsRejected() {
        let invalidCount = fixtureMnemonic.split(separator: " ").dropLast().joined(separator: " ")
        launchRecoveryPhraseImport(phrase: invalidCount)
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertFalse(app.staticTexts["Create passcode"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Enter recovery phrase"].exists)
    }

    func testRecoveryPhraseUnknownWordIsRejected() {
        let unknownWord = fixtureMnemonic.replacingOccurrences(of: "mansion", with: "notaword")
        launchRecoveryPhraseImport(phrase: unknownWord)
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertFalse(app.staticTexts["Create passcode"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Enter recovery phrase"].exists)
    }

    func testRecoveryPhraseInvalidChecksumIsRejected() {
        let invalidChecksum = Array(repeating: "abandon", count: 24).joined(separator: " ")
        launchRecoveryPhraseImport(phrase: invalidChecksum)
        XCTAssertEqual(app.descendants(matching: .any)["mnemonic.input.23"].value as? String, "abandon")
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertFalse(app.staticTexts["Create passcode"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Enter recovery phrase"].exists)
    }

    func testCancelledImportLeavesNoWallet() {
        launchRecoveryPhraseImport(phrase: fixtureMnemonic)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.08)).tap()
        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Create New Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Import Existing Wallet"].exists)
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

    func testUnsupportedLaunchDeepLinkCannotEscapeV1Tabs() {
        importFixtureWalletToHome()
        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launchEnvironment["TOS_UI_TEST_DEEP_LINK"] = "toswallet://swap?from=TON&to=USDT"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
        for forbidden in ["Swap", "USDT", "TRC20", "Jetton", "NFT", "Browser"] {
            XCTAssertFalse(app.staticTexts[forbidden].exists)
        }
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
        let qrCode = app.images["receive.qrCode"]
        XCTAssertTrue(qrCode.waitForExistence(timeout: 10))
        let qrImage = CIImage(image: qrCode.screenshot().image)
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let payload = qrImage.flatMap {
            detector?.features(in: $0).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
        }
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains(address.label) == true)
        let copy = app.descendants(matching: .any)["Copy"]
        XCTAssertTrue(copy.exists)
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 5))
        let copyResult = app.descendants(matching: .any)["receive.copy.result"]
        XCTAssertTrue(copyResult.waitForExistence(timeout: 5))
        XCTAssertEqual(copyResult.value as? String, address.label)
        let share = app.descendants(matching: .any)["receive.share"]
        XCTAssertTrue(share.exists)
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
        XCTAssertEqual(share.value as? String, address.label)
        for unsupported in ["TRC20", "Jetton", "NFT", "TON"] {
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported receive asset is visible: \(unsupported)")
        }
        assertReachableControlsAreAccessible()
    }

    func testWrongPasscodePreservesWalletAndCorrectPasscodeStillUnlocks() {
        createNativeWalletToHome()

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        for attempt in 1...5 {
            enterPasscode("9999")
            XCTAssertTrue(
                app.staticTexts["Enter passcode"].waitForExistence(timeout: 5),
                "Wallet unlocked or lost its retry state after wrong attempt \(attempt)"
            )
        }
        enterPasscode("1234")
        assertNativeWalletHome()
    }

    func testRecoveryPhraseInSettingsRequiresCorrectPasscode() {
        launchRecoveryPhraseImport(phrase: fixtureMnemonic)
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Customize your Wallet"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["Continue"].tap()
        assertNativeWalletHome()

        openSettings()
        app.cells["settings.BackupItem"].tap()
        XCTAssertTrue(app.staticTexts["Backup"].waitForExistence(timeout: 10))
        let showPhrase = app.cells.containing(.staticText, identifier: "Show Recovery Phrase").firstMatch
        XCTAssertTrue(showPhrase.waitForExistence(timeout: 5))
        showPhrase.tap()
        XCTAssertTrue(app.staticTexts["Attention"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("9999")
        XCTAssertFalse(app.descendants(matching: .any)["recovery.word.1"].exists)
        XCTAssertTrue(app.staticTexts["Enter passcode"].exists)
        let passcodeReset = expectation(description: "Wrong-passcode animation resets")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { passcodeReset.fulfill() }
        wait(for: [passcodeReset], timeout: 2)
        enterPasscode("1234")

        XCTAssertTrue(app.staticTexts["Recovery phrase"].waitForExistence(timeout: 10))
        let expectedWords = fixtureMnemonic.split(separator: " ").map(String.init)
        for (offset, expectedWord) in expectedWords.enumerated() {
            let word = app.descendants(matching: .any)["recovery.word.\(offset + 1)"]
            XCTAssertTrue(word.exists)
            XCTAssertEqual(word.value as? String, expectedWord)
        }
    }

    func testSendOpensNativeTOSFormWithoutDeferredAssetSelector() {
        createNativeWalletToHome()

        app.descendants(matching: .any)["Send"].tap()
        XCTAssertTrue(app.staticTexts["Send"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Address or name"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Amount"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Comment"].exists)
        for unsupported in ["TRC20", "Jetton", "NFT", "Token"] {
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported send asset is visible: \(unsupported)")
        }
        assertReachableControlsAreAccessible()
    }

    func testSendRejectsInvalidAddressAndAcceptsFixtureAddress() {
        createNativeWalletToHome()
        app.descendants(matching: .any)["Send"].tap()
        XCTAssertTrue(app.staticTexts["Send"].waitForExistence(timeout: 10))

        let recipient = app.textViews["Address or name"]
        let amount = app.textFields["Amount"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.typeText("invalid-address")
        amount.tap()
        XCTAssertTrue(app.staticTexts["Invalid wallet address."].waitForExistence(timeout: 5))

        let validAddress = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        recipient.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        recipient.typeText(validAddress)
        XCTAssertEqual(recipient.value as? String, validAddress)
        amount.tap()
        let invalidError = app.staticTexts["Invalid wallet address."]
        let errorRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: invalidError
        )
        XCTAssertEqual(XCTWaiter.wait(for: [errorRemoved], timeout: 10), .completed)
        XCTAssertFalse(
            app.staticTexts["TOS node unavailable. Pull to retry."].exists,
            "Recipient validation must not mark a reachable node as unavailable"
        )
    }

    func testSendPasteButtonsUseExactRecipientAndComment() {
        importFixtureWalletToHome()
        app.descendants(matching: .any)["Send"].tap()

        let recipient = app.textViews["Address or name"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        XCTAssertEqual(recipient.value as? String, "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU")
        app.descendants(matching: .any)["send.comment.paste"].tap()
        XCTAssertEqual(app.textViews["Comment"].value as? String, "TOS automated transfer")
    }

    func testNativeCommentUTF8ByteBoundary() {
        importFixtureWalletToHome(comment: String(repeating: "a", count: 120))
        app.descendants(matching: .any)["Send"].tap()
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        replaceText(in: app.textFields["Amount"], with: "1")
        app.descendants(matching: .any)["send.comment.paste"].tap()

        let continueButton = app.descendants(matching: .any)["Continue"].firstMatch
        XCTAssertTrue(waitForEnabled(continueButton, expected: true))

        replaceText(in: app.textViews["Comment"], with: String(repeating: "a", count: 121))
        XCTAssertTrue(app.staticTexts["Comment must be 120 UTF-8 bytes or fewer."].waitForExistence(timeout: 5))
        assertCannotContinue(continueButton: continueButton, amountField: app.textFields["Amount"])
    }

    func testNativeSendAmountBoundaries() throws {
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let currentBalance = try rpcBalance(address: sender)
        importFixtureWalletToHome()
        app.descendants(matching: .any)["Send"].tap()
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        let amount = app.textFields["Amount"]
        let continueButton = app.descendants(matching: .any)["Continue"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))

        replaceText(in: amount, with: "1")
        XCTAssertTrue(waitForEnabled(continueButton, expected: true))
        replaceText(in: amount, with: "1.25")
        XCTAssertTrue(waitForEnabled(continueButton, expected: true))
        replaceText(in: amount, with: "0")
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: formatNanoTOS(currentBalance + 1))
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: "0.0000000001")
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: "999999999999999999999999999999999999")
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: "-1")
        XCTAssertFalse((amount.value as? String)?.contains("-") == true)
    }

    func testMaxAmountUsesSendAllFeeSemantics() throws {
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let balance = try rpcBalance(address: sender)
        importFixtureWalletToHome()
        app.descendants(matching: .any)["Send"].tap()
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        let maxButton = app.descendants(matching: .any)["send.amount.max"]
        XCTAssertTrue(maxButton.waitForExistence(timeout: 10))
        maxButton.tap()
        XCTAssertEqual(app.textFields["Amount"].value as? String, formatDisplayTOS(balance))

        app.descendants(matching: .any)["Continue"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Confirm action"].waitForExistence(timeout: 20))
        let fee = app.descendants(matching: .any)["confirmation.fee"]
        XCTAssertTrue(fee.waitForExistence(timeout: 10))
        XCTAssertFalse(fee.staticTexts["?"].exists)
        app.descendants(matching: .any)["Close"].firstMatch.tap()
        XCTAssertEqual(try rpcBalance(address: sender), balance)
    }

    func testInsufficientBalanceAndFeeAreRejectedSafely() throws {
        createNativeWalletToHome()
        app.descendants(matching: .any)["Send"].tap()
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        replaceText(in: app.textFields["Amount"], with: "1")
        XCTAssertTrue(app.staticTexts["Insufficient balance"].waitForExistence(timeout: 5))
        assertCannotContinue(
            continueButton: app.descendants(matching: .any)["Continue"].firstMatch,
            amountField: app.textFields["Amount"]
        )

        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let balance = try rpcBalance(address: sender)
        importFixtureWalletToHome()
        app.descendants(matching: .any)["Send"].tap()
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        replaceText(in: app.textFields["Amount"], with: formatNanoTOS(balance - 1))
        app.descendants(matching: .any)["Continue"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Confirm action"].waitForExistence(timeout: 20))
        let insufficientFunds = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Insufficient Funds")
        ).firstMatch
        if !insufficientFunds.waitForExistence(timeout: 20) {
            let sliderStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.91))
            let sliderEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.91))
            sliderStart.press(forDuration: 0.2, thenDragTo: sliderEnd)
            if app.staticTexts["Enter passcode"].waitForExistence(timeout: 3) {
                enterPasscode("1234")
            }
        }
        if !insufficientFunds.waitForExistence(timeout: 20) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Insufficient fee hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Insufficient-fee transfer did not expose the safe error")
        }
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "blockchain fees")
        ).firstMatch.exists)
        XCTAssertEqual(try rpcBalance(address: sender), balance)
    }

    func testNativeSendConfirmationShowsExactValuesAndCancelDoesNotBroadcast() throws {
        let faucet = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        let balanceBefore = try rpcBalance(address: faucet)
        importFixtureWalletToHome()
        app.descendants(matching: .any)["Send"].tap()

        let recipient = app.textViews["Address or name"]
        let amount = app.textFields["Amount"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.typeText(faucet)
        amount.tap()
        amount.typeText("1.25")
        let comment = app.textViews["Comment"]
        comment.tap()
        comment.typeText("TOS automated transfer")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        let continueButton = app.descendants(matching: .any)["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "1.25", "TOS")
        ).firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", faucet)
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TOS automated transfer"].exists)
        let fee = app.descendants(matching: .any)["confirmation.fee"]
        XCTAssertTrue(fee.waitForExistence(timeout: 10))
        XCTAssertTrue(fee.staticTexts["Fee"].exists)
        XCTAssertTrue(fee.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label != %@", "TOS", "?")
        ).firstMatch.exists)
        assertReachableControlsAreAccessible()

        app.descendants(matching: .any)["Close"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Send"].waitForExistence(timeout: 10))
        XCTAssertEqual(try rpcBalance(address: faucet), balanceBefore)
    }

    func testPasscodeSignsBroadcastsAndReconcilesNativeTransfer() throws {
        let transferComment = "TOS 星河 🚀"
        let faucet = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let faucetBefore = try rpcBalance(address: faucet)
        let senderBefore = try rpcBalance(address: sender)
        let eventsBefore = try rpcEventIDs(address: sender)
        importFixtureWalletToHome(comment: transferComment)
        app.descendants(matching: .any)["Send"].tap()

        let recipient = app.textViews["Address or name"]
        let amount = app.textFields["Amount"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.typeText(faucet)
        amount.tap()
        amount.typeText("0.5")
        let comment = app.textViews["Comment"]
        app.descendants(matching: .any)["send.comment.paste"].tap()
        XCTAssertEqual(comment.value as? String, transferComment)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let continueButton = app.descendants(matching: .any)["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Confirm action"].waitForExistence(timeout: 20))
        let sliderStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.91))
        let sliderEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.91))
        sliderStart.press(forDuration: 0.2, thenDragTo: sliderEnd)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")

        XCTAssertTrue(waitForBalance(address: faucet, timeout: 30) { $0 >= faucetBefore + 500_000_000 })
        XCTAssertTrue(waitForBalance(address: sender, timeout: 30) { $0 < senderBefore - 500_000_000 })
        let eventsAfter = try rpcEventIDs(address: sender)
        let newEvents = eventsAfter.subtracting(eventsBefore)
        XCTAssertEqual(newEvents.count, 1)
        let eventID = try XCTUnwrap(newEvents.first)
        XCTAssertEqual(try rpcEventComment(address: sender, eventID: eventID), transferComment)
        let eventMetadata = try rpcEventMetadata(address: sender, eventID: eventID)
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 15))
        let historyAmount = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "0.5", "TOS")
        ).firstMatch
        XCTAssertTrue(historyAmount.waitForExistence(timeout: 20))
        historyAmount.tap()
        XCTAssertTrue(app.staticTexts[transferComment].waitForExistence(timeout: 10))
        let recipientAddress = app.staticTexts["Uf8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAG3R"]
        if !recipientAddress.exists {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Native event details hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(recipientAddress.exists)
        let feeItem = app.descendants(matching: .any)["history.details.fee"]
        XCTAssertTrue(feeItem.waitForExistence(timeout: 5))
        XCTAssertTrue(feeItem.staticTexts["Fee"].exists)
        XCTAssertTrue(feeItem.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "TOS")
        ).firstMatch.exists)
        let detailsDateFormatter = DateFormatter()
        detailsDateFormatter.locale = Locale.current
        detailsDateFormatter.dateFormat = "HH:mm"
        let expectedTimestamp = detailsDateFormatter.string(from: Date(timeIntervalSince1970: eventMetadata.timestamp))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", expectedTimestamp)
        ).firstMatch.exists)
        assertReachableControlsAreAccessible()
    }

    func testLostBroadcastResponseDoesNotDuplicateNativeTransfer() throws {
        let faucet = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let faucetBefore = try rpcBalance(address: faucet)
        let eventsBefore = try rpcEventIDs(address: sender)
        importFixtureWalletToHome(comment: "lost response")
        openNativeSendConfirmation(amount: "0.25")
        try setProxyMode("drop_broadcast_response", resetCounts: true)
        confirmNativeTransferWithPasscode()

        XCTAssertTrue(waitForBalance(address: faucet, timeout: 30) { $0 >= faucetBefore + 250_000_000 })
        XCTAssertTrue(
            waitForBroadcastCount(greaterThan: 0),
            "Proxy did not observe a native broadcast; counts=\((try? proxyCounts()) ?? [:]), endpoint=\(proxyEndpoint)"
        )
        XCTAssertEqual(try broadcastCount(), 1)
        let newEvents = try rpcEventIDs(address: sender).subtracting(eventsBefore)
        XCTAssertEqual(newEvents.count, 1)
        try setProxyMode("normal")
    }

    func testRelaunchReconcilesTransferWithDelayedBroadcastResponse() throws {
        let faucet = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        let sender = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        let faucetBefore = try rpcBalance(address: faucet)
        let eventsBefore = try rpcEventIDs(address: sender)
        importFixtureWalletToHome(comment: "relaunch pending")
        openNativeSendConfirmation(amount: "0.3")
        try setProxyMode("delay_broadcast_response", resetCounts: true)
        confirmNativeTransferWithPasscode()
        XCTAssertTrue(app.descendants(matching: .any)["process.state.processing"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForBroadcastCount(greaterThan: 0, timeout: 10))

        app.terminate()
        try setProxyMode("normal")
        XCTAssertTrue(waitForBalance(address: faucet, timeout: 30) { $0 >= faucetBefore + 300_000_000 })
        let newEvents = try rpcEventIDs(address: sender).subtracting(eventsBefore)
        XCTAssertEqual(newEvents.count, 1)

        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 30))
        app.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "0.3", "TOS")
        ).firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(try rpcEventIDs(address: sender).subtracting(eventsBefore).count, 1)
    }

    func testNewWalletShowsZeroNativeTOSBalance() {
        createNativeWalletToHome()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label MATCHES[c] %@", "0([.,]0+)? TOS")
        ).firstMatch.waitForExistence(timeout: 10))
        for unsupported in ["TON", "TRX", "USDT", "Jetton", "NFT"] {
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported V1 asset is visible: \(unsupported)")
        }

        app.descendants(matching: .any)["History"].tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Your history")
        ).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Make your first transaction!"].exists)
        for unsupported in ["TRON", "Jetton", "NFT", "DApp", "Spam"] {
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported V1 history entry is visible: \(unsupported)")
        }
        assertReachableControlsAreAccessible()
    }

    func testSettingsNavigationAndV1Inventory() {
        createNativeWalletToHome()

        let settings = app.descendants(matching: .any)["wallet.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["settings.BackupItem"].exists)
        XCTAssertTrue(app.cells["settings.RPCNodeItem"].exists)
        XCTAssertTrue(app.cells["settings.DeleteAccountItem"].exists)
        XCTAssertTrue(app.cells["settings.LegalItem"].exists)

        for unsupported in ["Swap", "Staking", "Battery", "Connected Apps", "Notifications", "Currency", "TRON"] {
            XCTAssertFalse(app.staticTexts[unsupported].exists, "Unsupported V1 setting is visible: \(unsupported)")
        }
        assertReachableControlsAreAccessible()

        app.descendants(matching: .any)["settings.back"].tap()
        assertNativeWalletHome()
    }

    func testRPCNodeValidationPersistenceAndRestore() {
        createNativeWalletToHome()
        openSettings()
        app.cells["settings.RPCNodeItem"].tap()

        let endpoint = app.textFields["settings.rpc.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.typeText("not a valid endpoint")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Invalid RPC Node"].waitForExistence(timeout: 5))
        app.alerts["Invalid RPC Node"].buttons["OK"].tap()

        app.cells["settings.RPCNodeItem"].tap()
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.typeText("127.0.0.1:18645/jsonRPC")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:18645"].waitForExistence(timeout: 5))

        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        try? setProxyMode("normal", resetCounts: true)
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(waitForAnyProxyCount(greaterThan: 0))
        openSettings()
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:18645"].waitForExistence(timeout: 5))

        app.cells["settings.RPCNodeItem"].tap()
        app.buttons["Restore Default"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Default node"].waitForExistence(timeout: 5))
    }

    func testDeleteWalletRequiresAcknowledgementAndCanBeCancelled() {
        createNativeWalletToHome()
        openSettings()
        app.cells["settings.DeleteAccountItem"].tap()

        XCTAssertTrue(app.staticTexts["Delete Wallet Data"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["settings.delete.confirm"].isEnabled)
        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        assertNativeWalletHome()
    }

    func testDeletingLastWalletReturnsToCleanOnboarding() {
        createNativeWalletToHome()
        openSettings()
        app.cells["settings.DeleteAccountItem"].tap()

        let acknowledge = app.descendants(matching: .any)["settings.delete.acknowledge"]
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 5))
        acknowledge.tap()
        let confirm = app.descendants(matching: .any)["settings.delete.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(app.buttons["Create New Wallet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Import Existing Wallet"].exists)

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Create New Wallet"].waitForExistence(timeout: 10))
    }

    func testLegalInventoryUsesApprovedTOSBranding() {
        createNativeWalletToHome()
        openSettings()
        app.cells["settings.LegalItem"].tap()

        XCTAssertTrue(app.staticTexts["Legal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["settings.termsOfServiceIdentifier"].exists)
        XCTAssertTrue(app.cells["settings.privacyPolicyIdentifier"].exists)
        XCTAssertTrue(app.cells["settings.montserratFontIdentifier"].exists)
        XCTAssertTrue(app.staticTexts["Terms of service"].exists)
        XCTAssertTrue(app.staticTexts["Privacy policy"].exists)
        assertReachableControlsAreAccessible()
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

    private func importFixtureWalletToHome(comment: String = "TOS automated transfer") {
        launchRecoveryPhraseImport(phrase: fixtureMnemonic, comment: comment)
        app.descendants(matching: .any)["mnemonic.continue"].tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Re-enter passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234")
        XCTAssertTrue(app.staticTexts["Customize your Wallet"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["Continue"].tap()
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

    private func replaceText(in element: XCUIElement, with value: String) {
        element.tap()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        element.typeText(value)
    }

    private func pullToRefresh(_ element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.2, thenDragTo: end)
    }

    private func formatNanoTOS(_ value: UInt64) -> String {
        let whole = value / 1_000_000_000
        let fraction = String(format: "%09llu", value % 1_000_000_000)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return fraction.isEmpty ? String(whole) : "\(whole).\(fraction)"
    }

    private func formatDisplayTOS(_ value: UInt64) -> String {
        let hundredths = value / 10_000_000
        let whole = hundredths / 100
        let fraction = hundredths % 100
        if fraction == 0 { return String(whole) }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return String(format: "%llu.%02llu", whole, fraction)
    }

    private func waitForEnabled(_ element: XCUIElement, expected: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == %@", NSNumber(value: expected)),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func assertCannotContinue(continueButton: XCUIElement, amountField: XCUIElement) {
        continueButton.tap()
        XCTAssertTrue(amountField.waitForExistence(timeout: 1), "Invalid amount advanced past the send form")
    }

    private func openNativeSendConfirmation(amount: String) {
        app.descendants(matching: .any)["Send"].tap()
        app.descendants(matching: .any)["send.recipient.paste"].tap()
        replaceText(in: app.textFields["Amount"], with: amount)
        app.descendants(matching: .any)["send.comment.paste"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let continueButton = app.descendants(matching: .any)["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Confirm action"].waitForExistence(timeout: 20))
    }

    private func confirmNativeTransferWithPasscode() {
        let sliderStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.91))
        let sliderEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.91))
        sliderStart.press(forDuration: 0.2, thenDragTo: sliderEnd)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
    }

    private func openCreatePasscode() {
        let create = app.buttons["Create New Wallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 5))
    }

    private func launchOnboarding(appearance: String, contentSize: String) {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "1"
        app.launchEnvironment["TOS_RPC_URL"] = ProcessInfo.processInfo.environment["TOS_UI_RPC_URL"]
            ?? "http://127.0.0.1:18645"
        app.launchArguments += [
            "-AppleInterfaceStyle", appearance,
            "-UIPreferredContentSizeCategoryName", contentSize,
        ]
        app.launch()
    }

    private func assertVisibleElementsFitWindow(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
        let types: [XCUIElement.ElementType] = [.button, .staticText, .textField, .secureTextField]
        for type in types {
            for element in app.descendants(matching: type).allElementsBoundByIndex where element.isHittable {
                XCTAssertGreaterThan(element.frame.width, 0, file: file, line: line)
                XCTAssertGreaterThan(element.frame.height, 0, file: file, line: line)
                XCTAssertTrue(
                    window.contains(element.frame),
                    "\(type) is clipped at \(element.frame) outside \(window): \(element.label)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertScreenshotHasReadableContrast(
        _ image: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            return XCTFail("Unable to inspect screenshot pixels", file: file, line: line)
        }
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)
        var minimum = 255
        var maximum = 0
        let step = max(cgImage.width / 80, 1)
        for y in stride(from: 0, to: cgImage.height, by: step) {
            for x in stride(from: 0, to: cgImage.width, by: step) {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + min(1, bytesPerPixel - 1)])
                let blue = Int(bytes[offset + min(2, bytesPerPixel - 1)])
                let luminance = (red * 299 + green * 587 + blue * 114) / 1000
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        XCTAssertLessThan(minimum, 80, file: file, line: line)
        XCTAssertGreaterThan(maximum, 175, file: file, line: line)
        XCTAssertGreaterThan(maximum - minimum, 120, file: file, line: line)
    }

    private func openRecoveryPhraseImport() {
        let importWallet = app.buttons["Import Existing Wallet"]
        XCTAssertTrue(importWallet.waitForExistence(timeout: 15))
        importWallet.tap()
        let existingWallet = app.cells.containing(.staticText, identifier: "Existing Wallet").firstMatch
        XCTAssertTrue(existingWallet.waitForExistence(timeout: 5))
        existingWallet.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Enter recovery phrase"].waitForExistence(timeout: 5))
    }

    private func launchRecoveryPhraseImport(
        phrase: String,
        comment: String = "TOS automated transfer"
    ) {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "1"
        app.launchEnvironment["TOS_UI_TEST_PASTEBOARD"] = phrase
        app.launchEnvironment["TOS_UI_TEST_SEND_RECIPIENT"] = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
        app.launchEnvironment["TOS_UI_TEST_SEND_COMMENT"] = comment
        app.launchEnvironment["TOS_RPC_URL"] = ProcessInfo.processInfo.environment["TOS_UI_RPC_URL"]
            ?? "http://127.0.0.1:18645"
        app.launch()
        openRecoveryPhraseImport()
        app.descendants(matching: .any)["mnemonic.paste"].tap()
    }

    private func openSettings() {
        let settings = app.descendants(matching: .any)["wallet.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
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
        assertReachableControlsAreAccessible()
    }

    private func assertReachableControlsAreAccessible(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbiddenCopy = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                ".*(^|[^A-Za-z])(TON|TosWallet|TRON|TRC20|Jetton|NFT|Swap|Staking|Buy|DApp|TonConnect)([^A-Za-z]|$).*"
            )
        )
        XCTAssertEqual(
            forbiddenCopy.count,
            0,
            "Reachable V1 screen exposes inherited or deferred product copy: \(forbiddenCopy.allElementsBoundByIndex.map(\.label))",
            file: file,
            line: line
        )

        let controlTypes: [XCUIElement.ElementType] = [
            .button, .textField, .secureTextField, .link, .switch,
        ]
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .null
        for type in controlTypes {
            for element in app.descendants(matching: type).allElementsBoundByIndex where element.isHittable {
                if keyboardFrame.intersects(element.frame) {
                    continue
                }
                let hasIdentifier = !element.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasLabel = !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                XCTAssertTrue(
                    hasIdentifier || hasLabel,
                    "Reachable \(type) has no accessibility identifier or label: \(element)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func rpcBalance(address: String) throws -> UInt64 {
        let endpoint = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        let url = try XCTUnwrap(URL(string: endpoint + "/jsonRPC"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "getAddressInformation",
            "params": ["address": address],
        ])
        let completed = expectation(description: "TOS RPC balance")
        var result: Result<UInt64, Error>?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { completed.fulfill() }
            do {
                if let error { throw error }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
                let envelope = try XCTUnwrap(object["result"] as? [String: Any])
                result = .success(try XCTUnwrap(UInt64(try XCTUnwrap(envelope["balance"] as? String))))
            } catch {
                result = .failure(error)
            }
        }.resume()
        wait(for: [completed], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    private func waitForBalance(
        address: String,
        timeout: TimeInterval,
        predicate: (UInt64) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let balance = try? rpcBalance(address: address), predicate(balance) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func rpcEventIDs(address: String) throws -> Set<String> {
        let endpoint = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        let url = try XCTUnwrap(URL(string: endpoint + "/jsonRPC"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "getAccountEvents",
            "params": ["address": address, "limit": 100],
        ])
        let completed = expectation(description: "TOS RPC events")
        var result: Result<Set<String>, Error>?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { completed.fulfill() }
            do {
                if let error { throw error }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
                let envelope = try XCTUnwrap(object["result"] as? [String: Any])
                let events = try XCTUnwrap(envelope["events"] as? [[String: Any]])
                result = .success(Set(events.compactMap { $0["event_id"] as? String }))
            } catch {
                result = .failure(error)
            }
        }.resume()
        wait(for: [completed], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    private func rpcEventComment(address: String, eventID: String) throws -> String? {
        let endpoint = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        let url = try XCTUnwrap(URL(string: endpoint + "/jsonRPC"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "getAccountEvent",
            "params": ["address": address, "event_id": eventID],
        ])
        let completed = expectation(description: "TOS RPC event comment")
        var result: Result<String?, Error>?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { completed.fulfill() }
            do {
                if let error { throw error }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
                let envelope = try XCTUnwrap(object["result"] as? [String: Any])
                let transfers = try XCTUnwrap(envelope["transfers"] as? [[String: Any]])
                result = .success(transfers.first?["comment"] as? String)
            } catch {
                result = .failure(error)
            }
        }.resume()
        wait(for: [completed], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    private struct RPCEventMetadata {
        let timestamp: TimeInterval
        let fee: UInt64
    }

    private func rpcEventMetadata(address: String, eventID: String) throws -> RPCEventMetadata {
        let endpoint = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        let url = try XCTUnwrap(URL(string: endpoint + "/jsonRPC"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "getAccountEvent",
            "params": ["address": address, "event_id": eventID],
        ])
        let data = try synchronousData(request: request, description: "TOS RPC event metadata")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let event = try XCTUnwrap(object["result"] as? [String: Any])
        let timestamp = try XCTUnwrap(event["timestamp"] as? NSNumber).doubleValue
        let fee = try XCTUnwrap(UInt64(try XCTUnwrap(event["fee"] as? String)))
        return RPCEventMetadata(timestamp: timestamp, fee: fee)
    }

    private var proxyEndpoint: String {
        ProcessInfo.processInfo.environment["TOS_UI_RPC_URL"] ?? "http://127.0.0.1:18645"
    }

    private func setProxyMode(_ mode: String, resetCounts: Bool = false) throws {
        let url = try XCTUnwrap(URL(string: proxyEndpoint + "/__control"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mode": mode,
            "reset_counts": resetCounts,
        ])
        _ = try synchronousData(request: request, description: "fault proxy control")
    }

    private func proxyCounts() throws -> [String: Int] {
        let url = try XCTUnwrap(URL(string: proxyEndpoint + "/__stats"))
        let data = try synchronousData(request: URLRequest(url: url), description: "fault proxy stats")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let counts = try XCTUnwrap(object["counts"] as? [String: Any])
        return counts.reduce(into: [:]) { result, item in
            result[item.key] = (item.value as? NSNumber)?.intValue
        }
    }

    private func waitForProxyCount(method: String, greaterThan minimum: Int, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let counts = try? proxyCounts(), counts[method, default: 0] > minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func waitForAnyProxyCount(greaterThan minimum: Int, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let counts = try? proxyCounts(), counts.values.reduce(0, +) > minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func broadcastCount() throws -> Int {
        let counts = try proxyCounts()
        return counts["sendBoc", default: 0] + counts["sendBocReturnHash", default: 0]
    }

    private func waitForBroadcastCount(greaterThan minimum: Int, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let count = try? broadcastCount(), count > minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func synchronousData(request: URLRequest, description: String) throws -> Data {
        let completed = expectation(description: description)
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { completed.fulfill() }
            do {
                if let error { throw error }
                let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                result = .success(try XCTUnwrap(data))
            } catch {
                result = .failure(error)
            }
        }.resume()
        wait(for: [completed], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    private func localnetTransfer(address: String, amount: Double) throws -> (before: UInt64, after: UInt64) {
        let endpoint = ProcessInfo.processInfo.environment["TOS_LOCALNET_CONTROL_URL"]
            ?? "http://127.0.0.1:18745"
        let url = try XCTUnwrap(URL(string: endpoint + "/transfer"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "address": address,
            "amount": amount,
        ])
        let data = try synchronousData(request: request, description: "localnet faucet transfer")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (
            try XCTUnwrap(UInt64(try XCTUnwrap(object["before"] as? String))),
            try XCTUnwrap(UInt64(try XCTUnwrap(object["after"] as? String)))
        )
    }

}
