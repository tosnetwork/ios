//
//  AppDelegate.swift
//  Tonkeeper
//
//  Created by Grigory on 22.5.23..
//

import TKAppInfo
import TKCore
import TKFeatureFlags
import TKLogging
import Security
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        resetStateForUITestsIfRequested()
        Log.configure()

        UNUserNotificationCenter.current().delegate = self

        clearBadgeCount()

        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        clearBadgeCount()
    }
}

private extension AppDelegate {
    func resetStateForUITestsIfRequested() {
        guard ProcessInfo.processInfo.environment["TOS_UI_TEST_RESET"] == "1" else { return }

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        let fileManager = FileManager.default
        for directory in [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory] {
            guard let url = fileManager.urls(for: directory, in: .userDomainMask).first,
                  let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else { continue }
            for item in contents {
                try? fileManager.removeItem(at: item)
            }
        }
        for itemClass in [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassKey,
            kSecClassCertificate,
            kSecClassIdentity,
        ] {
            SecItemDelete([kSecClass: itemClass] as CFDictionary)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        NotificationCenter.default.post(
            name: NSNotification.Name(rawValue: "PushNotificationOpen"),
            object: nil,
            userInfo: response.notification.request.content.userInfo
        )
    }

    func clearBadgeCount() {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
}
