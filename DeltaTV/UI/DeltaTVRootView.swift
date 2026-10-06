//
//  DeltaTVRootView.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import SwiftUI
import UIKit

@MainActor
struct DeltaTVRootView: View
{
    @ObservedObject var model: DeltaTVViewModel
    @FocusState private var focusedItem: LibraryFocus?
    @State private var presentedSheet: LibrarySheet?
    @State private var lastSelectedGameID: String?

    private enum LibraryFocus: Hashable
    {
        case game(String), importGame, restore, cloud, controllers
    }

    private enum LibrarySheet: String, Identifiable
    {
        case importGame, cloud, controllers
        var id: String { rawValue }
    }

    var body: some View
    {
        ZStack
        {
            TVTheme.background.ignoresSafeArea()

            if let session = model.session
            {
                gameScreen(session)
            }
            else
            {
                library
            }
        }
        .tint(TVTheme.purple)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $presentedSheet, onDismiss: restoreLibraryFocus) { sheet in
            switch sheet
            {
            case .importGame:
                TVImportView(model: model) { presentedSheet = nil }
            case .cloud:
                TVCloudView(model: model) { presentedSheet = nil }
            case .controllers:
                TVControllersView { presentedSheet = nil }
            }
        }
        .task
        {
            await model.refresh()
            restoreLibraryFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvControllerNavigation)) { notification in
            guard model.session == nil, presentedSheet == nil, let raw = notification.object as? String,
                  let command = TVNavigationCommand(rawValue: raw) else { return }
            navigate(command)
        }
        .onChange(of: model.session?.gameID) { _, gameID in
            if gameID == nil { restoreLibraryFocus() }
        }
        .onChange(of: model.playableGames.map(\.id)) { _, _ in
            guard model.session == nil, presentedSheet == nil else { return }
            if case .game(let id)? = focusedItem,
               !model.playableGames.contains(where: { $0.id == id })
            {
                restoreLibraryFocus()
            }
            else if focusedItem == nil
            {
                restoreLibraryFocus()
            }
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if !isBusy, model.session == nil, presentedSheet == nil, focusedItem == nil
            {
                restoreLibraryFocus()
            }
        }
    }

    private func navigate(_ command: TVNavigationCommand)
    {
        let actions: [LibraryFocus] = [.importGame, .restore, .cloud, .controllers]
        let games = model.playableGames
        if command == .select {
            guard !model.isBusy else { return }
            switch focusedItem {
            case .importGame: presentedSheet = .importGame
            case .restore: Task { await model.restoreLibrary() }
            case .cloud: presentedSheet = .cloud
            case .controllers: presentedSheet = .controllers
            case .game(let id):
                guard let game = games.first(where: { $0.id == id }) else { return }
                lastSelectedGameID = id; Task { await model.launch(game) }
            case nil: break
            }
            return
        }
        guard command != .back else { return }
        if let index = actions.firstIndex(where: { $0 == focusedItem }) {
            if command == .down, let game = games.first { focusedItem = .game(game.id) }
            else { focusedItem = actions[min(actions.count - 1, max(0, index + (command == .left || command == .up ? -1 : 1)))] }
        } else if case .game(let id)? = focusedItem, let index = games.firstIndex(where: { $0.id == id }) {
            let columns = max(1, Int((UIScreen.main.bounds.width - 104) / 316))
            let delta = command == .up ? -columns : command == .down ? columns : command == .left ? -1 : 1
            if index + delta < 0 { focusedItem = .importGame }
            else { focusedItem = .game(games[min(games.count - 1, index + delta)].id) }
        } else { focusedItem = .importGame }
    }

    private var library: some View
    {
        VStack(alignment: .leading, spacing: 28)
        {
            HStack(alignment: .firstTextBaseline, spacing: 20)
            {
                Text("Delta")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                Text("Apple TV")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(model.cloud.title, systemImage: TVTheme.cloudSymbol(model.cloud))
                    .font(.callout)
                    .foregroundStyle(TVTheme.cloudColor(model.cloud))
            }

            HStack(spacing: 28)
            {
                Button { presentedSheet = .importGame } label: { Label("Import Game", systemImage: "plus") }
                    .focused($focusedItem, equals: .importGame)
                    .disabled(model.supportedSystems.isEmpty || model.isBusy)
                Button { Task { await model.restoreLibrary() } } label: { Label("Restore Library", systemImage: "icloud.and.arrow.down") }
                    .focused($focusedItem, equals: .restore)
                    .disabled(model.isBusy || model.cloud.isWorking)
                Button { presentedSheet = .cloud } label: { Label("iCloud Details", systemImage: "icloud") }
                    .focused($focusedItem, equals: .cloud)
                Button { presentedSheet = .controllers } label: { Label("Controllers", systemImage: "gamecontroller") }
                    .focused($focusedItem, equals: .controllers)
                Spacer()
            }
            .focusSection()

            if let error = model.errorMessage
            {
                TVErrorMessage(message: error) { model.errorMessage = nil }
            }

            if model.playableGames.isEmpty
            {
                emptyLibrary
            }
            else
            {
                ScrollView
                {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 36)], alignment: .leading, spacing: 38)
                    {
                        ForEach(model.playableGames) { game in
                            Button {
                                lastSelectedGameID = game.id
                                Task { await model.launch(game) }
                            } label: {
                                TVGameTile(game: game, systemName: model.systemName(for: game))
                            }
                            .buttonStyle(.card)
                            .focused($focusedItem, equals: .game(game.id))
                            .disabled(model.isBusy)
                            .accessibilityLabel("\(game.title), \(model.systemName(for: game))")
                            .accessibilityHint(game.isAvailableLocally ? "Play game" : "Download from iCloud and play")
                        }
                    }
                    .padding(18)
                }
                .focusSection()
            }

            footer
        }
        .padding(.horizontal, 70)
        .padding(.vertical, 48)
        .onPlayPauseCommand
        {
            guard case .game(let id)? = focusedItem,
                  let game = model.playableGames.first(where: { $0.id == id }) else { return }
            lastSelectedGameID = id
            Task { await model.launch(game) }
        }
        // Deliberately leave Menu/Back unhandled at library root so tvOS can
        // return Home. Game and modal screens handle their own Back action.
    }

    private var emptyLibrary: some View
    {
        VStack(spacing: 22)
        {
            Spacer(minLength: 12)
            Image(systemName: "gamecontroller")
                .font(.system(size: 72))
                .foregroundStyle(TVTheme.purple)
                .accessibilityHidden(true)
            Text(model.supportedSystems.isEmpty ? "No emulator core available" : "Your library starts here")
                .font(.title2.bold())
            Text(model.supportedSystems.isEmpty
                 ? "This build does not include a playable Apple TV core."
                 : "Import a game you own from a direct HTTPS link, or restore an existing Apple TV backup from iCloud.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)
            if !model.supportedSystems.isEmpty
            {
                Text("Available in this build: \(model.supportedSystems.map(\.name).joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("iPhone and iPad Delta Sync libraries do not appear here automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View
    {
        VStack(alignment: .leading, spacing: 10)
        {
            if let title = model.busyTitle
            {
                HStack(spacing: 18) { ProgressView(); Text(title) }
            }
            else if let notice = model.notice
            {
                Text(notice).foregroundStyle(.secondary)
            }
            Text(model.controllerDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gameScreen(_ session: TVSessionState) -> some View
    {
        ZStack
        {
            Color.black.ignoresSafeArea()
            if let controller = model.gameViewController
            {
                TVGameRenderer(controller: controller)
                    .ignoresSafeArea()
                    .accessibilityHidden(session.isPaused)
            }
            if session.isPaused
            {
                TVPauseView(model: model, session: session)
            }
            else if let title = model.busyTitle
            {
                VStack { Spacer(); HStack(spacing: 18) { ProgressView(); Text(title) } }
                    .padding(50)
            }
        }
        .onExitCommand
        {
            Task
            {
                if session.isPaused { await model.resume() }
                else { await model.pause() }
            }
        }
        .onPlayPauseCommand
        {
            Task
            {
                if session.isPaused { await model.resume() }
                else { await model.pause() }
            }
        }
    }

    private func restoreLibraryFocus()
    {
        if let id = lastSelectedGameID, model.playableGames.contains(where: { $0.id == id })
        {
            focusedItem = .game(id)
        }
        else if let game = model.playableGames.first
        {
            focusedItem = .game(game.id)
        }
        else
        {
            focusedItem = model.supportedSystems.isEmpty ? .cloud : .importGame
        }
    }
}

@MainActor
private struct TVGameRenderer: UIViewControllerRepresentable
{
    var controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

@MainActor
private struct TVGameTile: View
{
    var game: TVGameItem
    var systemName: String

    var body: some View
    {
        VStack(alignment: .leading, spacing: 14)
        {
            ZStack
            {
                TVTheme.purple.opacity(0.18)
                if let url = game.artworkURL, url.isFileURL, let artwork = UIImage(contentsOfFile: url.path)
                {
                    Image(uiImage: artwork).resizable().scaledToFit().padding(18)
                }
                else
                {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 66))
                        .foregroundStyle(TVTheme.purple)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)

            Text(game.title).font(.headline).lineLimit(2)
            Text(systemName).font(.caption).foregroundStyle(.secondary)
            Label(game.isAvailableLocally ? (game.hasCloudBackup ? "Backed up" : "On this Apple TV") : "Download to play",
                  systemImage: game.isAvailableLocally ? (game.hasCloudBackup ? "checkmark.icloud" : "internaldrive") : "icloud.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
    }
}

@MainActor
enum TVTheme
{
    // Matches Resources/Assets.xcassets/Colors/Purple.colorset from Delta.
    static let purple = Color(red: 139.0 / 255.0, green: 40.0 / 255.0, blue: 247.0 / 255.0)
    static let background = Color(white: 0.08)

    static func cloudSymbol(_ status: TVCloudPresentation) -> String
    {
        if status.isWorking { return "arrow.triangle.2.circlepath.icloud" }
        switch status.severity
        {
        case .information: return "icloud"
        case .success: return "checkmark.icloud"
        case .warning: return "exclamationmark.icloud"
        case .error: return "icloud.slash"
        }
    }

    static func cloudColor(_ status: TVCloudPresentation) -> Color
    {
        switch status.severity
        {
        case .information: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .orange
        }
    }
}

@MainActor
struct TVErrorMessage: View
{
    var message: String
    var dismiss: () -> Void

    var body: some View
    {
        HStack(spacing: 26)
        {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", action: dismiss)
        }
        .padding(22)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
