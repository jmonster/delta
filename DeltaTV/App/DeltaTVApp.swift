// Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.

import GameController
import SwiftUI
import UIKit

@main
final class TVAppDelegate: UIResponder, UIApplicationDelegate
{
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration
    {
        UISceneConfiguration(name: "Delta TV", sessionRole: connectingSceneSession.role)
    }
}

final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate
{
    var window: UIWindow?
    private var coordinator: TVApplicationCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
    {
        guard let scene = scene as? UIWindowScene else { return }
        let coordinator = TVApplicationCoordinator()
        let root = TVRootViewController(model: coordinator.model)
        coordinator.setControllerRouting = { [weak root] isPlaying in
            root?.controllerUserInteractionEnabled = !isPlaying
        }
        self.coordinator = coordinator
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneWillResignActive(_ scene: UIScene)
    {
        // This is synchronous: a local checkpoint must precede suspension.
        // A network backup still requires server acknowledgement in foreground.
        coordinator?.sceneWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene)
    {
        coordinator?.sceneDidBecomeActive()
    }

    func sceneDidDisconnect(_ scene: UIScene)
    {
        coordinator?.stopForSceneDisconnection()
    }
}

/// GCEventViewController is the window root, as required by tvOS controller
/// routing. SwiftUI remains responsible for the focused library and pause menu.
private final class TVRootViewController: GCEventViewController
{
    let model: DeltaTVViewModel

    init(model: DeltaTVViewModel)
    {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        controllerUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad()
    {
        super.viewDidLoad()
        let host = UIHostingController(rootView: DeltaTVRootView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?)
    {
        if !controllerUserInteractionEnabled, presses.contains(where: { $0.type == .menu })
        {
            Task { await model.pause() }
        }
        else
        {
            super.pressesBegan(presses, with: event)
        }
    }
}
