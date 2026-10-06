// Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
import SwiftUI
import DeltaCore

@MainActor
struct TVControllersView: View
{
    @ObservedObject private var service = Switch2ControllerService.shared
    @ObservedObject private var registry = GameControllerRegistry.shared
    let close: () -> Void
    @FocusState private var focus: String?
    private struct Entry: Identifiable {
        let controller: DeltaCore.GameController
        var id: ObjectIdentifier { ObjectIdentifier(controller) }
    }
    private func key(_ controller: DeltaCore.GameController) -> String { String(ObjectIdentifier(controller).hashValue) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Controllers").font(.largeTitle.bold())
                Text("Pair supported standard controllers in Apple TV Settings. NES and SNES controllers keep their Start button as a game input.")
                    .foregroundStyle(.secondary)
                Button("Find Switch 2 Controllers") { service.findControllers() }
                    .focused($focus, equals: "find").disabled(service.isStopping)
                Button("Disconnect Switch 2 Controllers") { service.stop() }
                    .focused($focus, equals: "disconnect").disabled(!service.isStarted || service.isStopping)
                Text(service.status).foregroundStyle(.secondary)
                Text("For the official Switch 2 GameCube controller, choose Find and hold Sync. Up to two direct Bluetooth controllers. Returning from background may require Find and Sync again.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = service.errorMessage { Text(error).foregroundStyle(.orange) }
                ForEach(registry.connectedControllers.map { Entry(controller: $0) }) { entry in
                    let controller = entry.controller
                    Text(controller.name).font(.title3)
                    HStack {
                        ForEach(0..<4) { player in
                            Button(controller.playerIndex == player ? "✓ Player \(player + 1)" : "Player \(player + 1)") {
                                registry.assign(controller, player: player)
                            }.focused($focus, equals: "\(key(controller)):\(player)")
                        }
                        Button("Unassigned") { registry.assign(controller, player: nil) }
                            .focused($focus, equals: "\(key(controller)):-1")
                    }
                }
                Text("Click the left stick to pause. NES controllers use the top shoulder buttons; SNES controllers use ZL or ZR. Start + Select also pauses. Raw Switch 2 Home opens the app menu. Native Home belongs to Apple TV.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("GameCube trigger clicks are mapped separately from their travel. Motion, rumble, mouse input and combined Joy-Con pairs are not exposed by this adapter.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Back", action: close).focused($focus, equals: "back")
            }.padding(70)
        }.onAppear { focus = "find" }.onExitCommand(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: .tvControllerNavigation)) { notification in
            guard let raw = notification.object as? String, let command = TVNavigationCommand(rawValue: raw) else { return }
            if command == .back { close(); return }
            let actions = (service.isStopping ? [] : ["find"]) + (service.isStarted && !service.isStopping ? ["disconnect"] : [])
                + registry.connectedControllers.flatMap { controller in (-1..<4).map { "\(key(controller)):\($0)" } } + ["back"]
            if command == .select {
                if focus == "find", !service.isStopping { service.findControllers() }
                else if focus == "disconnect", service.isStarted { service.stop() }
                else if focus == "back" { close() }
                else if let focus {
                    let parts = focus.split(separator: ":")
                    if parts.count == 2, let player = Int(parts[1]), let controller = registry.connectedControllers.first(where: { key($0) == parts[0] }) {
                        registry.assign(controller, player: player == -1 ? nil : player)
                    }
                }
            } else {
                let index = actions.firstIndex(where: { $0 == focus }) ?? 0
                focus = actions[min(actions.count - 1, max(0, index + (command == .up || command == .left ? -1 : 1)))]
            }
        }
    }
}
