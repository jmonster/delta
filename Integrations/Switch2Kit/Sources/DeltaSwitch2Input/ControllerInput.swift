// Pure input policy, shared by the application and hardware-free tests.
import Foundation

public enum ControllerModel: CaseIterable, Sendable
{
    case pro, gameCube, joyConLeft, joyConRight
}

public enum ControllerButton: CaseIterable, Sendable
{
    case a, b, x, y, up, down, left, right
    case l, r, zl, zr, plus, minus, home, capture, c, sl, sr
}

// Names intentionally match DeltaCore.MFiGameController.Input. Using that input
// vocabulary retains Delta's normal per-system defaults and Customize Controls UI.
public enum ControllerInput: String, CaseIterable, Sendable
{
    case a, b, x, y, up, down, left, right
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case start, select, menu
    case leftThumbstickUp, leftThumbstickDown, leftThumbstickLeft, leftThumbstickRight
    case rightThumbstickUp, rightThumbstickDown, rightThumbstickLeft, rightThumbstickRight
}

public struct Stick: Equatable, Sendable
{
    public let x: Double
    public let y: Double

    public init(x: Double = 0, y: Double = 0)
    {
        self.x = x.isFinite ? min(1, max(-1, x)) : 0
        self.y = y.isFinite ? min(1, max(-1, y)) : 0
    }
}

public struct ControllerReport: Sendable
{
    public var buttons: Set<ControllerButton>
    public var leftStick: Stick?
    public var rightStick: Stick?

    public init(buttons: Set<ControllerButton> = [], leftStick: Stick? = nil, rightStick: Stick? = nil)
    {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
    }
}

public enum ControllerMapping
{
    public static func values(for report: ControllerReport, model: ControllerModel) -> [ControllerInput: Double]
    {
        var values = [ControllerInput: Double]()
        func button(_ source: ControllerButton, _ destination: ControllerInput)
        {
            if report.buttons.contains(source) { values[destination] = 1 }
        }

        if model == .joyConLeft
        {
            // Held horizontally, stick on the left: rotate the left half CCW.
            button(.up, .y); button(.right, .x); button(.down, .a); button(.left, .b)
            button(.minus, .start); button(.capture, .menu)
            button(.sl, .leftShoulder); button(.sr, .rightShoulder)
            button(.l, .leftTrigger); button(.zl, .rightTrigger)
        }
        else if model == .joyConRight
        {
            // Held horizontally, stick on the left: rotate the right half CW.
            button(.a, .b); button(.b, .y); button(.x, .a); button(.y, .x)
            button(.plus, .start); button(.home, .menu); button(.c, .select)
            button(.sl, .leftShoulder); button(.sr, .rightShoulder)
            button(.r, .leftTrigger); button(.zr, .rightTrigger)
        }
        else
        {
            button(.a, .a); button(.b, .b); button(.x, .x); button(.y, .y)
            button(.up, .up); button(.down, .down); button(.left, .left); button(.right, .right)
            button(.l, .leftShoulder); button(.r, .rightShoulder)
            button(.zl, .leftTrigger); button(.zr, .rightTrigger)
            button(.plus, .start); button(.minus, .select); button(.home, .menu)
            // The NSO GameCube pad has no Minus. Capture is an in-game Select.
            if model == .gameCube { button(.capture, .select) }
        }

        let left: Stick?
        switch model
        {
        case .joyConLeft: left = report.leftStick.map { Stick(x: -$0.y, y: $0.x) }
        case .joyConRight: left = report.rightStick.map { Stick(x: $0.y, y: -$0.x) }
        default: left = report.leftStick
        }
        add(left, horizontal: (.leftThumbstickLeft, .leftThumbstickRight),
            vertical: (.leftThumbstickDown, .leftThumbstickUp), to: &values)
        if model == .pro || model == .gameCube
        {
            add(report.rightStick, horizontal: (.rightThumbstickLeft, .rightThumbstickRight),
                vertical: (.rightThumbstickDown, .rightThumbstickUp), to: &values)
        }
        return values
    }

    private static func add(_ stick: Stick?, horizontal: (ControllerInput, ControllerInput),
                            vertical: (ControllerInput, ControllerInput), to values: inout [ControllerInput: Double])
    {
        guard let stick else { return }
        // Radial 15% dead zone. Preserve direction, rescale usable travel, cap
        // diagonals at unit radius. Switch2Kit already supplies calibrated axes.
        let magnitude = hypot(stick.x, stick.y)
        guard magnitude > 0.15 else { return }
        let scale = min(1, (magnitude - 0.15) / 0.85) / magnitude
        let x = stick.x * scale, y = stick.y * scale
        if x != 0 { values[x < 0 ? horizontal.0 : horizontal.1] = abs(x) }
        if y != 0 { values[y < 0 ? vertical.0 : vertical.1] = abs(y) }
    }
}

public struct InputChanges: Equatable, Sendable
{
    public let released: [ControllerInput]
    public let activated: [ControllerInput: Double]
}

public struct InputState: Sendable
{
    public private(set) var values: [ControllerInput: Double] = [:]

    public init() {}

    public mutating func update(_ newValues: [ControllerInput: Double]) -> InputChanges
    {
        let released = ControllerInput.allCases.filter { values[$0] != nil && newValues[$0] == nil }
        let activated = newValues.filter { values[$0.key] != $0.value }
        values = newValues
        return InputChanges(released: released, activated: activated)
    }

    public mutating func reset() -> InputChanges
    {
        return update([:])
    }
}
