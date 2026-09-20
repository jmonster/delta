import Foundation
import DeltaCore
import Switch2Kit

// DeltaCore's pre-concurrency controller protocol is used on the main actor by this app.
@MainActor
final class Switch2GameController: NSObject, @preconcurrency DeltaCore.GameController
{
    let id: Switch2ControllerID
    let connectionID: UUID
    let model: Switch2ControllerModel
    var name: String { self.model.displayName }
    let inputType: GameControllerInputType = .mfi
    var defaultInputMapping: GameControllerInputMappingProtocol? { Switch2InputMapping.defaultMapping }
    var playerIndexDidChange: ((Int?) -> Void)?
    private let manager: Switch2Managing
    private var physicalInputs: [MFiGameController.Input: Double] = [:]
    private var sequence: UInt64?
    private var activationGeneration = 0
    private var isRetired = false
    private var isDeliveringInputs = false
    private var releasePending = false
    private var retirementCompletion: (() -> Void)?

    var playerIndex: Int? {
        willSet { if newValue != self.playerIndex { self.releaseInputs() } }
        didSet {
            guard !self.isRetired, oldValue != self.playerIndex else { return }
            if let index = self.playerIndex, (0..<4).contains(index)
            {
                try? self.manager.setPlayerLEDPattern(nil, for: self.id)
                try? self.manager.setPlayerNumber(index + 1, for: self.id)
            }
            else { try? self.manager.setPlayerLEDPattern(0, for: self.id) }
            self.playerIndexDidChange?(self.playerIndex)
        }
    }

    init(controller: Switch2Controller, manager: Switch2Managing)
    {
        self.id = controller.id
        self.connectionID = controller.connectionID
        self.model = controller.model
        self.manager = manager
        super.init()
    }

    func update(_ controller: Switch2Controller, isSnapshot: Bool = false)
    {
        guard !self.isRetired, !self.isDeliveringInputs,
              controller.id == self.id, controller.connectionID == self.connectionID,
              self.sequence.map({ controller.state.sequence > $0 || (isSnapshot && controller.state.sequence == $0) }) ?? true else { return }
        self.sequence = controller.state.sequence
        self.isDeliveringInputs = true
        defer {
            self.isDeliveringInputs = false
            if self.releasePending { self.releaseInputs() }
        }
        let values = Switch2InputMapping.values(model: self.model, state: controller.state)
        let released = self.physicalInputs.keys.filter { values[$0] == nil }
        let activated = values.filter { self.physicalInputs[$0.key] != $0.value }
        // Update bookkeeping before invoking receivers, which may synchronously pause input.
        self.physicalInputs = values
        let generation = self.activationGeneration
        for input in released { self.deactivate(input) }
        for (input, value) in activated
        {
            guard generation == self.activationGeneration else { break }
            self.activate(input, value: value)
        }
    }

    func releaseInputs()
    {
        self.activationGeneration &+= 1
        self.physicalInputs.removeAll()
        // DeltaCore visits every receiver synchronously. A receiver can request a
        // stop, but releasing midway would let later receivers see a press after
        // its release. Finish that delivery before neutralizing and unregistering.
        guard !self.isDeliveringInputs else { self.releasePending = true; return }
        self.releasePending = false
        for input in self.sustainedInputs.keys { self.unsustain(input) }
        for input in self.activatedInputs.keys { self.deactivate(input) }
        let completion = self.retirementCompletion
        self.retirementCompletion = nil
        completion?()
    }

    func retire(completion: @escaping () -> Void)
    {
        guard !self.isRetired else { return }
        self.isRetired = true
        self.playerIndexDidChange = nil
        self.retirementCompletion = completion
        self.releaseInputs()
    }
}
