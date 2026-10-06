// tvOS native provider for Delta's shared controller registry contract.
import Combine
import GameController
import DeltaCore

extension Notification.Name {
    static let deltaControllerDidConnect = Notification.Name("DeltaControllerDidConnect")
    static let deltaControllerDidDisconnect = Notification.Name("DeltaControllerDidDisconnect")
    static let deltaControllerAssignmentDidChange = Notification.Name("DeltaControllerAssignmentDidChange")
}

@MainActor
final class GameControllerRegistry: ObservableObject
{
    static let shared = GameControllerRegistry()
    @Published private(set) var connectedControllers: [DeltaCore.GameController] = []
    let automaticallyAssignsPlayerIndexes: Bool
    private let notifications: NotificationCenter
    private var native: [ObjectIdentifier: MFiGameController] = [:]
    private var observations = Set<AnyCancellable>()
    let navigation = TVControllerNavigation()

    init(automaticallyAssignsPlayerIndexes: Bool = true, notifications: NotificationCenter = .default)
    {
        self.automaticallyAssignsPlayerIndexes = automaticallyAssignsPlayerIndexes
        self.notifications = notifications
    }

    func startMonitoring()
    {
        guard observations.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            notifications.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshNative() }.store(in: &observations)
        }
        refreshNative()
    }

    private func refreshNative()
    {
        let devices = GCController.controllers().filter(Self.isGameplayController)
        let current = Set(devices.map(ObjectIdentifier.init))
        for (id, controller) in native where !current.contains(id) { unregister(controller); native[id] = nil }
        for device in devices where native[ObjectIdentifier(device)] == nil {
            device.handlerQueue = .main
            let controller = MFiGameController(controller: device)
            native[ObjectIdentifier(device)] = controller
            register(controller)
        }
    }

    func register(_ controller: DeltaCore.GameController, assignPlayerIndex: Bool = true)
    {
        guard !connectedControllers.contains(where: { $0 === controller }) else { return }
        let occupied = Set(connectedControllers.compactMap(\.playerIndex))
        if assignPlayerIndex && automaticallyAssignsPlayerIndexes { controller.playerIndex = (0..<4).first { !occupied.contains($0) } }
        else if let index = controller.playerIndex, !(0..<4).contains(index) || occupied.contains(index) { controller.playerIndex = nil }
        connectedControllers.append(controller)
        if controller is Switch2GameController { controller.addReceiver(navigation) }
        notifications.post(name: .deltaControllerDidConnect, object: controller)
    }

    func unregister(_ controller: DeltaCore.GameController)
    {
        releaseInputs(controller)
        guard let index = connectedControllers.firstIndex(where: { $0 === controller }) else { return }
        connectedControllers.remove(at: index)
        controller.removeReceiver(navigation)
        notifications.post(name: .deltaControllerDidDisconnect, object: controller)
    }

    func assign(_ controller: DeltaCore.GameController, player: Int?)
    {
        releaseInputs(controller)
        if let player, let other = connectedControllers.first(where: { $0 !== controller && $0.playerIndex == player }) {
            releaseInputs(other)
            other.playerIndex = nil
        }
        controller.playerIndex = player
        assignmentDidChange()
    }

    func assignmentDidChange()
    {
        objectWillChange.send()
        notifications.post(name: .deltaControllerAssignmentDidChange, object: self)
    }

    private func releaseInputs(_ controller: DeltaCore.GameController)
    {
        for input in Array(controller.sustainedInputs.keys) { controller.unsustain(input) }
        for input in Array(controller.activatedInputs.keys) { controller.deactivate(input) }
    }

    private static func isGameplayController(_ controller: GCController) -> Bool
    {
        let profile = controller.physicalInputProfile
        return profile.buttons[GCInputButtonA] != nil && profile.buttons[GCInputButtonB] != nil
            && (profile.dpads[GCInputDirectionPad] != nil || profile.dpads[GCInputLeftThumbstick] != nil)
    }
}
