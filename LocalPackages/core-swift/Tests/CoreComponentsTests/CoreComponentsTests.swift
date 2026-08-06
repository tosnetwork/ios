//
//  CoreComponentsTests.swift
//
//
//  Created by Grigory Serebryanyy on 14.01.2024.
//

@testable import CoreComponents
import TKKeychain
import XCTest

final class CoreComponentsTests: XCTestCase {
    func testPasswordUsesDeviceOnlyUnlockedKeychainWithBiometry() throws {
        let keychain = KeychainVaultSpy()
        let vault = MnemonicsVault(keychainVault: keychain, seedProvider: { "test" })

        try vault.savePassword("secret")

        let query = try XCTUnwrap(keychain.lastSetQuery)
        guard case .whenUnlockedThisDeviceOnly = query.accessible else {
            return XCTFail("Password must not be migratable or readable while locked")
        }
        guard case .any = query.biometry else {
            return XCTFail("Password query must require enrolled biometry")
        }
    }
}

private final class KeychainVaultSpy: TKKeychainVault {
    var lastSetQuery: TKKeychainQuery?

    func get(query: TKKeychainQuery) throws -> Data { throw TKKeychainVaultError.unexpectedData }
    func get(query: TKKeychainQuery) throws -> String { throw TKKeychainVaultError.unexpectedData }
    func get<T: Codable>(query: TKKeychainQuery) throws -> T { throw TKKeychainVaultError.unexpectedData }

    func set(_ value: Data, query: TKKeychainQuery) throws { lastSetQuery = query }
    func set(_ value: String, query: TKKeychainQuery) throws { lastSetQuery = query }
    func set<T: Codable>(_ value: T, query: TKKeychainQuery) throws { lastSetQuery = query }

    func delete(_ query: TKKeychainQuery) throws {}
}
