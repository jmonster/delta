// Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
import DeltaCore
import MelonDSDeltaCore
import UIKit

/// The session still receives touch controls; only the DS core reserves them.
struct TVDSControllerMapping: GameControllerInputMappingProtocol
{
    let base: GameControllerInputMappingProtocol?
    var reservesTouch = false
    var touchCursorMode = false
    let gameControllerInputType = GameControllerInputType.mfi

    func input(forControllerInput input: Input) -> Input?
    {
        let mapped = base?.input(forControllerInput: input)
        if reservesTouch, let mapped {
            if touchCursorMode, ["up", "down", "left", "right", "a", "b"].contains(mapped.stringValue) { return nil }
            if !touchCursorMode, mapped.stringValue == "r2" { return nil }
        }
        return mapped
    }
}

/// An app-owned virtual touch input, independent of the physical pad's player slot.
@MainActor
final class TVDSStylus: NSObject, @preconcurrency DeltaCore.GameController
{
    let name = "DS Stylus"
    var playerIndex: Int? = 0
    let inputType = GameControllerInputType("tvDSStylus")
    private enum Axis: String, Input {
        case x, y
        var type: InputType { .controller(GameControllerInputType("tvDSStylus")) }
        var isContinuous: Bool { true }
    }
    private struct Mapping: GameControllerInputMappingProtocol {
        let gameControllerInputType = GameControllerInputType("tvDSStylus")
        func input(forControllerInput input: Input) -> Input? {
            switch input.stringValue {
            case "x": MelonDSGameInput.touchScreenX
            case "y": MelonDSGameInput.touchScreenY
            default: nil
            }
        }
    }
    var defaultInputMapping: GameControllerInputMappingProtocol? { Mapping() }
    private(set) var point = CGPoint(x: 0.5, y: 0.5)
    var onChange: ((CGPoint, Bool) -> Void)?
    private var velocity = CGVector.zero
    private var contact = false
    private var timer: Timer?

    func move(horizontal: Double, vertical: Double)
    {
        velocity = CGVector(dx: horizontal, dy: vertical)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }
    func press(_ pressed: Bool) { contact = pressed; publish() }
    func release()
    {
        timer?.invalidate(); timer = nil; velocity = .zero; contact = false
        deactivate(Axis.x)
        deactivate(Axis.y)
        onChange?(point, false)
    }
    private func tick()
    {
        point.x = min(1, max(0, point.x + velocity.dx / 90))
        point.y = min(1, max(0, point.y - velocity.dy / 70))
        publish()
    }
    private func publish()
    {
        if contact {
            activate(Axis.x, value: point.x)
            activate(Axis.y, value: point.y)
        } else {
            deactivate(Axis.x)
            deactivate(Axis.y)
        }
        onChange?(point, contact)
    }
}
