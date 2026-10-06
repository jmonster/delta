import XCTest
import DeltaCore

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
