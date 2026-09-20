import Switch2Kit
import DeltaSwitch2Input

public enum Switch2InputBridge
{
    public static func values(model: Switch2ControllerModel, state: Switch2ControllerState) -> [ControllerInput: Double]
    {
        let modelMapping: ControllerModel
        switch model
        {
        case .proController2: modelMapping = .pro
        case .nsoGameCube: modelMapping = .gameCube
        case .joyCon2Left: modelMapping = .joyConLeft
        case .joyCon2Right: modelMapping = .joyConRight
        }

        var report = ControllerReport(
            leftStick: state.leftStick.map { Stick(x: $0.x, y: $0.y) },
            rightStick: state.rightStick.map { Stick(x: $0.x, y: $0.y) })
        let bindings: [(Switch2Buttons, ControllerButton)] = [
            (.a, .a), (.b, .b), (.x, .x), (.y, .y),
            (.dpadUp, .up), (.dpadDown, .down), (.dpadLeft, .left), (.dpadRight, .right),
            (.l, .l), (.r, .r), (.plus, .plus), (.minus, .minus),
            (.home, .home), (.capture, .capture), (.c, .c)
        ]
        for (source, destination) in bindings where state.buttons.contains(source)
        {
            report.buttons.insert(destination)
        }
        // Travel and click are independent on the NSO GameCube controller.
        // Delta's MFi trigger inputs are digital: never invent a click from travel.
        if state.leftTrigger.isPressed { report.buttons.insert(.zl) }
        if state.rightTrigger.isPressed { report.buttons.insert(.zr) }
        if model == .joyCon2Left
        {
            if state.buttons.contains(.slL) { report.buttons.insert(.sl) }
            if state.buttons.contains(.srL) { report.buttons.insert(.sr) }
        }
        if model == .joyCon2Right
        {
            if state.buttons.contains(.slR) { report.buttons.insert(.sl) }
            if state.buttons.contains(.srR) { report.buttons.insert(.sr) }
        }
        return ControllerMapping.values(for: report, model: modelMapping)
    }
}
