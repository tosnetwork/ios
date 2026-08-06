import CoreImage
import XCTest

final class TOSWalletUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureMnemonic = "mansion chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction voice"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "1"
        app.launchEnvironment["TOS_RPC_URL"] = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
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

        let wrongInput = app.descendants(matching: .any)["backup.check.input.\(challengedIndexes[0])"]
        wrongInput.tap()
        wrongInput.typeKey("a", modifierFlags: .command)
        wrongInput.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        wrongInput.typeText(phrase[challengedIndexes[0]] ?? "")
        app.descendants(matching: .any)["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Customize your Wallet"].waitForExistence(timeout: 10))
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

    func testFundedFixtureLoadsExactNativeBalanceAndIncomingHistory() {
        importFixtureWalletToHome()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label MATCHES[c] %@", "100([.,]0+)? TOS")
        ).firstMatch.waitForExistence(timeout: 20))

        app.descendants(matching: .any)["History"].tap()
        let amount = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "100", "TOS")
        ).firstMatch
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

        recipient.tap()
        recipient.typeKey("a", modifierFlags: .command)
        recipient.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        recipient.typeText("UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe")
        amount.tap()
        let invalidError = app.staticTexts["Invalid wallet address."]
        let errorRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: invalidError
        )
        XCTAssertEqual(XCTWaiter.wait(for: [errorRemoved], timeout: 10), .completed)
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

    func testNativeSendAmountBoundaries() {
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
        replaceText(in: amount, with: "101")
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: "0.0000000001")
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: "999999999999999999999999999999999999")
        assertCannotContinue(continueButton: continueButton, amountField: amount)
        replaceText(in: amount, with: "-1")
        XCTAssertFalse((amount.value as? String)?.contains("-") == true)
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
        XCTAssertEqual(try rpcEventComment(address: sender, eventID: XCTUnwrap(newEvents.first)), transferComment)
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "0.5", "TOS")
        ).firstMatch.waitForExistence(timeout: 20))
        assertReachableControlsAreAccessible()
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
        endpoint.typeText("127.0.0.1:18545/jsonRPC")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:18545"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchEnvironment["TOS_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        enterPasscode("1234")
        openSettings()
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:18545"].waitForExistence(timeout: 5))

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

    private func openCreatePasscode() {
        let create = app.buttons["Create New Wallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.staticTexts["Create passcode"].waitForExistence(timeout: 5))
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
        app.launchEnvironment["TOS_RPC_URL"] = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
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
                ".*(^|[^A-Za-z])(TON|Tonkeeper|TRON|TRC20|Jetton|NFT|Swap|Staking|Buy|DApp|TonConnect)([^A-Za-z]|$).*"
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

}
