import XCTest
import DeltaCore
import os

@MainActor
private final class AssignedPad: NSObject, @preconcurrency DeltaCore.GameController {
    let name = "Assignment test pad"
    var playerIndex: Int?
    let inputType = GameControllerInputType.mfi
    var defaultInputMapping: GameControllerInputMappingProtocol? { Switch2InputMapping.defaultMapping }
}
@MainActor
private final class AssignmentReceiver: @preconcurrency GameControllerReceiver {
    var active: Set<String> = []
    var releasedPlayers: [Int?] = []
    func gameController(_ gameController: DeltaCore.GameController, didActivate input: Input, value: Double) {
        active.insert(input.stringValue)
    }
    func gameController(_ gameController: DeltaCore.GameController, didDeactivate input: Input) {
        active.remove(input.stringValue); releasedPlayers.append(gameController.playerIndex)
    }
}
@MainActor
final class TVControllerRegistryTests: XCTestCase {
    func testDSTouchTriggerIsReservedOnlyForTheCore() {
        let base = Switch2InputMapping.defaultMapping
        let input = MFiGameController.Input.rightTrigger
        XCTAssertEqual(TVDSControllerMapping(base: base).input(forControllerInput: input)?.stringValue, "r2")
        XCTAssertNil(TVDSControllerMapping(base: base, reservesTouch: true).input(forControllerInput: input))
        XCTAssertEqual(TVDSControllerMapping(base: base, reservesTouch: true, touchCursorMode: true).input(forControllerInput: input)?.stringValue, "r2")
        XCTAssertNil(TVDSControllerMapping(base: base, reservesTouch: true, touchCursorMode: true).input(forControllerInput: MFiGameController.Input.a))
        let pad = AssignedPad(), receiver = AssignmentReceiver()
        pad.addReceiver(receiver, inputMapping: TVDSControllerMapping(base: base, reservesTouch: true))
        pad.activate(input)
        XCTAssertTrue(receiver.active.isEmpty)
    }

    func testNavigationStopsBelowThresholdAndIgnoresUnrelatedRelease() async {
        let navigation = TVControllerNavigation(), pad = AssignedPad(), other = AssignedPad()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: .tvControllerNavigation, object: nil, queue: .main) { _ in count.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer); navigation.stopRepeating() }
        navigation.gameController(pad, didActivate: StandardGameControllerInput.leftThumbstickUp, value: 0.8)
        navigation.gameController(pad, didActivate: StandardGameControllerInput.leftThumbstickUp, value: 0.3)
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(count.withLock { $0 }, 1)
        navigation.gameController(pad, didActivate: StandardGameControllerInput.up, value: 1)
        navigation.gameController(other, didDeactivate: StandardGameControllerInput.up)
        navigation.gameController(pad, didDeactivate: StandardGameControllerInput.right)
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(count.withLock { $0 } > 2)
        navigation.gameController(pad, didDeactivate: StandardGameControllerInput.up)
        let stopped = count.withLock { $0 }
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(count.withLock { $0 }, stopped)
    }

    func testReassignmentReleasesSustainedInputsForBothOldPlayers() {
        let registry = GameControllerRegistry()
        let pads = [AssignedPad(), AssignedPad()]
        let receivers = [AssignmentReceiver(), AssignmentReceiver()]
        for index in pads.indices {
            registry.register(pads[index]); pads[index].addReceiver(receivers[index])
            pads[index].sustain(MFiGameController.Input.a)
        }
        registry.assign(pads[0], player: 1)
        XCTAssertEqual(pads[0].playerIndex, 1)
        XCTAssertNil(pads[1].playerIndex)
        for index in pads.indices {
            XCTAssertTrue(receivers[index].active.isEmpty)
            XCTAssertTrue(pads[index].sustainedInputs.isEmpty)
            XCTAssertTrue(pads[index].activatedInputs.isEmpty)
            XCTAssertEqual(receivers[index].releasedPlayers, [index])
        }
    }
    func testUnassignedPadCannotRetainHeldInput() {
        let registry = GameControllerRegistry()
        let pad = AssignedPad(), receiver = AssignmentReceiver()
        registry.register(pad); pad.addReceiver(receiver)
        pad.activate(MFiGameController.Input.start)
        registry.assign(pad, player: nil)
        XCTAssertNil(pad.playerIndex)
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertEqual(receiver.releasedPlayers, [0])
    }
}
