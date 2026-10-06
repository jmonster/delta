// Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.

import DeltaCore
import Foundation
import GBCDeltaCore

@MainActor
final class TVApplicationCoordinator
{
    let model = DeltaTVViewModel()
    var setControllerRouting: ((Bool) -> Void)?

    private let emulator = TVEmulationSession()
    private var store: TVLibraryStore?
    private var synchronizationTask: Task<Void, Never>?
    private var synchronizationRequested = false
    private var isSceneActive = false
    private var lifecycleGeneration: UInt64 = 0
    private var progressErrors: [String: String] = [:]
    private var acceptedCheckpointSequences: [String: UInt64] = [:]

    init()
    {
        model.supportedSystems = TVSystem.allCases.map { TVSupportedSystem(id: $0.rawValue, name: $0.name, fileExtensions: $0.fileExtensions) }
        emulator.onPauseRequested = { [weak self] in self?.pauseForSystemEvent() }
        emulator.onControllersChanged = { [weak self] count in self?.showControllerCount(count) }
        emulator.onFailure = { [weak self] gameID, sequence, error in
            guard let self, sequence > self.acceptedCheckpointSequences[gameID, default: 0] else { return }
            self.acceptedCheckpointSequences[gameID] = sequence
            self.recordProgressFailure(error, gameID: gameID)
        }
        emulator.onBatterySave = { [weak self] gameID, sequence, snapshot in
            defer
            {
                try? FileManager.default.removeItem(at: snapshot)
                try? FileManager.default.removeItem(at: snapshot.deletingPathExtension().appendingPathExtension("rtc"))
            }
            guard let self, let store = self.store, let game = store.games.first(where: { $0.id == gameID }),
                  sequence > self.acceptedCheckpointSequences[gameID, default: 0] else { return }
            self.acceptedCheckpointSequences[gameID] = sequence
            do
            {
                try store.stageBatterySave(for: game, from: snapshot)
                self.progressErrors.removeValue(forKey: gameID)
                self.updatePresentation()
                self.synchronize()
            }
            catch { self.recordProgressFailure(error, gameID: gameID) }
        }
        showControllerCount(emulator.controllerCount)

        do
        {
            let identifier = (Bundle.main.object(forInfoDictionaryKey: "DeltaTVCloudContainerIdentifier") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cloud: TVCloudTransport? = identifier.isEmpty || identifier.hasPrefix("$(") ? nil : TVCloudKitTransport(containerIdentifier: identifier)
            let store = try TVLibraryStore(cloud: cloud)
            self.store = store
            store.onChange = { [weak self] in self?.updatePresentation() }
            installActions()
            updatePresentation()
        }
        catch
        {
            model.cloud = TVCloudPresentation(title: "Library unavailable", detail: error.localizedDescription, severity: .error, allowsRetry: false)
            model.errorMessage = error.localizedDescription
        }
    }

    private func installActions()
    {
        model.actions = TVApplicationActions(
            refresh: { [weak self] in await self?.refresh() },
            restoreLibrary: { [weak self] in await self?.refresh() },
            launch: { [weak self] id in try await self?.launch(id) },
            pause: { [weak self] in self?.pauseForSystemEvent() },
            resume: { [weak self] in try self?.resume() },
            saveState: { [weak self] in try self?.saveState() },
            loadState: { [weak self] in try self?.loadState() },
            exitGame: { [weak self] in try self?.exitGame() },
            importGame: { [weak self] url in try await self?.importGame(url) },
            resolveConflict: { [weak self] id, keepLocal in try await self?.resolveConflict(id, keepLocal: keepLocal) },
            toggleTouchCursor: { [weak self] in
                self?.emulator.toggleTouchCursorMode()
                self?.model.session?.touchCursorMode = self?.emulator.touchCursorMode ?? false
            }
        )
    }

    private func refresh() async
    {
        synchronize()
        await synchronizationTask?.value
    }

    func synchronize()
    {
        synchronizationRequested = true
        guard synchronizationTask == nil else { return }
        synchronizationTask = Task { [weak self] in
            guard let self else { return }
            repeat
            {
                self.synchronizationRequested = false
                await self.store?.synchronize()
                self.updatePresentation()
                // A newer snapshot staged during an await gets another pass.
                // An offline pending status alone does not cause a retry loop.
            } while self.synchronizationRequested
            self.synchronizationTask = nil
        }
    }

    func sceneDidBecomeActive()
    {
        isSceneActive = true
        synchronize()
    }

    func sceneWillResignActive()
    {
        isSceneActive = false
        lifecycleGeneration &+= 1
        pauseForSystemEvent()
    }

    private func resolveConflict(_ id: String, keepLocal: Bool) async throws
    {
        guard let store, model.session == nil else { throw TVInterfaceError.notConfigured }
        try await store.resolveConflict(recordID: id, keepLocal: keepLocal)
        await refresh()
        updatePresentation()
    }

    private func importGame(_ url: URL) async throws
    {
        guard let store else { throw TVInterfaceError.notConfigured }
        let downloadedURL = try await TVROMDownloader.download(url)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        try Task.checkCancellation()
        let title = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        try await store.importGame(at: downloadedURL, title: title, system: TVSystem.system(forExtension: url.pathExtension)!.rawValue)
        updatePresentation()
        // Import cancellation ends at the atomic local commit. Do not hold the
        // import sheet open for a cloud request that has its own visible status.
        synchronize()
        model.notice = "Game imported. Check the iCloud status before relying on this Apple TV to retain it."
    }

    private func launch(_ id: String) async throws
    {
        guard let store, let game = store.games.first(where: { $0.id == id }) else { throw TVInterfaceError.unavailableGame }
        let generation = lifecycleGeneration
        guard isSceneActive else { throw TVEmulationSession.SessionError.sceneInactive }
        if !store.isAvailableLocally(game) { await refresh() }
        try Task.checkCancellation()
        guard isSceneActive, lifecycleGeneration == generation else { throw TVEmulationSession.SessionError.sceneInactive }
        // A force-quit can interrupt the native SAV/RTC pair between writes.
        // Reopen only a coherent journaled checkpoint, including pending saves.
        try await store.prepareForLaunch(game)
        try Task.checkCancellation()
        guard isSceneActive, lifecycleGeneration == generation else { throw TVEmulationSession.SessionError.sceneInactive }
        guard store.isAvailableLocally(game) else { throw TVEmulationSession.SessionError.incompleteRecovery }
        store.activeGameID = game.id
        do
        {
            try emulator.start(gameID: id, system: game.system, romURL: store.romURL(for: game), batterySaveURL: store.batterySaveURL(for: game))
        }
        catch
        {
            store.activeGameID = nil
            throw error
        }
        model.gameViewController = emulator.viewController
        model.session = TVSessionState(gameID: id, title: game.title, isPaused: false, canLoadState: canLoadState(game), hasDSTouch: emulator.hasDSTouch)
        setControllerRouting?(true)
    }

    func pauseForSystemEvent()
    {
        guard let session = model.session else { return }
        let wasPaused = emulator.isPaused
        emulator.pause()
        if wasPaused, progressErrors[session.gameID] != nil { emulator.retryBatterySave() }
        setControllerRouting?(false)
        model.session?.isPaused = true
        model.session?.touchCursorMode = emulator.touchCursorMode
        // Stage immediately on the main actor as well as the core callback.
        // The callback may be queued until after tvOS suspends this scene.
        if let store, let game = currentGame
        {
            let sequence = emulator.latestCheckpointSequence
            if sequence > acceptedCheckpointSequences[game.id, default: 0]
            {
                // A queued older snapshot must never replace this newer attempt,
                // even if the current write fails. Surface the failure instead.
                acceptedCheckpointSequences[game.id] = sequence
                do
                {
                    guard emulator.batterySavedSuccessfully else { throw TVEmulationSession.SessionError.failedToSaveBattery }
                    if FileManager.default.fileExists(atPath: store.batterySaveURL(for: game).path)
                        || FileManager.default.fileExists(atPath: store.batteryRTCURL(for: game).path)
                    {
                        try store.stageBatterySave(for: game)
                    }
                    progressErrors.removeValue(forKey: game.id)
                }
                catch { recordProgressFailure(error, gameID: game.id) }
            }
        }
        synchronize()
        updatePresentation()
    }

    private func resume() throws
    {
        guard isSceneActive else { throw TVEmulationSession.SessionError.sceneInactive }
        try emulator.resume()
        model.session?.isPaused = false
        setControllerRouting?(true)
    }

    private var currentGame: TVGame?
    {
        guard let id = model.session?.gameID else { return nil }
        return store?.games.first { $0.id == id }
    }

    private func saveState() throws
    {
        guard let store, let game = currentGame else { throw TVEmulationSession.SessionError.noSession }
        try emulator.saveState(to: store.saveStateURL(for: game))
        try store.stageSaveState(for: game, coreIdentifier: TVSystem(rawValue: game.system)!.core.identifier, coreVersion: TVSystem(rawValue: game.system)!.coreRevision)
        model.session?.canLoadState = true
        model.notice = "State saved locally. iCloud status shows when the backup is complete."
        synchronize()
        updatePresentation()
    }

    private func canLoadState(_ game: TVGame) -> Bool
    {
        store?.saveStateIsCompatible(game, coreIdentifier: TVSystem(rawValue: game.system)!.core.identifier, coreVersion: TVSystem(rawValue: game.system)!.coreRevision) == true
    }

    private func loadState() throws
    {
        guard let store, let game = currentGame else { throw TVEmulationSession.SessionError.noSession }
        guard canLoadState(game) else { throw TVEmulationSession.SessionError.failedToLoadState }
        try emulator.loadState(from: store.saveStateURL(for: game))
        model.notice = "Saved state loaded. Resume when ready."
    }

    private func exitGame(force: Bool = false) throws
    {
        pauseForSystemEvent()
        if !force, let gameID = model.session?.gameID, progressErrors[gameID] != nil
        {
            // Keep unsaved RAM alive so freeing space and retrying can recover it.
            throw TVEmulationSession.SessionError.failedToSaveBattery
        }
        emulator.stop()
        store?.activeGameID = nil
        setControllerRouting?(false)
        model.gameViewController = nil
        model.session = nil
        updatePresentation()
        synchronize()
    }

    func stopForSceneDisconnection()
    {
        isSceneActive = false
        lifecycleGeneration &+= 1
        try? exitGame(force: true)
        emulator.invalidate()
    }

    private func showControllerCount(_ count: Int)
    {
        model.controllerDescription = count > 0 ? "Game controller connected. Click the left stick to pause, or use the controller’s extra menu buttons." : "Use the Siri Remote to browse. Pair a game controller in Apple TV Settings to play."
    }

    private func recordProgressFailure(_ error: Error, gameID: String)
    {
        progressErrors[gameID] = error.localizedDescription
        model.errorMessage = error.localizedDescription
        updatePresentation()
    }

    private func updatePresentation()
    {
        guard let store else { return }
        model.games = store.games.map {
            TVGameItem(id: $0.id, title: $0.title, systemID: $0.system, isAvailableLocally: store.isAvailableLocally($0), hasCloudBackup: store.hasCloudBackup($0), hasSaveState: store.hasSaveState($0))
        }
        model.conflicts = store.conflicts.map {
            let kind: String
            switch $0.kind
            {
            case .rom: kind = "Game file"
            case .batterySave: kind = "In-game save"
            case .saveState: kind = "Save state (\($0.slot))"
            }
            return TVConflictItem(id: $0.id, gameTitle: $0.game.title, kindDescription: kind)
        }
        let status = store.status
        let title: String
        let severity: TVCloudPresentation.Severity
        switch status.phase
        {
        case .unavailable: title = "iCloud unavailable"; severity = .warning
        case .idle: title = "Library ready"; severity = .information
        case .syncing: title = "Syncing with iCloud"; severity = .information
        case .pending: title = "Backup pending"; severity = .warning
        case .synced: title = "Backed up to iCloud"; severity = .success
        case .conflict: title = "Progress conflict"; severity = .warning
        case .error: title = "iCloud needs attention"; severity = .error
        }
        model.cloud = TVCloudPresentation(title: title, detail: status.message, severity: severity, isWorking: status.phase == .syncing, allowsRetry: status.phase != .syncing && status.phase != .unavailable)
        if let gameID = progressErrors.keys.sorted().first, let error = progressErrors[gameID]
        {
            let title = store.games.first(where: { $0.id == gameID })?.title ?? "Game"
            model.cloud = TVCloudPresentation(title: "Latest progress is not backed up", detail: "\(title): \(error)", severity: .error, allowsRetry: false)
        }
        if let game = currentGame { model.session?.canLoadState = canLoadState(game) }
    }
}
