// Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
import DeltaCore
import Foundation

enum TVNavigationCommand: String, Sendable { case up, down, left, right, select, back }
extension Notification.Name { static let tvControllerNavigation = Notification.Name("TVControllerNavigation") }

/// Direct Bluetooth pads do not generate UIKit focus events. Route their mapped
/// buttons to the visible SwiftUI screen while native controllers use UIKit.
@MainActor
final class TVControllerNavigation: GameControllerReceiver
{
    var enabled = true { didSet { if !enabled { stopRepeating() } } }
    private var held: TVNavigationCommand?
    private var timer: Timer?
    private var repeatAfter: Date?

    nonisolated func gameController(_ gameController: DeltaCore.GameController, didActivate input: Input, value: Double)
    {
        MainActor.assumeIsolated {
            guard enabled else { return }
            let command: TVNavigationCommand?
            switch input.stringValue {
            case "up", "leftThumbstickUp": command = .up
            case "down", "leftThumbstickDown": command = .down
            case "left", "leftThumbstickLeft": command = .left
            case "right", "leftThumbstickRight": command = .right
            case "a", "start": command = .select
            case "b", "menu": command = .back
            default: command = nil
            }
            guard let command, value >= 0.5 else { return }
            if [.up, .down, .left, .right].contains(command) {
                guard held != command else { return }
                stopRepeating(); held = command; repeatAfter = Date().addingTimeInterval(0.4)
                timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.enabled, let held = self.held, let after = self.repeatAfter, Date() >= after else { return }
                        self.post(held)
                    }
                }
            }
            post(command)
        }
    }
    nonisolated func gameController(_ gameController: DeltaCore.GameController, didDeactivate input: Input)
    { MainActor.assumeIsolated { if input.isContinuous || ["up", "down", "left", "right"].contains(input.stringValue) { stopRepeating() } } }
    func stopRepeating() { timer?.invalidate(); timer = nil; held = nil; repeatAfter = nil }
    private func post(_ command: TVNavigationCommand)
    { NotificationCenter.default.post(name: .tvControllerNavigation, object: command.rawValue) }
}
