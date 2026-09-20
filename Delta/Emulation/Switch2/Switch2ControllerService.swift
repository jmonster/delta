import UIKit
import Combine
import DeltaCore
import Switch2Kit

@MainActor
protocol Switch2InputObservation: AnyObject
{
    func cancel()
}
extension Switch2ControllerObservation: Switch2InputObservation {}

/// The small injectable boundary is the SDK's public commands and event stream, not a second input model.
@MainActor
protocol Switch2Managing: AnyObject
{
    func start()
    func stop() async
    func discover(for seconds: TimeInterval) throws
    func observeInputs(_ handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) throws -> Switch2InputObservation
    func setPlayerNumber(_ number: Int, for id: Switch2ControllerID) throws
    func setPlayerLEDPattern(_ pattern: UInt8?, for id: Switch2ControllerID) throws
}

extension Switch2ControllerManager: Switch2Managing
{
    func observeInputs(_ handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) throws -> Switch2InputObservation
    {
        return try self.observe(on: .main, handler: handler)
    }
}

@MainActor
final class Switch2ControllerService: ObservableObject
{
    static let shared = Switch2ControllerService(
        manager: Switch2ControllerManager(configuration: .init(maximumControllers: 4)),
        registry: .shared, scenes: Array(UIApplication.shared.connectedScenes))

    enum Phase { case stopped, running, stopping }
    enum SceneEvent { case foreground, activate, deactivate, background, disconnect }
    @Published private(set) var phase = Phase.stopped
    @Published private(set) var controllers: [Switch2GameController] = []
    @Published private(set) var status = String(localized: "Not connected")
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsBluetoothPermission = false
    private(set) var stopTask: Task<Void, Never>?
    var isStarted: Bool { self.phase == .running }
    var isStopping: Bool { self.phase == .stopping }

    private let manager: Switch2Managing
    private let registry: GameControllerRegistry
    private var observation: Switch2InputObservation?
    private var observationGeneration = 0
    private var lifecycle = Set<AnyCancellable>()
    private var foreground = Set<String>()
    private var active = Set<String>()
    private struct Assignment { let playerIndex: Int? }
    private var assignments: [Switch2ControllerID: Assignment] = [:]

    init(manager: Switch2Managing, registry: GameControllerRegistry,
         scenes: [UIScene] = [], notifications: NotificationCenter = .default)
    {
        self.manager = manager
        self.registry = registry
        for scene in scenes where scene.session.role == .windowApplication
        {
            let id = scene.session.persistentIdentifier
            if scene.activationState == .foregroundActive { self.active.insert(id) }
            if scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive { self.foreground.insert(id) }
        }
        let events: [(Notification.Name, SceneEvent)] = [
            (UIScene.willEnterForegroundNotification, .foreground), (UIScene.didActivateNotification, .activate),
            (UIScene.willDeactivateNotification, .deactivate), (UIScene.didEnterBackgroundNotification, .background),
            (UIScene.didDisconnectNotification, .disconnect)
        ]
        for (name, event) in events
        {
            notifications.publisher(for: name).sink { [weak self] notification in
                guard let scene = notification.object as? UIScene, scene.session.role == .windowApplication else { return }
                self?.sceneDidChange(event, id: scene.session.persistentIdentifier)
            }.store(in: &self.lifecycle)
        }
    }

    func sceneDidChange(_ event: SceneEvent, id: String)
    {
        let wasActive = !self.active.isEmpty
        switch event
        {
        case .foreground: self.foreground.insert(id)
        case .activate: self.foreground.insert(id); self.active.insert(id)
        case .deactivate: self.active.remove(id)
        case .background, .disconnect: self.active.remove(id); self.foreground.remove(id)
        }
        if self.foreground.isEmpty { self.stop() }
        else if self.active.isEmpty && wasActive
        {
            self.cancelObservation()
            self.controllers.forEach { $0.releaseInputs() }
        }
        else if !self.active.isEmpty && !wasActive && self.isStarted
        {
            // A fresh observation starts with an authoritative snapshot. Never mix a
            // currentSnapshot read with older reports queued on the previous observer.
            self.subscribe()
        }
    }

    func findControllers()
    {
        guard !self.isStopping else { return }
        self.errorMessage = nil
        self.phase = .running
        self.subscribe()
        guard self.isStarted else { return }
        self.manager.start()
        do { try self.manager.discover(for: 60) }
        catch
        {
            self.errorMessage = String(localized: "Could not start controller discovery. Stop and try again.")
            self.stop()
        }
    }

    func stop()
    {
        guard self.isStarted else { return }
        self.phase = .stopping
        self.cancelObservation()
        for controller in self.controllers { self.remove(controller) }
        self.status = String(localized: "Stopping…")
        self.stopTask = Task {
            await self.manager.stop()
            self.phase = .stopped
            self.status = String(localized: "Disconnected. Choose Find to reconnect.")
        }
    }

    private func cancelObservation()
    {
        self.observationGeneration &+= 1
        self.observation?.cancel()
        self.observation = nil
    }

    private func subscribe()
    {
        guard self.observation == nil, !self.active.isEmpty else { return }
        let generation = self.observationGeneration
        do
        {
            self.observation = try self.manager.observeInputs { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isStarted, !self.active.isEmpty,
                          self.observationGeneration == generation else { return }
                    self.receive(event)
                }
            }
        }
        catch
        {
            self.errorMessage = String(localized: "Could not observe controller input. Stop and try again.")
            self.stop()
        }
    }

    private func receive(_ event: Switch2ControllerEvent)
    {
        let generation = self.observationGeneration
        switch event
        {
        case .snapshot(let snapshot), .status(let snapshot):
            let current = Set(snapshot.controllers.map(\.connectionID))
            for controller in self.controllers where !current.contains(controller.connectionID) { self.remove(controller) }
            for controller in snapshot.controllers
            {
                guard self.isStarted, self.observationGeneration == generation else { return }
                self.connect(controller)
            }
            guard self.isStarted, self.observationGeneration == generation else { return }
            self.needsBluetoothPermission = snapshot.bluetooth == .unauthorized
            switch snapshot.bluetooth
            {
            case .unauthorized: self.status = String(localized: "Allow Bluetooth access for Delta in Settings.")
            case .poweredOff: self.status = String(localized: "Turn on Bluetooth to find controllers.")
            case .unsupported: self.status = String(localized: "Bluetooth controller support is unavailable on this device.")
            case .resetting, .unknown: self.status = String(localized: "Waiting for Bluetooth…")
            case .poweredOn:
                switch snapshot.discovery
                {
                case .scanning: self.status = String(localized: "Searching. Hold the controller’s Sync button.")
                case .connecting: self.status = String(localized: "Connecting controller…")
                case .capacityReached: self.status = String(localized: "Four controllers connected.")
                case .stopped, .paused: self.status = String(localized: "Search finished. Choose Find to search again.")
                }
            }
        case .connected(let value): self.connect(value)
        case .input(let value):
            // A delayed report must not create a controller or replace a newer connection.
            self.controllers.first { $0.id == value.id && $0.connectionID == value.connectionID }?.update(value)
        case .disconnected(let id, _):
            if let controller = self.controllers.first(where: { $0.id == id }) { self.remove(controller) }
        case .failure:
            self.errorMessage = String(localized: "The controller operation failed. Check Bluetooth, then choose Find and hold Sync.")
        case .connectionChanged, .signalStrengthChanged: break
        }
    }

    private func connect(_ value: Switch2Controller)
    {
        guard self.isStarted, !self.active.isEmpty else { return }
        if let old = self.controllers.first(where: { $0.id == value.id && $0.connectionID != value.connectionID }) { self.remove(old) }
        guard self.isStarted, !self.active.isEmpty else { return }
        if let controller = self.controllers.first(where: { $0.connectionID == value.connectionID }) { controller.update(value, isSnapshot: true); return }
        let controller = Switch2GameController(controller: value, manager: self.manager)
        // Own the controller before registration notifies receivers; a synchronous
        // Stop during that notification must retire this controller too.
        self.controllers.append(controller)
        let assignment = self.assignments[value.id]
        if let assignment
        {
            controller.playerIndex = assignment.playerIndex
            self.registry.register(controller, assignPlayerIndex: false)
        }
        else
        {
            self.registry.register(controller)
        }
        guard self.controllers.contains(where: { $0 === controller }) else { return }
        if assignment == nil { self.remember(controller.playerIndex, for: value.id) }
        // Install after registration: a temporary occupied slot must not erase saved intent.
        controller.playerIndexDidChange = { [weak self] index in self?.remember(index, for: value.id) }
        if self.isStarted && !self.active.isEmpty { controller.update(value, isSnapshot: true) }
    }

    private func remove(_ controller: Switch2GameController)
    {
        guard self.controllers.contains(where: { $0 === controller }) else { return }
        self.controllers.removeAll { $0 === controller }
        controller.retire { [registry = self.registry] in registry.unregister(controller) }
    }

    private func remember(_ index: Int?, for id: Switch2ControllerID)
    {
        if self.assignments.count < 64 || self.assignments[id] != nil { self.assignments[id] = Assignment(playerIndex: index) }
    }
}
