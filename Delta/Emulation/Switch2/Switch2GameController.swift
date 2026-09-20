#if DELTA_SWITCH2KIT
import Foundation
import DeltaCore
import Switch2Kit
import DeltaSwitch2Input
import DeltaSwitch2Bridge

// DeltaCore's GameController protocol is nonisolated. The service and Delta's
// controller UI confine this adapter to the main thread, like MFiGameController.
final class Switch2GameController: NSObject, DeltaCore.GameController
{
    let id: Switch2ControllerID
    let connectionID: UUID
    let name: String
    let inputType: GameControllerInputType = .mfi
    let defaultInputMapping: GameControllerInputMappingProtocol?
    private let manager: Switch2ControllerManager
    private var inputState = InputState()

    var playerIndex: Int? {
        willSet { self.releaseInputs() }
        didSet {
            if let playerIndex, (0..<4).contains(playerIndex)
            {
                try? self.manager.setPlayerLEDPattern(nil, for: self.id)
                try? self.manager.setPlayerNumber(playerIndex + 1, for: self.id)
            }
            else
            {
                try? self.manager.setPlayerLEDPattern(0, for: self.id)
            }
        }
    }

    init(controller: Switch2Controller, manager: Switch2ControllerManager)
    {
        self.id = controller.id
        self.connectionID = controller.connectionID
        self.name = controller.name
        self.manager = manager
        var mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
        let standardNames = ["leftShoulder": "l1", "leftTrigger": "l2", "rightShoulder": "r1", "rightTrigger": "r2"]
        for input in ControllerInput.allCases
        {
            guard let source = MFiGameController.Input(rawValue: input.rawValue),
                  let destination = StandardGameControllerInput(rawValue: standardNames[input.rawValue] ?? input.rawValue) else {
                preconditionFailure("Switch 2 input vocabulary must match DeltaCore")
            }
            mapping.set(destination, forControllerInput: source)
        }
        self.defaultInputMapping = mapping
        super.init()
    }

    func update(_ controller: Switch2Controller)
    {
        dispatchPrecondition(condition: .onQueue(.main))
        guard controller.connectionID == self.connectionID else { return }
        let values = Switch2InputBridge.values(model: controller.model, state: controller.state)
        self.apply(self.inputState.update(values))
    }

    func releaseInputs()
    {
        dispatchPrecondition(condition: .onQueue(.main))
        // Hold Buttons uses sustained state separate from physical input state.
        // Clear both so a retired peripheral cannot leave a game button held.
        for input in self.sustainedInputs.keys { self.unsustain(input) }
        self.apply(self.inputState.reset())
        for input in self.activatedInputs.keys { self.deactivate(input) }
    }

    private func apply(_ changes: InputChanges)
    {
        // Releases precede presses when a stick crosses through center.
        for input in changes.released
        {
            if let input = MFiGameController.Input(rawValue: input.rawValue) { self.deactivate(input) }
        }
        for (input, value) in changes.activated
        {
            if let input = MFiGameController.Input(rawValue: input.rawValue) { self.activate(input, value: value) }
        }
    }
}
#endif
