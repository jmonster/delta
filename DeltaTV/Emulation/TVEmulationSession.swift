//
//  TVEmulationSession.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import DeltaCore
import GBCDeltaCore
import GameController
import UIKit
import os

/// The tvOS shell owns navigation; audio, video and emulation remain DeltaCore's.
@MainActor
final class TVEmulationSession: NSObject
{
    enum SessionError: LocalizedError
    {
        case controllerRequired
        case sceneInactive
        case missingROM
        case incompleteRecovery
        case unsupportedGame
        case failedToStart
        case noSession
        case pauseRequired
        case failedToSave
        case failedToSaveBattery
        case failedToLoadState

        var errorDescription: String?
        {
            switch self
            {
            case .sceneInactive: return "Return to Delta TV before starting a game."
            case .controllerRequired: return "Pair a game controller in Apple TV Settings before playing. The Siri Remote can browse the library."
            case .incompleteRecovery: return "This game’s files or progress are not fully restored. Retry iCloud recovery before playing."
            case .missingROM: return "The local ROM was removed. Restore this game from iCloud before playing."
            case .unsupportedGame: return "This build can play Game Boy and Game Boy Color games."
            case .failedToStart: return "Gambatte could not load this ROM. Check that it is an uncompressed, supported Game Boy game."
            case .noSession: return "No game is running."
            case .pauseRequired: return "Pause the game before saving or loading a state."
            case .failedToSaveBattery: return "The latest in-game progress could not be saved. Free local space and retry before closing this game."
            case .failedToSave: return "The emulator could not write the save state."
            case .failedToLoadState: return "The emulator could not load this state. It may be damaged or from a different core version."
            }
        }
    }

    private struct EmulatorGame: GameProtocol
    {
        let fileURL: URL
        let gameSaveURL: URL
        let type = GameType.gbc
    }

    /// The left shoulder always opens the pause menu, even on a controller whose
    /// Home button tvOS reserves. Other buttons keep Delta's standard mapping.
    private struct ControllerMapping: GameControllerInputMappingProtocol
    {
        let base: GameControllerInputMappingProtocol?
        let gameControllerInputType = GameControllerInputType.mfi

        func input(forControllerInput input: Input) -> Input?
        {
            if input == MFiGameController.Input.leftShoulder { return StandardGameControllerInput.menu }
            return base?.input(forControllerInput: input)
        }
    }

    private(set) var gameID: String?
    private(set) var viewController: UIViewController?
    private(set) var isPaused = false
    var onPauseRequested: (() -> Void)?
    var onControllersChanged: ((Int) -> Void)?
    /// Called with an immutable copy, never the live file the emulator mutates.
    var onBatterySave: ((String, UInt64, URL) -> Void)?
    var onFailure: ((String, UInt64, Error) -> Void)?
    private let checkpointSequence = OSAllocatedUnfairLock(initialState: UInt64(0))
    var latestCheckpointSequence: UInt64 { checkpointSequence.withLock { $0 } }

    private var core: EmulatorCore?
    private var gameView: GameView?
    private var controllers: [ObjectIdentifier: MFiGameController] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var checkpointTimer: Timer?
    private var isInvalidated = false

    var controllerCount: Int
    {
        GCController.controllers().filter { $0.extendedGamepad != nil }.count
    }

    override init()
    {
        super.init()
        Delta.register(GBC.core)
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect]
        {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateControllers() }
            }
            notificationTokens.append(token)
        }
    }

    func start(gameID: String, system: String, romURL: URL, batterySaveURL: URL) throws
    {
        guard core == nil, !isInvalidated else { throw SessionError.failedToStart }
        guard ["gb", "gbc"].contains(system) else { throw SessionError.unsupportedGame }
        guard controllerCount > 0 else { throw SessionError.controllerRequired }
        guard FileManager.default.fileExists(atPath: romURL.path) else { throw SessionError.missingROM }
        try TVROMImportPolicy.validateGameBoyROM(at: romURL)
        try FileManager.default.createDirectory(at: batterySaveURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let game = EmulatorGame(fileURL: romURL, gameSaveURL: batterySaveURL)
        guard let core = EmulatorCore(game: game) else { throw SessionError.unsupportedGame }
        let gameView = GameView(frame: .zero)
        let renderer = TVGameRendererViewController(gameView: gameView)
        core.add(gameView)
        let checkpointSequence = self.checkpointSequence
        core.saveHandler = { [weak self] _ in
            let sequence = checkpointSequence.withLock { value in value &+= 1; return value }
            // saveHandler may run on the emulation thread. Snapshot before the
            // bridge can write again, then hand the immutable file to storage.
            guard GBCEmulatorBridge.shared.lastBatterySaveResult else
            {
                Task { @MainActor in self?.onFailure?(gameID, sequence, SessionError.failedToSaveBattery) }
                return
            }
            // RTC-only cartridges legitimately have a clock sidecar without SRAM.
            let rtc = batterySaveURL.deletingPathExtension().appendingPathExtension("rtc")
            guard FileManager.default.fileExists(atPath: batterySaveURL.path) || FileManager.default.fileExists(atPath: rtc.path) else { return }
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sav")
            do
            {
                if FileManager.default.fileExists(atPath: batterySaveURL.path)
                {
                    try FileManager.default.copyItem(at: batterySaveURL, to: snapshot)
                }
                if FileManager.default.fileExists(atPath: rtc.path)
                {
                    try FileManager.default.copyItem(at: rtc, to: snapshot.deletingPathExtension().appendingPathExtension("rtc"))
                }
                Task { @MainActor in
                    guard let self, let handler = self.onBatterySave else
                    {
                        try? FileManager.default.removeItem(at: snapshot)
                        try? FileManager.default.removeItem(at: snapshot.deletingPathExtension().appendingPathExtension("rtc"))
                        return
                    }
                    handler(gameID, sequence, snapshot)
                }
            }
            catch
            {
                try? FileManager.default.removeItem(at: snapshot)
                try? FileManager.default.removeItem(at: snapshot.deletingPathExtension().appendingPathExtension("rtc"))
                Task { @MainActor in self?.onFailure?(gameID, sequence, error) }
            }
        }
        self.gameID = gameID
        self.core = core
        self.gameView = gameView
        self.viewController = renderer
        self.isPaused = false
        updateControllers()
        guard core.start(), GBCEmulatorBridge.shared.lastLoadResult == 0 else
        {
            core.saveHandler = nil
            stop()
            throw SessionError.failedToStart
        }

        // tvOS can terminate a suspended process without notice. Keep battery
        // RAM checkpointed while playing as well as on pause/background/exit.
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpoint() }
        }
    }

    func pause()
    {
        guard let core, !isPaused else { return }
        releaseInputs()
        core.pause()
        isPaused = true
        detachEmulatorInput()
    }

    func retryBatterySave()
    {
        guard let core, isPaused else { return }
        core.save()
    }

    func resume() throws
    {
        guard let core else { throw SessionError.noSession }
        guard controllerCount > 0 else { throw SessionError.controllerRequired }
        guard isPaused else { return }
        updateControllers()
        for controller in controllers.values { controller.addReceiver(core, inputMapping: ControllerMapping(base: controller.defaultInputMapping)) }
        core.resume()
        isPaused = false
    }

    func saveState(to url: URL) throws
    {
        guard let core else { throw SessionError.noSession }
        guard isPaused else { throw SessionError.pauseRequired }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("state")
        defer { try? FileManager.default.removeItem(at: temporary) }
        core.saveSaveState(to: temporary)
        guard GBCEmulatorBridge.shared.lastSaveStateResult else { throw SessionError.failedToSave }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else { throw SessionError.failedToSave }
        if FileManager.default.fileExists(atPath: url.path)
        {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        }
        else
        {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    func loadState(from url: URL) throws
    {
        guard let core else { throw SessionError.noSession }
        guard isPaused else { throw SessionError.pauseRequired }
        try core.load(SaveState(fileURL: url, gameType: .gbc))
        guard GBCEmulatorBridge.shared.lastLoadStateResult else { throw SessionError.failedToLoadState }
        core.save()
    }

    func stop()
    {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        releaseInputs()
        core?.stop()
        detachEmulatorInput()
        if let gameView { core?.remove(gameView) }
        for controller in controllers.values { controller.removeReceiver(self) }
        core?.saveHandler = nil
        core = nil
        gameView = nil
        viewController = nil
        gameID = nil
        isPaused = false
    }

    func invalidate()
    {
        stop()
        isInvalidated = true
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        controllers.removeAll()
    }

    private func checkpoint()
    {
        guard let core, !isPaused else { return }
        // Pausing synchronizes with the core thread and writes battery RAM.
        // No UI transition is needed for this brief checkpoint.
        core.pause()
        core.resume()
    }

    private func detachEmulatorInput()
    {
        guard let core else { return }
        for controller in controllers.values { controller.removeReceiver(core) }
    }

    private func releaseInputs()
    {
        for controller in controllers.values
        {
            for input in Array(controller.activatedInputs.keys) { controller.deactivate(input) }
        }
    }

    private func updateControllers()
    {
        guard !isInvalidated else { return }
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }
        let identifiers = Set(connected.map { ObjectIdentifier($0) })
        for (identifier, controller) in controllers where !identifiers.contains(identifier)
        {
            for input in Array(controller.activatedInputs.keys) { controller.deactivate(input) }
            if let core { controller.removeReceiver(core) }
            controller.removeReceiver(self)
            controllers.removeValue(forKey: identifier)
        }
        for device in connected
        {
            let identifier = ObjectIdentifier(device)
            if controllers[identifier] == nil
            {
                device.handlerQueue = .main
                controllers[identifier] = MFiGameController(controller: device)
            }
            guard let controller = controllers[identifier] else { continue }
            // The first slice is single-player: any paired full controller can
            // drive player one, so reconnects do not strand the session.
            controller.playerIndex = 0
            let mapping = ControllerMapping(base: controller.defaultInputMapping)
            controller.addReceiver(self, inputMapping: mapping)
            if let core, !isPaused { controller.addReceiver(core, inputMapping: mapping) }
        }
        onControllersChanged?(connected.count)
        if core != nil, connected.isEmpty, !isPaused { onPauseRequested?() }
    }
}

extension TVEmulationSession: GameControllerReceiver
{
    nonisolated func gameController(_ gameController: DeltaCore.GameController, didActivate input: Input, value: Double)
    {
        guard input == StandardGameControllerInput.menu else { return }
        Task { @MainActor [weak self] in
            guard let self, self.core != nil, !self.isPaused else { return }
            self.onPauseRequested?()
        }
    }

    nonisolated func gameController(_ gameController: DeltaCore.GameController, didDeactivate input: Input) {}
}

private final class TVGameRendererViewController: UIViewController
{
    let gameView: GameView

    init(gameView: GameView)
    {
        self.gameView = gameView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad()
    {
        super.viewDidLoad()
        view.backgroundColor = .black
        gameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gameView)
        // Original Game Boy pixels stay square on every TV aspect ratio.
        NSLayoutConstraint.activate([
            gameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            gameView.widthAnchor.constraint(equalTo: gameView.heightAnchor, multiplier: 160.0 / 144.0),
            gameView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
            gameView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor)
        ])
        let fill = gameView.heightAnchor.constraint(equalTo: view.heightAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true
    }
}
