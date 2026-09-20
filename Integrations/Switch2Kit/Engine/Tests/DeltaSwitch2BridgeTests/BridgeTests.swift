import XCTest
import Switch2Kit
import DeltaSwitch2Bridge

final class BridgeTests: XCTestCase
{
    func testAnalogTravelDoesNotBecomeDigitalClick()
    {
        let travel = Switch2ControllerState(leftTrigger: .init(travel: 1), rightTrigger: .init(travel: 0.9))
        XCTAssertTrue(Switch2InputBridge.values(model: .nsoGameCube, state: travel).isEmpty)
        let clicks = Switch2ControllerState(leftTrigger: .init(isPressed: true, travel: 0), rightTrigger: .init(isPressed: true))
        XCTAssertEqual(Switch2InputBridge.values(model: .nsoGameCube, state: clicks), [.leftTrigger: 1, .rightTrigger: 1])
    }

    func testProNamedButtonsAndAxes()
    {
        let state = Switch2ControllerState(buttons: [.a, .home, .plus, .minus], leftStick: .init(x: 1, y: 0), rightStick: .init(x: 0, y: -1))
        XCTAssertEqual(Switch2InputBridge.values(model: .proController2, state: state), [.a: 1, .menu: 1, .start: 1, .select: 1, .leftThumbstickRight: 1, .rightThumbstickDown: 1])
    }

    func testHandedRailsAreNotMixed()
    {
        let left = Switch2ControllerState(buttons: [.slL, .srR], leftStick: .init(x: 0, y: 1))
        XCTAssertEqual(Switch2InputBridge.values(model: .joyCon2Left, state: left), [.leftShoulder: 1, .leftThumbstickLeft: 1])
        let right = Switch2ControllerState(buttons: [.slL, .srR], rightStick: .init(x: 0, y: -1))
        XCTAssertEqual(Switch2InputBridge.values(model: .joyCon2Right, state: right), [.rightShoulder: 1, .leftThumbstickLeft: 1])
    }
}
