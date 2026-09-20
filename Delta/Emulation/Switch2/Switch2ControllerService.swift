#if DELTA_SWITCH2KIT
import UIKit
import Combine
import DeltaCore
import Switch2Kit
import DeltaSwitch2Input

@MainActor
final class Switch2ControllerService: ObservableObject
{
    static let shared = Switch2ControllerService()

    @Published private(set) var controllers: [Switch2GameController] = []
    @Published private(set) var status = "Not connected"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStarted = false
    @Published private(set) var isStopping = false
    @Published private(set) var needsBluetoothPermission = false

    private let manager = Switch2ControllerManager(configuration: .init(maximumControllers: 4))
    private var observation: Switch2ControllerObservation?
    private var lifecycle = Set<AnyCancellable>()
    private var epoch: UInt64 = 0
    private var scenePolicy = SceneInputPolicy()
    private struct Assignment { let playerIndex: Int? }
    private var assignments: [Switch2ControllerID: Assignment] = [:]

    private init()
    {
        // Constructing the service does not open the radio or ask permission.
        let scenes = UIApplication.shared.connectedScenes.filter { $0.session.role == .windowApplication }
        self.scenePolicy = SceneInputPolicy(
            foreground: Set(scenes.filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }.map { $0.session.persistentIdentifier }),
            active: Set(scenes.filter { $0.activationState == .foregroundActive }.map { $0.session.persistentIdentifier }))
        let notifications: [Notification.Name] = [UIScene.willEnterForegroundNotification,
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification]
        for name in notifications
        {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] notification in self?.sceneDidChange(notification) }
                .store(in: &self.lifecycle)
        }
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.stop() }.store(in: &self.lifecycle)
    }

    private func sceneDidChange(_ notification: Notification)
    {
        guard let scene = notification.object as? UIScene, scene.session.role == .windowApplication else { return }
        let event: SceneInputPolicy.Event
        switch notification.name
        {
        case UIScene.willEnterForegroundNotification: event = .foreground
        case UIScene.didActivateNotification: event = .activate
        case UIScene.willDeactivateNotification: event = .deactivate
        case UIScene.didEnterBackgroundNotification: event = .background
        case UIScene.didDisconnectNotification: event = .disconnect
        default: return
        }
        self.scenePolicy.receive(event, scene: scene.session.persistentIdentifier)
        if !self.scenePolicy.acceptsInput { self.controllers.forEach { $0.releaseInputs() } }
        if self.scenePolicy.shouldStop { self.stop() }
        else if self.scenePolicy.acceptsInput && self.isStarted { self.reconcile(self.manager.currentSnapshot) }
    }

    func findControllers()
    {
        guard !self.isStopping else { return }
        self.errorMessage = nil
        do
        {
            if self.observation == nil
            {
                self.epoch &+= 1
                let epoch = self.epoch
                self.observation = try self.manager.observe(on: .main) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, self.epoch == epoch, self.isStarted else { return }
                        self.receive(event)
                    }
                }
            }
            self.isStarted = true
            self.status = "Waiting for Bluetooth…"
            self.manager.start()
            try self.manager.discover(for: 60)
        }
        catch
        {
            self.errorMessage = "Could not start controller discovery. Stop and try again."
            self.stop()
        }
    }

    func stop()
    {
        guard self.isStarted, !self.isStopping else { return }
        self.isStarted = false
        self.isStopping = true
        self.epoch &+= 1
        self.observation?.cancel()
        self.observation = nil
        for controller in Array(self.controllers) { self.remove(controller) }
        self.status = "Stopping…"
        self.manager.stop { [weak self] in
            Task { @MainActor in
                self?.isStopping = false
                self?.status = "Disconnected. Choose Find to reconnect."
            }
        }
    }

    private func receive(_ event: Switch2ControllerEvent)
    {
        switch event
        {
        case .snapshot(let snapshot), .status(let snapshot):
            // Both carry authoritative membership. Overflow can replace queued
            // disconnects with a snapshot, so reconcile rather than merely append.
            self.reconcile(snapshot)
        case .connected(let controller), .input(let controller):
            self.update(controller)
        case .disconnected(let id, _):
            if let controller = self.controllers.first(where: { $0.id == id }) { self.remove(controller) }
        case .failure(_, let error):
            self.errorMessage = self.message(for: error)
        case .connectionChanged, .signalStrengthChanged:
            break
        }
    }

    private func reconcile(_ snapshot: Switch2ManagerSnapshot)
    {
        let current = Set(snapshot.controllers.map(\.connectionID))
        for controller in Array(self.controllers) where !current.contains(controller.connectionID)
        {
            self.remove(controller)
        }
        for controller in snapshot.controllers { self.update(controller) }
        self.needsBluetoothPermission = snapshot.bluetooth == .unauthorized
        switch snapshot.bluetooth
        {
        case .unauthorized: self.status = "Allow Bluetooth access for Delta in Settings."
        case .poweredOff: self.status = "Turn on Bluetooth to find controllers."
        case .unsupported: self.status = "Bluetooth controller support is unavailable on this device."
        case .resetting: self.status = "Bluetooth is resetting…"
        case .unknown: self.status = "Waiting for Bluetooth…"
        case .poweredOn:
            switch snapshot.discovery
            {
            case .scanning: self.status = "Searching. Hold the controller’s Sync button."
            case .connecting: self.status = "Connecting controller…"
            case .capacityReached: self.status = "Four controllers connected."
            case .stopped, .paused: self.status = "Search finished. Choose Find to search again."
            }
        }
    }

    private func update(_ value: Switch2Controller)
    {
        if let previous = self.controllers.first(where: { $0.id == value.id && $0.connectionID != value.connectionID })
        {
            self.remove(previous)
        }
        let controller: Switch2GameController
        if let existing = self.controllers.first(where: { $0.connectionID == value.connectionID })
        {
            controller = existing
        }
        else
        {
            controller = Switch2GameController(controller: value, manager: self.manager)
            let registry = ExternalGameControllerManager.shared
            // Preserve a previous in-session assignment only while its slot is
            // free. Never steal a player from a native controller or reset maps.
            if let assignment = self.assignments[value.id]
            {
                controller.playerIndex = assignment.playerIndex.flatMap { index in
                    registry.connectedControllers.contains(where: { $0.playerIndex == index }) ? nil : index
                }
                registry.registerSwitch2Controller(controller, assignPlayerIndex: false)
            }
            else
            {
                registry.registerSwitch2Controller(controller, assignPlayerIndex: true)
            }
            self.controllers.append(controller)
        }
        if self.scenePolicy.acceptsInput { controller.update(value) }
    }

    private func remove(_ controller: Switch2GameController)
    {
        // Session-only, bounded bookkeeping. No device identities are persisted.
        if self.assignments.count < 64 || self.assignments[controller.id] != nil
        {
            self.assignments[controller.id] = Assignment(playerIndex: controller.playerIndex)
        }
        controller.releaseInputs()
        ExternalGameControllerManager.shared.unregisterSwitch2Controller(controller)
        self.controllers.removeAll { $0 === controller }
    }

    private func message(for error: Switch2KitError) -> String
    {
        switch error
        {
        case .bluetoothUnavailable: return "Bluetooth is off, unavailable, or not authorized."
        case .connectionFailed, .protocolFailure, .timedOut:
            return "The controller could not connect or stopped responding. Close other controller apps, then choose Find and hold Sync."
        default: return "The controller operation could not finish. Stop and try again."
        }
    }
}
#endif
