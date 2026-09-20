import XCTest
import DeltaCore
@testable import Switch2Kit

// Only the radio is substituted. The registry, service, adapter, mappings and
// DeltaCore receiver/sustained-input machinery below are production code.
@MainActor
private final class Radio: Switch2Managing
{
    final class Observation: Switch2InputObservation
    {
        var cancelled = false
        func cancel() { self.cancelled = true }
    }
    var handlers: [@Sendable (Switch2ControllerEvent) -> Void] = []
    var observations: [Observation] = []
    var starts = 0
    var stops = 0
    var discoveries: [TimeInterval] = []
    var rejectsObservation = false
    var rejectsDiscovery = false
    var delaysStop = false
    var completion: CheckedContinuation<Void, Never>?
    func start() { self.starts += 1 }
    func stop() async
    {
        self.stops += 1
        if self.delaysStop { await withCheckedContinuation { self.completion = $0 } }
    }
    func discover(for seconds: TimeInterval) throws
    {
        if self.rejectsDiscovery { throw Switch2KitError.invalidParameter }
        self.discoveries.append(seconds)
    }
    func observeInputs(_ handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) throws -> Switch2InputObservation
    {
        if self.rejectsObservation { throw Switch2KitError.observerLimitReached }
        self.handlers.append(handler)
        let observation = Observation()
        self.observations.append(observation)
        return observation
    }
    func setPlayerNumber(_ number: Int, for id: Switch2ControllerID) throws {}
    func setPlayerLEDPattern(_ pattern: UInt8?, for id: Switch2ControllerID) throws {}
    // Can deliberately invoke a retired callback to exercise the host's fence.
    func emit(_ event: Switch2ControllerEvent, observer: Int? = nil)
    {
        self.handlers[observer ?? (self.handlers.count - 1)](event)
    }
}

@MainActor
private final class Receiver: @preconcurrency GameControllerReceiver
{
    var active: [String: Double] = [:]
    var presses: [String] = []
    var releases: [String] = []
    var onPress: (() -> Void)?
    func gameController(_ gameController: GameController, didActivate input: Input, value: Double)
    {
        self.active[input.stringValue] = value
        self.presses.append(input.stringValue)
        self.onPress?()
    }
    func gameController(_ gameController: GameController, didDeactivate input: Input)
    {
        self.active[input.stringValue] = nil
        self.releases.append(input.stringValue)
    }
}

@MainActor
private final class NativeController: NSObject, @preconcurrency GameController
{
    let name = "Native controller"
    var playerIndex: Int?
    let inputType: GameControllerInputType = .mfi
    var defaultInputMapping: GameControllerInputMappingProtocol? { Switch2InputMapping.defaultMapping }
}

@MainActor
final class ControllerIntegrationTests: XCTestCase
{
    private let identity = Switch2ControllerID(rawValue: UUID())
    private let connection = UUID()

    private func device(_ buttons: Switch2Buttons = [], sequence: UInt64 = 1,
                        id: Switch2ControllerID? = nil, connection: UUID? = nil,
                        model: Switch2ControllerModel = .proController2) -> Switch2Controller
    {
        return Switch2Controller(id: id ?? self.identity, model: model,
            state: Switch2ControllerState(buttons: buttons, sequence: sequence),
            connectedAt: Date(timeIntervalSince1970: 0), bodyColor: nil, buttonColor: nil,
            serialNumber: nil, sessionGeneration: connection ?? self.connection, lastActivityAt: 0)
    }

    private func snapshot(_ controllers: [Switch2Controller], bluetooth: Switch2BluetoothState = .poweredOn) -> Switch2ControllerEvent
    {
        return .snapshot(Switch2ManagerSnapshot(isRunning: true, bluetooth: bluetooth,
            discovery: .paused, controllers: controllers, rememberedControllers: []))
    }

    private func setup(autoAssign: Bool = true) -> (Radio, GameControllerRegistry, Switch2ControllerService)
    {
        let radio = Radio()
        let registry = GameControllerRegistry(automaticallyAssignsPlayerIndexes: autoAssign, notifications: NotificationCenter())
        let service = Switch2ControllerService(manager: radio, registry: registry, notifications: NotificationCenter())
        service.sceneDidChange(.activate, id: "game")
        return (radio, registry, service)
    }

    func testConstructionIsRadioSilentAndFindIsExplicit() async
    {
        let (radio, _, service) = self.setup()
        XCTAssertEqual(radio.starts, 0)
        XCTAssertTrue(radio.observations.isEmpty)
        service.findControllers()
        service.findControllers()
        XCTAssertEqual(radio.observations.count, 1)
        XCTAssertEqual(radio.discoveries, [60, 60])
        service.stop()
        await service.stopTask?.value
    }

    func testRegistrationIsIdempotentAndUsesRealReceivers() async
    {
        let (radio, registry, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        radio.emit(self.snapshot([self.device()]))
        XCTAssertEqual(service.controllers.count, 1)
        XCTAssertEqual(registry.connectedControllers.count, 1)
        let receiver = Receiver()
        service.controllers[0].addReceiver(receiver)
        radio.emit(.input(self.device([.a, .home], sequence: 2)))
        XCTAssertEqual(Set(receiver.active.keys), ["a", "menu"])
        radio.emit(.input(self.device(sequence: 3)))
        XCTAssertTrue(receiver.active.isEmpty)
    }

    func testNativeAndSwitchControllersSharePlayerAllocationInEitherOrder() async
    {
        for nativeFirst in [false, true]
        {
            let (radio, registry, service) = self.setup()
            let native = NativeController()
            if nativeFirst { registry.register(native) }
            service.findControllers()
            radio.emit(.connected(self.device()))
            if !nativeFirst { registry.register(native) }
            XCTAssertEqual(Set(registry.connectedControllers.compactMap(\.playerIndex)), [0, 1])
            XCTAssertEqual(registry.connectedControllers.count, 2)
            registry.register(native)
            XCTAssertEqual(registry.connectedControllers.count, 2)
        }
    }

    func testUnassignedAndFullRegistryDoNotStealPlayers() async
    {
        let registry = GameControllerRegistry(notifications: NotificationCenter())
        for _ in 0..<4 { registry.register(NativeController()) }
        let extra = NativeController()
        registry.register(extra)
        XCTAssertNil(extra.playerIndex)
        XCTAssertEqual(Set(registry.connectedControllers.compactMap(\.playerIndex)), [0, 1, 2, 3])
        let (radio, _, service) = self.setup(autoAssign: false)
        service.findControllers()
        radio.emit(.connected(self.device()))
        XCTAssertNil(service.controllers[0].playerIndex)
    }

    func testRegistryReleasesSustainedInputsBeforeDisconnectionNotification() async
    {
        let notifications = NotificationCenter()
        let registry = GameControllerRegistry(notifications: notifications)
        let controller = NativeController()
        let receiver = Receiver()
        registry.register(controller)
        controller.addReceiver(receiver)
        controller.sustain(MFiGameController.Input.a)
        let token = notifications.addObserver(forName: .deltaControllerDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                XCTAssertTrue(receiver.active.isEmpty)
                XCTAssertTrue(registry.connectedControllers.isEmpty)
            }
        }
        registry.unregister(controller)
        notifications.removeObserver(token)
        XCTAssertTrue(controller.sustainedInputs.isEmpty)
        XCTAssertEqual(receiver.releases, ["a"])
    }

    func testDisconnectReleasesPhysicalAndHoldButtons() async
    {
        let (radio, registry, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        let controller = service.controllers[0]
        let receiver = Receiver()
        controller.addReceiver(receiver)
        radio.emit(.input(self.device([.a], sequence: 2)))
        controller.sustain(MFiGameController.Input.b)
        radio.emit(.disconnected(self.identity, .linkLost))
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertTrue(controller.activatedInputs.isEmpty)
        XCTAssertTrue(controller.sustainedInputs.isEmpty)
        XCTAssertTrue(registry.connectedControllers.isEmpty)
    }

    func testPlayerReassignmentReleasesOldPlayerBeforeNextReport() async
    {
        let radio = Radio()
        let controller = Switch2GameController(controller: self.device(), manager: radio)
        controller.playerIndex = 0
        let receiver = Receiver()
        controller.addReceiver(receiver)
        controller.update(self.device([.a]))
        controller.sustain(MFiGameController.Input.b)
        controller.playerIndex = 1
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertTrue(controller.sustainedInputs.isEmpty)
        controller.update(self.device([.a], sequence: 2))
        XCTAssertEqual(receiver.active, ["a": 1])
    }

    func testDuplicateAndOlderReportsDoNotReplayInput() async
    {
        let controller = Switch2GameController(controller: self.device(), manager: Radio())
        let receiver = Receiver()
        controller.addReceiver(receiver)
        controller.update(self.device([.a], sequence: 10))
        controller.update(self.device(sequence: 11))
        controller.update(self.device([.a], sequence: 10))
        controller.update(self.device([.a], sequence: 11))
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertEqual(receiver.presses, ["a"])
    }

    func testReplacingConnectionRejectsLateInputAndReleasesOldState() async
    {
        let (radio, _, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        let old = service.controllers[0]
        let receiver = Receiver()
        old.addReceiver(receiver)
        radio.emit(.input(self.device([.a], sequence: 2)))
        let replacement = self.device(connection: UUID())
        radio.emit(self.snapshot([replacement]))
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertFalse(service.controllers[0] === old)
        radio.emit(.input(self.device([.home], sequence: 3)))
        XCTAssertEqual(service.controllers[0].connectionID, replacement.connectionID)
        XCTAssertTrue(service.controllers[0].activatedInputs.isEmpty)
    }

    func testOverflowSnapshotRemovesMissingControllers() async
    {
        let (radio, registry, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        let controller = service.controllers[0]
        let receiver = Receiver()
        controller.addReceiver(receiver)
        radio.emit(.input(self.device([.a], sequence: 2)))
        radio.emit(self.snapshot([]))
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertTrue(registry.connectedControllers.isEmpty)
        radio.emit(.input(self.device([.a], sequence: 3)))
        XCTAssertTrue(service.controllers.isEmpty)
    }

    func testInterruptionCancelsObserverWithoutStoppingRadioAndResumeRejectsOldPress() async
    {
        let (radio, _, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        let receiver = Receiver()
        service.controllers[0].addReceiver(receiver)
        radio.emit(.input(self.device([.a], sequence: 2)))
        service.sceneDidChange(.deactivate, id: "game")
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertTrue(radio.observations[0].cancelled)
        XCTAssertEqual(radio.stops, 0)
        service.sceneDidChange(.activate, id: "game")
        XCTAssertEqual(radio.observations.count, 2)
        radio.emit(self.snapshot([self.device(sequence: 4)]))
        radio.emit(.input(self.device([.home], sequence: 3)), observer: 0)
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertFalse(receiver.presses.contains("menu"))
        radio.emit(.input(self.device([.b], sequence: 5)))
        XCTAssertEqual(receiver.active, ["b": 1])
    }

    func testFreshObservationReconcilesDisconnectDuringInterruption() async
    {
        let (radio, registry, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        service.sceneDidChange(.deactivate, id: "game")
        service.sceneDidChange(.activate, id: "game")
        radio.emit(self.snapshot([]))
        radio.emit(.connected(self.device()), observer: 0)
        XCTAssertTrue(registry.connectedControllers.isEmpty)
        XCTAssertTrue(service.controllers.isEmpty)
    }

    func testOtherActiveSceneKeepsInputAndLastBackgroundStops() async
    {
        let (radio, _, service) = self.setup()
        service.sceneDidChange(.activate, id: "library")
        service.findControllers()
        service.sceneDidChange(.deactivate, id: "library")
        service.sceneDidChange(.background, id: "library")
        XCTAssertFalse(radio.observations[0].cancelled)
        service.sceneDidChange(.background, id: "game")
        await service.stopTask?.value
        XCTAssertEqual(radio.stops, 1)
        XCTAssertEqual(service.phase, .stopped)
        service.sceneDidChange(.activate, id: "game")
        XCTAssertEqual(radio.starts, 1)
        XCTAssertEqual(service.phase, .stopped)
    }

    func testFindCannotOvertakeAnAsynchronousStop() async
    {
        let (radio, _, service) = self.setup()
        radio.delaysStop = true
        service.findControllers()
        service.stop()
        for _ in 0..<20 where radio.completion == nil { await Task.yield() }
        XCTAssertNotNil(radio.completion)
        service.findControllers()
        XCTAssertEqual(radio.starts, 1)
        XCTAssertEqual(service.phase, .stopping)
        radio.completion?.resume()
        await service.stopTask?.value
        radio.delaysStop = false
        service.findControllers()
        XCTAssertEqual(radio.starts, 2)
        XCTAssertEqual(service.phase, .running)
        radio.emit(.connected(self.device()), observer: 0)
        XCTAssertTrue(service.controllers.isEmpty)
    }

    func testObservationAndDiscoveryErrorsStopCleanly() async
    {
        for observationFailure in [false, true]
        {
            let (radio, _, service) = self.setup()
            radio.rejectsObservation = observationFailure
            radio.rejectsDiscovery = !observationFailure
            service.findControllers()
            await service.stopTask?.value
            XCTAssertNotNil(service.errorMessage)
            XCTAssertEqual(service.phase, .stopped)
            XCTAssertEqual(radio.stops, 1)
        }
    }

    func testPermissionStatusIsVisibleWithoutInventingControllers() async
    {
        let (radio, _, service) = self.setup()
        service.findControllers()
        radio.emit(self.snapshot([], bluetooth: .unauthorized))
        XCTAssertTrue(service.needsBluetoothPermission)
        radio.emit(self.snapshot([], bluetooth: .poweredOff))
        XCTAssertFalse(service.needsBluetoothPermission)
        XCTAssertTrue(service.controllers.isEmpty)
    }

    func testReconnectPreservesDeliberatelyUnassignedPlayer() async
    {
        let (radio, _, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        service.controllers[0].playerIndex = nil
        radio.emit(.disconnected(self.identity, .linkLost))
        radio.emit(.connected(self.device(connection: UUID())))
        XCTAssertNil(service.controllers[0].playerIndex)
    }

    func testOccupiedReconnectSlotPreservesIntentWithoutStealingNativePlayer() async
    {
        let (radio, registry, service) = self.setup()
        service.findControllers()
        radio.emit(.connected(self.device()))
        XCTAssertEqual(service.controllers[0].playerIndex, 0)
        radio.emit(.disconnected(self.identity, .linkLost))
        let native = NativeController()
        registry.register(native)
        radio.emit(.connected(self.device(connection: UUID())))
        XCTAssertNil(service.controllers[0].playerIndex)
        XCTAssertEqual(native.playerIndex, 0)
        radio.emit(.disconnected(self.identity, .linkLost))
        registry.unregister(native)
        radio.emit(.connected(self.device(connection: UUID())))
        XCTAssertEqual(service.controllers[0].playerIndex, 0)
    }

    func testSynchronousPauseDuringInputDeliveryDoesNotReapplyRemainingPresses() async
    {
        let controller = Switch2GameController(controller: self.device(), manager: Radio())
        let receiver = Receiver()
        controller.addReceiver(receiver)
        receiver.onPress = { controller.releaseInputs() }
        controller.update(self.device([.a, .b, .home]))
        XCTAssertTrue(receiver.active.isEmpty)
        XCTAssertTrue(controller.activatedInputs.isEmpty)
        XCTAssertEqual(receiver.presses.count, 1)
    }

    func testTypedDefaultMappingCoversEveryProducedInput() async
    {
        let buttons: Switch2Buttons = [.a, .b, .x, .y, .l, .r, .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .plus, .minus, .home]
        let values = Switch2InputMapping.values(model: .proController2,
            state: .init(buttons: buttons, leftStick: .init(x: -1, y: 1), rightStick: .init(x: 1, y: -1),
                         leftTrigger: .init(isPressed: true), rightTrigger: .init(isPressed: true)))
        for input in values.keys { XCTAssertNotNil(Switch2InputMapping.defaultMapping.input(forControllerInput: input)) }
    }

    func testDigitalClicksStayIndependentOfGameCubeTravel() async
    {
        let travel = Switch2ControllerState(leftTrigger: .init(travel: 1), rightTrigger: .init(travel: 1))
        XCTAssertTrue(Switch2InputMapping.values(model: .nsoGameCube, state: travel).isEmpty)
        let click = Switch2ControllerState(leftTrigger: .init(isPressed: true), rightTrigger: .init(isPressed: true))
        XCTAssertEqual(Switch2InputMapping.values(model: .nsoGameCube, state: click), [.leftTrigger: 1, .rightTrigger: 1])
    }

    func testFaceButtonsMenusAndHandedRails() async
    {
        let left: [(Switch2Buttons, MFiGameController.Input)] = [(.dpadUp, .y), (.dpadRight, .x), (.dpadDown, .a), (.dpadLeft, .b), (.minus, .start), (.capture, .menu), (.slL, .leftShoulder), (.srL, .rightShoulder)]
        let right: [(Switch2Buttons, MFiGameController.Input)] = [(.a, .b), (.b, .y), (.x, .a), (.y, .x), (.plus, .start), (.home, .menu), (.c, .select), (.slR, .leftShoulder), (.srR, .rightShoulder)]
        for (button, input) in left { XCTAssertEqual(Switch2InputMapping.values(model: .joyCon2Left, state: .init(buttons: button)), [input: 1]) }
        for (button, input) in right { XCTAssertEqual(Switch2InputMapping.values(model: .joyCon2Right, state: .init(buttons: button)), [input: 1]) }
        XCTAssertTrue(Switch2InputMapping.values(model: .joyCon2Left, state: .init(buttons: [.slR, .srR])).isEmpty)
        XCTAssertTrue(Switch2InputMapping.values(model: .proController2, state: .init(buttons: [.capture, .c])).isEmpty)
        XCTAssertEqual(Switch2InputMapping.values(model: .nsoGameCube, state: .init(buttons: .capture)), [.select: 1])
    }

    func testSticksRotateRescaleAndNeutralize() async
    {
        XCTAssertEqual(Switch2InputMapping.values(model: .joyCon2Left, state: .init(leftStick: .init(y: 1))), [.leftThumbstickLeft: 1])
        XCTAssertEqual(Switch2InputMapping.values(model: .joyCon2Right, state: .init(rightStick: .init(y: 1))), [.leftThumbstickRight: 1])
        XCTAssertTrue(Switch2InputMapping.values(model: .proController2, state: .init(leftStick: .init(x: 0.1, y: 0.1))).isEmpty)
        let values = Switch2InputMapping.values(model: .proController2, state: .init(leftStick: .init(x: 0.575), rightStick: .init(y: -1)))
        XCTAssertEqual(values[.leftThumbstickRight]!, 0.5, accuracy: 0.000001)
        XCTAssertEqual(values[.rightThumbstickDown], 1)
        let diagonal = Switch2InputMapping.values(model: .proController2, state: .init(leftStick: .init(x: 1, y: 1)))
        XCTAssertEqual(hypot(diagonal[.leftThumbstickRight]!, diagonal[.leftThumbstickUp]!), 1, accuracy: 0.000001)
    }
}
