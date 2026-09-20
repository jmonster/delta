import XCTest
@testable import DeltaSwitch2Input

final class ControllerInputTests: XCTestCase
{
    func testProFaceLabelsAndMenuButtons()
    {
        let report = ControllerReport(buttons: [.a, .b, .x, .y, .plus, .minus, .home])
        let values = ControllerMapping.values(for: report, model: .pro)
        XCTAssertEqual(Set(values.keys), [.a, .b, .x, .y, .start, .select, .menu])
    }

    func testGameCubeCaptureIsSelectAndClicksRemainDigital()
    {
        let values = ControllerMapping.values(for: .init(buttons: [.capture, .zl, .zr]), model: .gameCube)
        XCTAssertEqual(values, [.select: 1, .leftTrigger: 1, .rightTrigger: 1])
    }

    func testProCaptureDoesNotGenerateAnExtraButton()
    {
        XCTAssertTrue(ControllerMapping.values(for: .init(buttons: [.capture, .c]), model: .pro).isEmpty)
    }

    func testShouldersAndDPad()
    {
        let values = ControllerMapping.values(for: .init(buttons: [.up, .down, .left, .right, .l, .r, .zl, .zr]), model: .pro)
        XCTAssertEqual(Set(values.keys), [.up, .down, .left, .right, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger])
    }

    func testLeftJoyConHorizontalOrientation()
    {
        let values = ControllerMapping.values(for: .init(buttons: [.up, .minus, .capture, .sl, .sr], leftStick: .init(x: 0, y: 1)), model: .joyConLeft)
        XCTAssertEqual(values, [.y: 1, .start: 1, .menu: 1, .leftShoulder: 1, .rightShoulder: 1, .leftThumbstickLeft: 1])
    }

    func testRightJoyConHorizontalOrientation()
    {
        let values = ControllerMapping.values(for: .init(buttons: [.a, .plus, .home, .c], rightStick: .init(x: 0, y: 1)), model: .joyConRight)
        XCTAssertEqual(values, [.b: 1, .start: 1, .menu: 1, .select: 1, .leftThumbstickRight: 1])
        XCTAssertNil(values[.rightThumbstickRight])
    }

    func testAllHorizontalFaceButtons()
    {
        for (source, destination) in [(ControllerButton.up, ControllerInput.y), (.right, .x), (.down, .a), (.left, .b)]
        {
            XCTAssertEqual(ControllerMapping.values(for: .init(buttons: [source]), model: .joyConLeft), [destination: 1])
        }
        for (source, destination) in [(ControllerButton.a, ControllerInput.b), (.b, .y), (.x, .a), (.y, .x)]
        {
            XCTAssertEqual(ControllerMapping.values(for: .init(buttons: [source]), model: .joyConRight), [destination: 1])
        }
    }

    func testIndependentSticksAndPositiveUp()
    {
        let values = ControllerMapping.values(for: .init(leftStick: .init(x: 0, y: 1), rightStick: .init(x: -1, y: 0)), model: .pro)
        XCTAssertEqual(values, [.leftThumbstickUp: 1, .rightThumbstickLeft: 1])
    }

    func testDeadZoneAndRescaling()
    {
        XCTAssertTrue(ControllerMapping.values(for: .init(leftStick: .init(x: 0.1, y: 0.1)), model: .pro).isEmpty)
        let values = ControllerMapping.values(for: .init(leftStick: .init(x: 0.575, y: 0)), model: .pro)
        XCTAssertEqual(values[.leftThumbstickRight]!, 0.5, accuracy: 0.000001)
    }

    func testDiagonalIsBoundedAndInvalidValuesAreNeutral()
    {
        let values = ControllerMapping.values(for: .init(leftStick: .init(x: 1, y: 1)), model: .pro)
        XCTAssertEqual(hypot(values[.leftThumbstickRight]!, values[.leftThumbstickUp]!), 1, accuracy: 0.000001)
        XCTAssertEqual(Stick(x: .nan, y: .infinity), Stick())
        XCTAssertEqual(Stick(x: 9, y: -9), Stick(x: 1, y: -1))
    }

    func testReleaseBeforeOppositeDirectionAndNoDuplicatePresses()
    {
        var state = InputState()
        XCTAssertEqual(state.update([.a: 1, .leftThumbstickLeft: 1]).activated.count, 2)
        XCTAssertTrue(state.update([.a: 1, .leftThumbstickLeft: 1]).activated.isEmpty)
        let changed = state.update([.leftThumbstickRight: 0.5])
        XCTAssertEqual(Set(changed.released), [.a, .leftThumbstickLeft])
        XCTAssertEqual(changed.activated, [.leftThumbstickRight: 0.5])
    }

    func testNeutralizationAndMissingStickReleaseEverything()
    {
        var state = InputState()
        let held = ControllerMapping.values(for: .init(buttons: [.a, .home], leftStick: .init(x: 1, y: 0)), model: .pro)
        _ = state.update(held)
        XCTAssertEqual(Set(state.reset().released), Set(held.keys))
        XCTAssertTrue(state.reset().released.isEmpty)
        _ = state.update(held)
        XCTAssertEqual(Set(state.update(ControllerMapping.values(for: .init(), model: .pro)).released), Set(held.keys))
    }
}
