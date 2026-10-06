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
            case .unsupportedGame: return "This game does not match a linked emulator core."
            case .failedToStart: return "The emulator could not start this cartridge. Check its format and try again."
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
        let type: GameType
    }

    /// Preserve each provider's mapping; cursor mode reserves DS touch controls.
    private struct ControllerMapping: GameControllerInputMappingProtocol
    {
        let base: GameControllerInputMappingProtocol?
        var touchCursorMode = false
        let gameControllerInputType = GameControllerInputType.mfi

        func input(forControllerInput input: Input) -> Input?
        {
            let mapped = base?.input(forControllerInput: input)
            if touchCursorMode, let mapped,
               ["up", "down", "left", "right", "a", "b"].contains(mapped.stringValue) { return nil }
            return mapped
        }
    }

    private(set) var gameID: String?
    private(set) var viewController: UIViewController?
    private(set) var isPaused = false
    var onPauseRequested: (() -> Void)?
    var onControllersChanged: ((Int) -> Void)?
    private let stylus = TVDSStylus()
    private var stylusInputs: [String: Double] = [:]
    private(set) var touchCursorMode = false
    var hasDSTouch: Bool { system == .ds }
    /// Called with an immutable copy, never the live file the emulator mutates.
    var onBatterySave: ((String, UInt64, URL) -> Void)?
    var onFailure: ((String, UInt64, Error) -> Void)?
    private let checkpointSequence = OSAllocatedUnfairLock(initialState: UInt64(0))
    var latestCheckpointSequence: UInt64 { checkpointSequence.withLock { $0 } }

    private var system: TVSystem?
    var batterySavedSuccessfully: Bool { system?.batterySavedSuccessfully == true }
    private var core: EmulatorCore?
    private var gameView: GameView?
    private var controllers: [ObjectIdentifier: DeltaCore.GameController] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var checkpointTimer: Timer?
    private var isInvalidated = false

    var controllerCount: Int
    {
        GameControllerRegistry.shared.connectedControllers.count
    }

    override init()
    {
        super.init()
        for system in TVSystem.allCases { Delta.register(system.core) }
        GameControllerRegistry.shared.startMonitoring()
        for name in [Notification.Name.deltaControllerDidConnect, .deltaControllerDidDisconnect, .deltaControllerAssignmentDidChange]
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
        guard let system = TVSystem(rawValue: system) else { throw SessionError.unsupportedGame }
        guard GameControllerRegistry.shared.connectedControllers.contains(where: { ($0.playerIndex ?? 4) < system.maximumPlayers }) else { throw SessionError.controllerRequired }
        guard FileManager.default.fileExists(atPath: romURL.path) else { throw SessionError.missingROM }
        try TVROMImportPolicy.validateROM(at: romURL)
        try FileManager.default.createDirectory(at: batterySaveURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let game = EmulatorGame(fileURL: romURL, gameSaveURL: batterySaveURL, type: system.core.gameType)
        guard let core = EmulatorCore(game: game) else { throw SessionError.unsupportedGame }
        let gameView = GameView(frame: .zero)
        let renderer = TVGameRendererViewController(gameView: gameView, aspectRatio: system.aspectRatio)
        core.add(gameView)
        if system == .ds {
            stylus.addReceiver(core)
            stylus.onChange = { [weak renderer] point, touching in renderer?.showStylus(point, touching: touching) }
            renderer.showStylus(stylus.point, touching: false)
        }
        let checkpointSequence = self.checkpointSequence
        core.saveHandler = { [weak self] _ in
            let sequence = checkpointSequence.withLock { value in value &+= 1; return value }
            // saveHandler may run on the emulation thread. Snapshot before the
            // bridge can write again, then hand the immutable file to storage.
            guard system.batterySavedSuccessfully else
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
        self.system = system
        self.gameID = gameID
        self.core = core
        self.gameView = gameView
        self.viewController = renderer
        self.isPaused = false
        updateControllers()
        guard core.start(), system.loadedSuccessfully else
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
        stylus.release()
        stylusInputs.removeAll()
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
        guard GameControllerRegistry.shared.connectedControllers.contains(where: { ($0.playerIndex ?? 4) < (system?.maximumPlayers ?? 1) }) else { throw SessionError.controllerRequired }
        guard isPaused else { return }
        updateControllers()
        for controller in controllers.values where (controller.playerIndex ?? 4) < (system?.maximumPlayers ?? 1) { controller.addReceiver(core, inputMapping: ControllerMapping(base: controller.defaultInputMapping, touchCursorMode: touchCursorMode)) }
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
        guard system?.stateSavedSuccessfully == true else { throw SessionError.failedToSave }
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
        try core.load(SaveState(fileURL: url, gameType: system!.core.gameType))
        guard system?.stateLoadedSuccessfully == true else { throw SessionError.failedToLoadState }
        core.save()
    }

    func stop()
    {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        releaseInputs()
        stylus.release()
        if let core { stylus.removeReceiver(core) }
        stylus.onChange = nil
        stylusInputs.removeAll()
        touchCursorMode = false
        core?.stop()
        detachEmulatorInput()
        if let gameView { core?.remove(gameView) }
        for controller in controllers.values { controller.removeReceiver(self) }
        core?.saveHandler = nil
        core = nil
        gameView = nil
        viewController = nil
        gameID = nil
        system = nil
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
        let connected = GameControllerRegistry.shared.connectedControllers
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
                controllers[identifier] = device
            }
            guard let controller = controllers[identifier] else { continue }
            // Registry assignments remain stable across the native and direct
            // Bluetooth providers; only this core's supported slots receive input.
            if let core { controller.removeReceiver(core) }
            let mapping = ControllerMapping(base: controller.defaultInputMapping)
            controller.addReceiver(self, inputMapping: mapping)
            if let core, !isPaused, let player = controller.playerIndex, player < (system?.maximumPlayers ?? 1) { controller.addReceiver(core, inputMapping: ControllerMapping(base: controller.defaultInputMapping, touchCursorMode: touchCursorMode)) }
        }
        onControllersChanged?(connected.count)
        if core != nil, !connected.contains(where: { ($0.playerIndex ?? 4) < (system?.maximumPlayers ?? 1) }), !isPaused { onPauseRequested?() }
    }

    func toggleTouchCursorMode()
    {
        guard system == .ds else { return }
        releaseInputs()
        stylus.release()
        stylusInputs.removeAll()
        touchCursorMode.toggle()
        updateControllers()
    }

    private func handleInput(_ name: String, value: Double?, player: Int?)
    {
        guard core != nil, !isPaused else { return }
        if name == "menu", value != nil { onPauseRequested?(); return }
        guard system == .ds, player == 0 else { return }
        stylusInputs[name] = value
        if touchCursorMode, name == "b", value != nil { toggleTouchCursorMode(); return }
        let left = touchCursorMode ? "left" : "rightThumbstickLeft"
        let right = touchCursorMode ? "right" : "rightThumbstickRight"
        let up = touchCursorMode ? "up" : "rightThumbstickUp"
        let down = touchCursorMode ? "down" : "rightThumbstickDown"
        stylus.move(horizontal: stylusInputs[right, default: 0] - stylusInputs[left, default: 0],
                    vertical: stylusInputs[up, default: 0] - stylusInputs[down, default: 0])
        stylus.press(stylusInputs[touchCursorMode ? "a" : "r2", default: 0] > 0)
    }
}

extension TVEmulationSession: GameControllerReceiver
{
    nonisolated func gameController(_ gameController: DeltaCore.GameController, didActivate input: Input, value: Double)
    {
        // Native handlers and the SDK adapter both deliver on main. Synchronous
        // release prevents a queued touch from surviving pause or disconnection.
        let name = input.stringValue
        let player = gameController.playerIndex
        MainActor.assumeIsolated { handleInput(name, value: value, player: player) }
    }

    nonisolated func gameController(_ gameController: DeltaCore.GameController, didDeactivate input: Input)
    {
        let name = input.stringValue
        let player = gameController.playerIndex
        MainActor.assumeIsolated { handleInput(name, value: nil, player: player) }
    }
}

private final class TVGameRendererViewController: UIViewController
{
    let gameView: GameView
    let aspectRatio: Double
    private let cursor = CAShapeLayer()

    init(gameView: GameView, aspectRatio: Double)
    {
        self.gameView = gameView
        self.aspectRatio = aspectRatio
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad()
    {
        super.viewDidLoad()
        view.backgroundColor = .black
        gameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gameView)
        // Keep each system's native display ratio, including the stacked DS screens.
        NSLayoutConstraint.activate([
            gameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            gameView.widthAnchor.constraint(equalTo: gameView.heightAnchor, multiplier: aspectRatio),
            gameView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
            gameView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor)
        ])
        let fill = gameView.heightAnchor.constraint(equalTo: view.heightAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true
    }

    func showStylus(_ point: CGPoint, touching: Bool)
    {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        if cursor.superlayer == nil { gameView.layer.addSublayer(cursor) }
        let bounds = gameView.bounds
        let center = CGPoint(x: point.x * bounds.width, y: bounds.height / 2 + point.y * bounds.height / 2)
        cursor.path = UIBezierPath(ovalIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)).cgPath
        cursor.fillColor = UIColor.clear.cgColor
        cursor.strokeColor = (touching ? UIColor.systemYellow : UIColor.white).cgColor
        cursor.lineWidth = 2
    }
}
