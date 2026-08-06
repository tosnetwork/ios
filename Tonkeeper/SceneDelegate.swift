//
//  SceneDelegate.swift
//  Tonkeeper
//
//  Created by Grigory on 22.5.23..
//

import App
import TKCoordinator
import TKFeatureFlags
import TKUIKit
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var launchCoordinator: App.LaunchCoordinator?
    private var privacyShieldView: UIView?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = TKWindow(windowScene: windowScene)
        let coordinator = App.LaunchCoordinator(
            router: TKCoordinator.WindowRouter(window: window),
            remoteConfig: LocalRemoteConfigProvider()
        )

        if let deeplink = connectionOptions.urlContexts.first?.url.absoluteString {
            coordinator.start(deeplink: deeplink)
        } else if let universalLink = connectionOptions.userActivities.first(where: { $0.webpageURL != nil })?.webpageURL {
            coordinator.start(deeplink: universalLink.absoluteString)
        } else {
            coordinator.start(deeplink: nil)
        }

        window.makeKeyAndVisible()

        self.launchCoordinator = coordinator
        self.window = window
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        _ = launchCoordinator?.handleDeeplink(deeplink: url.absoluteString)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }
        _ = launchCoordinator?.handleDeeplink(deeplink: url.absoluteString)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        showPrivacyShield()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard ProcessInfo.processInfo.environment["TOS_UI_TEST_KEEP_PRIVACY_SHIELD"] != "1" else { return }
        hidePrivacyShield()
    }

    private func showPrivacyShield() {
        guard privacyShieldView == nil, let window else { return }

        let shield = UIView(frame: window.bounds)
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shield.backgroundColor = .systemBackground
        shield.accessibilityIdentifier = "app.privacyShield"
        shield.isAccessibilityElement = true
        shield.accessibilityLabel = "TOS Wallet protected"

        let logo = UIImageView(image: UIImage(resource: .icLogo128))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 96),
            logo.heightAnchor.constraint(equalTo: logo.widthAnchor),
        ])

        window.addSubview(shield)
        privacyShieldView = shield
    }

    private func hidePrivacyShield() {
        privacyShieldView?.removeFromSuperview()
        privacyShieldView = nil
    }
}
