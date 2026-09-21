import Combine
import Observation
import DeltaCore

extension Notification.Name
{
    static let deltaControllerDidConnect = Notification.Name("DeltaControllerDidConnect")
    static let deltaControllerDidDisconnect = Notification.Name("DeltaControllerDidDisconnect")
    static let deltaControllerAssignmentDidChange = Notification.Name("DeltaControllerAssignmentDidChange")
}

/// App-owned registry for native and additional input providers. DeltaCore remains unchanged.
@MainActor @Observable
final class GameControllerRegistry
{
    static let shared = GameControllerRegistry(automaticallyAssignsPlayerIndexes:
        ExternalGameControllerManager.shared.automaticallyAssignsPlayerIndexes)

    private(set) var connectedControllers: [GameController] = []
    let automaticallyAssignsPlayerIndexes: Bool
    private let notifications: NotificationCenter
    @ObservationIgnored private var monitoring = Set<AnyCancellable>()

    init(automaticallyAssignsPlayerIndexes: Bool = true, notifications: NotificationCenter = .default)
    {
        self.automaticallyAssignsPlayerIndexes = automaticallyAssignsPlayerIndexes
        self.notifications = notifications
    }

    func startMonitoring()
    {
        guard self.monitoring.isEmpty else { return }
        let native = ExternalGameControllerManager.shared
        // Allocate players across all providers, including native devices arriving later.
        native.automaticallyAssignsPlayerIndexes = false
        for name in [Notification.Name.externalGameControllerDidConnect, .externalGameControllerDidDisconnect]
        {
            self.notifications.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let controller = notification.object as? GameController else { return }
                    if name == .externalGameControllerDidConnect { self?.register(controller) }
                    else { self?.unregister(controller) }
                }.store(in: &self.monitoring)
        }
        native.startMonitoring()
        for controller in native.connectedControllers { self.register(controller) }
    }

    func register(_ controller: GameController, assignPlayerIndex: Bool = true)
    {
        guard !self.connectedControllers.contains(where: { $0 === controller }) else { return }
        let occupied = Set(self.connectedControllers.compactMap(\.playerIndex))
        if assignPlayerIndex && self.automaticallyAssignsPlayerIndexes
        {
            controller.playerIndex = (0..<4).first { !occupied.contains($0) }
        }
        else if let index = controller.playerIndex, !(0..<4).contains(index) || occupied.contains(index)
        {
            controller.playerIndex = nil
        }
        self.connectedControllers.append(controller)
        self.notifications.post(name: .deltaControllerDidConnect, object: controller)
    }

    func unregister(_ controller: GameController)
    {
        guard self.connectedControllers.contains(where: { $0 === controller }) else { return }
        // Release before removing the controller, while its receivers are still attached.
        for input in controller.sustainedInputs.keys { controller.unsustain(input) }
        for input in controller.activatedInputs.keys { controller.deactivate(input) }
        // Receiver callbacks may have already removed this or another controller.
        guard let index = self.connectedControllers.firstIndex(where: { $0 === controller }) else { return }
        self.connectedControllers.remove(at: index)
        self.notifications.post(name: .deltaControllerDidDisconnect, object: controller)
    }

    func assignmentDidChange()
    {
        self.notifications.post(name: .deltaControllerAssignmentDidChange, object: self)
    }
}
