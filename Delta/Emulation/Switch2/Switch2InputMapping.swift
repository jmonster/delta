import Foundation
import DeltaCore
import Switch2Kit

/// One conversion: Switch2Kit's public values to DeltaCore's existing input vocabulary.
enum Switch2InputMapping
{
    typealias Input = MFiGameController.Input

    static let defaultMapping: DeltaCore.GameControllerInputMapping = {
        var mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
        let bindings: [(Input, StandardGameControllerInput)] = [
            (.a, .a), (.b, .b), (.x, .x), (.y, .y),
            (.up, .up), (.down, .down), (.left, .left), (.right, .right),
            (.leftShoulder, .l1), (.rightShoulder, .r1), (.leftTrigger, .l2), (.rightTrigger, .r2),
            (.start, .start), (.select, .select), (.menu, .menu),
            (.leftThumbstickUp, .leftThumbstickUp), (.leftThumbstickDown, .leftThumbstickDown),
            (.leftThumbstickLeft, .leftThumbstickLeft), (.leftThumbstickRight, .leftThumbstickRight),
            (.rightThumbstickUp, .rightThumbstickUp), (.rightThumbstickDown, .rightThumbstickDown),
            (.rightThumbstickLeft, .rightThumbstickLeft), (.rightThumbstickRight, .rightThumbstickRight)
        ]
        for (source, destination) in bindings { mapping.set(destination, forControllerInput: source) }
        return mapping
    }()

    static func values(model: Switch2ControllerModel, state: Switch2ControllerState) -> [Input: Double]
    {
        var values: [Input: Double] = [:]
        let bindings: [(Switch2Buttons, Input)]
        switch model
        {
        case .joyCon2Left:
            // Horizontal, stick on the left: rotate the left half counterclockwise.
            bindings = [(.dpadUp, .y), (.dpadRight, .x), (.dpadDown, .a), (.dpadLeft, .b),
                        (.minus, .start), (.capture, .menu), (.slL, .leftShoulder), (.srL, .rightShoulder),
                        (.l, .leftTrigger)]
        case .joyCon2Right:
            bindings = [(.a, .b), (.b, .y), (.x, .a), (.y, .x), (.plus, .start), (.home, .menu),
                        (.c, .select), (.slR, .leftShoulder), (.srR, .rightShoulder), (.r, .leftTrigger)]
        case .proController2, .nsoGameCube:
            bindings = [(.a, .a), (.b, .b), (.x, .x), (.y, .y),
                        (.dpadUp, .up), (.dpadDown, .down), (.dpadLeft, .left), (.dpadRight, .right),
                        (.l, .leftShoulder), (.r, .rightShoulder), (.plus, .start), (.minus, .select), (.home, .menu)]
            if model == .nsoGameCube && state.buttons.contains(.capture) { values[.select] = 1 }
        }
        for (button, input) in bindings where state.buttons.contains(button) { values[input] = 1 }
        // GameCube travel and click are independent; Delta's trigger inputs are digital.
        switch model
        {
        case .joyCon2Left:
            if state.leftTrigger.isPressed { values[.rightTrigger] = 1 }
        case .joyCon2Right:
            if state.rightTrigger.isPressed { values[.rightTrigger] = 1 }
        default:
            if state.leftTrigger.isPressed { values[.leftTrigger] = 1 }
            if state.rightTrigger.isPressed { values[.rightTrigger] = 1 }
        }

        let left: Switch2Stick?
        switch model
        {
        case .joyCon2Left: left = state.leftStick.map { Switch2Stick(x: -$0.y, y: $0.x) }
        case .joyCon2Right: left = state.rightStick.map { Switch2Stick(x: $0.y, y: -$0.x) }
        default: left = state.leftStick
        }
        add(left, horizontal: (.leftThumbstickLeft, .leftThumbstickRight),
            vertical: (.leftThumbstickDown, .leftThumbstickUp), to: &values)
        if model == .proController2 || model == .nsoGameCube
        {
            add(state.rightStick, horizontal: (.rightThumbstickLeft, .rightThumbstickRight),
                vertical: (.rightThumbstickDown, .rightThumbstickUp), to: &values)
        }
        return values
    }

    private static func add(_ stick: Switch2Stick?, horizontal: (Input, Input),
                            vertical: (Input, Input), to values: inout [Input: Double])
    {
        guard let stick else { return }
        let deadZone = 0.15
        let magnitude = hypot(stick.x, stick.y)
        guard magnitude > deadZone else { return }
        let scale = min(1, (magnitude - deadZone) / (1 - deadZone)) / magnitude
        let x = stick.x * scale, y = stick.y * scale
        if x != 0 { values[x < 0 ? horizontal.0 : horizontal.1] = abs(x) }
        if y != 0 { values[y < 0 ? vertical.0 : vertical.1] = abs(y) }
    }
}
