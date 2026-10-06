//
//  DeltaTVViewModel.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import Combine
import Foundation
import UIKit

/// Presentation values are populated from the real library and linked cores.
/// In particular, an empty library must never be replaced with sample games.
struct TVGameItem: Identifiable, Equatable, Sendable
{
    var id: String
    var title: String
    var systemID: String
    var isAvailableLocally: Bool
    var hasCloudBackup: Bool
    var hasSaveState: Bool
    var artworkURL: URL? = nil
}

struct TVSupportedSystem: Identifiable, Equatable, Sendable
{
    var id: String
    var name: String
    var fileExtensions: [String]
}

struct TVCloudPresentation: Equatable, Sendable
{
    enum Severity: Equatable, Sendable
    {
        case information, success, warning, error
    }

    var title: String
    var detail: String
    var severity: Severity = .information
    var isWorking: Bool = false
    var allowsRetry: Bool = true

    static let checking = TVCloudPresentation(title: "Checking iCloud", detail: "Checking the backup available to this Apple TV.", isWorking: true, allowsRetry: false)
}

struct TVSessionState: Equatable, Sendable
{
    var gameID: String
    var title: String
    var isPaused: Bool
    var canSaveState: Bool = true
    var canLoadState: Bool = false
    var hasDSTouch: Bool = false
    var touchCursorMode: Bool = false
}

struct TVConflictItem: Identifiable, Equatable, Sendable
{
    var id: String
    var gameTitle: String
    var kindDescription: String
}

/// The app target installs these actions before presenting the root view.
/// Each action must update the model from its storage or emulation result.
/// A successful download alone is not evidence of a successful cloud backup.
@MainActor
struct TVApplicationActions
{
    var refresh: @MainActor () async throws -> Void
    var restoreLibrary: @MainActor () async throws -> Void
    var launch: @MainActor (String) async throws -> Void
    var pause: @MainActor () async throws -> Void
    var resume: @MainActor () async throws -> Void
    var saveState: @MainActor () async throws -> Void
    var loadState: @MainActor () async throws -> Void
    var exitGame: @MainActor () async throws -> Void
    /// Receives a validated HTTPS URL. The implementation downloads and imports it.
    var importGame: @MainActor (URL) async throws -> Void
    var resolveConflict: @MainActor (String, Bool) async throws -> Void = { _, _ in throw TVInterfaceError.notConfigured }
    var toggleTouchCursor: @MainActor () -> Void = {}

    static var unavailable: TVApplicationActions
    {
        let unavailable: @MainActor () async throws -> Void = { throw TVInterfaceError.notConfigured }
        return TVApplicationActions(refresh: unavailable, restoreLibrary: unavailable,
                                    launch: { _ in throw TVInterfaceError.notConfigured },
                                    pause: unavailable, resume: unavailable,
                                    saveState: unavailable, loadState: unavailable,
                                    exitGame: unavailable,
                                    importGame: { _ in throw TVInterfaceError.notConfigured })
    }
}

enum TVInterfaceError: LocalizedError
{
    case notConfigured
    case unavailableGame
    case invalidURL
    case unsupportedFile

    var errorDescription: String?
    {
        switch self
        {
        case .notConfigured:
            return "The Apple TV library is not ready. Try again after the app finishes starting."
        case .unavailableGame:
            return "This game is not available for a linked Apple TV core."
        case .invalidURL:
            return "Enter a complete https:// address without a username or password."
        case .unsupportedFile:
            return "Use a direct link ending in a supported ROM extension. Compressed archives and web pages cannot be imported."
        }
    }
}

@MainActor
final class DeltaTVViewModel: ObservableObject
{
    @Published var games: [TVGameItem] = []
    @Published var supportedSystems: [TVSupportedSystem] = []
    @Published var cloud: TVCloudPresentation = .checking
    @Published var conflicts: [TVConflictItem] = []
    @Published var session: TVSessionState?
    @Published var gameViewController: UIViewController?
    @Published var controllerDescription = "Use the Siri Remote or a game controller to browse."
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published private(set) var busyTitle: String?

    var actions: TVApplicationActions = .unavailable
    private var operationTask: Task<Void, Error>?

    var isBusy: Bool { busyTitle != nil }

    var playableGames: [TVGameItem]
    {
        let supportedIDs = Set(supportedSystems.map(\.id))
        return games.filter { supportedIDs.contains($0.systemID) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var supportedFileExtensions: Set<String>
    {
        Set(supportedSystems.flatMap(\.fileExtensions).map { $0.lowercased() })
    }

    func systemName(for game: TVGameItem) -> String
    {
        supportedSystems.first { $0.id == game.systemID }?.name ?? game.systemID
    }

    @discardableResult
    func refresh() async -> Bool
    {
        await perform("Checking library", operation: actions.refresh)
    }

    @discardableResult
    func restoreLibrary() async -> Bool
    {
        await perform("Restoring from iCloud", operation: actions.restoreLibrary)
    }

    func launch(_ game: TVGameItem) async
    {
        guard session == nil, !isBusy else { return }
        guard playableGames.contains(where: { $0.id == game.id }) else
        {
            errorMessage = TVInterfaceError.unavailableGame.localizedDescription
            return
        }
        await perform(game.isAvailableLocally ? "Starting \(game.title)" : "Restoring \(game.title)") {
            try await self.actions.launch(game.id)
        }
    }

    func pause() async
    {
        guard session?.isPaused == false else { return }
        await perform("Pausing game", operation: actions.pause)
    }

    func resume() async
    {
        guard session?.isPaused == true else { return }
        await perform("Resuming game", operation: actions.resume)
    }

    func saveState() async
    {
        guard session?.isPaused == true, session?.canSaveState == true else { return }
        await perform("Saving state", operation: actions.saveState)
    }

    func loadState() async
    {
        guard session?.isPaused == true, session?.canLoadState == true else { return }
        await perform("Loading state", operation: actions.loadState)
    }

    func exitGame() async
    {
        guard session != nil else { return }
        await perform("Saving progress and returning to library", operation: actions.exitGame)
    }

    @discardableResult
    func importGame(from text: String) async -> Bool
    {
        guard session == nil, !isBusy else { return false }
        do
        {
            let url = try TVROMImportPolicy.validatedURL(text, allowedExtensions: supportedFileExtensions)
            return await perform("Importing game", cancellationNotice: "Import cancelled.") { try await self.actions.importGame(url) }
        }
        catch
        {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Cancel is only exposed for the network import. Storage must honor
    /// cancellation before committing an import, or finish its atomic commit.
    func cancelOperation()
    {
        operationTask?.cancel()
    }

    func resolveConflict(_ conflict: TVConflictItem, keepLocal: Bool) async
    {
        guard session == nil, conflicts.contains(where: { $0.id == conflict.id }) else { return }
        await perform("Resolving saved progress") {
            try await self.actions.resolveConflict(conflict.id, keepLocal)
        }
    }

    @discardableResult
    private func perform(_ title: String, cancellationNotice: String? = nil, operation: @escaping @MainActor () async throws -> Void) async -> Bool
    {
        guard operationTask == nil else { return false }
        errorMessage = nil
        notice = nil
        busyTitle = title
        let task = Task {
            try Task.checkCancellation()
            try await operation()
        }
        operationTask = task
        defer
        {
            operationTask = nil
            busyTitle = nil
        }

        do
        {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            return true
        }
        catch is CancellationError
        {
            notice = cancellationNotice
            return false
        }
        catch let error as URLError where error.code == .cancelled
        {
            notice = cancellationNotice
            return false
        }
        catch
        {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
