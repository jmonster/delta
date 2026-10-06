//
//  TVLibrarySheets.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import SwiftUI

@MainActor
struct TVImportView: View
{
    @ObservedObject var model: DeltaTVViewModel
    var close: () -> Void
    @State private var address = ""
    @State private var closesAfterCancellation = false
    @State private var importTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case address, importGame, back }

    var body: some View
    {
        VStack(alignment: .leading, spacing: 30)
        {
            Text("Import Game").font(.largeTitle.bold())
            Text("Enter a direct HTTPS download link to a game you own. Use the Siri Remote keyboard, or the Apple TV keyboard notification on your iPhone or iPad.")
                .foregroundStyle(.secondary)
            TextField("https://example.com/game.gbc", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .address)
                .disabled(model.isBusy)
                .accessibilityLabel("ROM download address")
                .onSubmit { focusedField = .importGame }

            Text("Supported: \(model.supportedFileExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")) · Limits vary by system, up to 512 MB · No ZIP files")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let error = model.errorMessage
            {
                TVErrorMessage(message: error) { model.errorMessage = nil; focusedField = .address }
            }

            HStack(spacing: 30)
            {
                Button("Import")
                {
                    importTask = Task
                    {
                        if await model.importGame(from: address) { close() }
                        else if !closesAfterCancellation { focusedField = .address }
                    }
                }
                .focused($focusedField, equals: .importGame)
                .disabled(model.isBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(model.isBusy ? "Cancel Import" : "Back", action: goBack)
                    .focused($focusedField, equals: .back)
            }

            if let title = model.busyTitle
            {
                HStack(spacing: 18) { ProgressView(); Text(title) }
            }

            Text("Imported games are cached on this Apple TV. Check iCloud Details to confirm a backup has finished before relying on recovery.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 1200, alignment: .leading)
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVTheme.background)
        .tint(TVTheme.purple)
        .onAppear { focusedField = .address }
        .onDisappear { importTask?.cancel() }
        .onExitCommand(perform: goBack)
        .onReceive(NotificationCenter.default.publisher(for: .tvControllerNavigation)) { notification in
            guard let raw = notification.object as? String, let command = TVNavigationCommand(rawValue: raw) else { return }
            if command == .back { goBack() }
            else if command == .select {
                if focusedField == .back { goBack() }
                else if focusedField == .importGame, !model.isBusy, !address.isEmpty {
                    importTask = Task { if await model.importGame(from: address) { close() } }
                }
            } else {
                let actions: [Field] = model.isBusy ? [.back] : [.address, .importGame, .back]
                let index = actions.firstIndex(where: { $0 == focusedField }) ?? 0
                focusedField = actions[min(actions.count - 1, max(0, index + (command == .up || command == .left ? -1 : 1)))]
            }
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy { focusedField = .back }
            else if closesAfterCancellation { close() }
        }
    }

    private func goBack()
    {
        if model.isBusy
        {
            closesAfterCancellation = true
            importTask?.cancel()
            model.cancelOperation()
        }
        else
        {
            close()
        }
    }
}

@MainActor
struct TVCloudView: View
{
    @ObservedObject var model: DeltaTVViewModel
    var close: () -> Void
    @FocusState private var focusedAction: String?
    @State private var selectedConflict: TVConflictItem?

    var body: some View
    {
        ScrollView
        {
            VStack(alignment: .leading, spacing: 28)
            {
                Text("iCloud Backup & Recovery").font(.largeTitle.bold())
                Label(model.cloud.title, systemImage: TVTheme.cloudSymbol(model.cloud))
                    .font(.title3)
                    .foregroundStyle(TVTheme.cloudColor(model.cloud))
                Text(model.cloud.detail).fixedSize(horizontal: false, vertical: true)

                if let error = model.errorMessage
                {
                    TVErrorMessage(message: error) { model.errorMessage = nil }
                }

                HStack(spacing: 30)
                {
                    Button("Retry Sync") { Task { await model.refresh() } }
                        .focused($focusedAction, equals: "retry")
                        .disabled(model.isBusy || model.cloud.isWorking || !model.cloud.allowsRetry)
                    Button("Restore Library") { Task { await model.restoreLibrary() } }
                        .focused($focusedAction, equals: "restore")
                        .disabled(model.isBusy || model.cloud.isWorking)
                    Button("Back", action: close).focused($focusedAction, equals: "back")
                }

                if let title = model.busyTitle
                {
                    HStack(spacing: 18) { ProgressView(); Text(title) }
                }

                if let conflict = selectedConflict {
                    Text("Choose which progress to keep").font(.headline)
                    Text("\(conflict.gameTitle): \(conflict.kindDescription). Keeping this Apple TV replaces the iCloud version. Using iCloud keeps the replaced local file only in this Apple TV’s purgeable cache.")
                    HStack {
                        Button("Keep This Apple TV") { resolve(conflict, keepLocal: true) }.focused($focusedAction, equals: "local")
                        Button("Use iCloud") { resolve(conflict, keepLocal: false) }.focused($focusedAction, equals: "cloud")
                        Button("Cancel") { cancelConflict() }.focused($focusedAction, equals: "cancel")
                    }.disabled(model.isBusy)
                } else if !model.conflicts.isEmpty
                {
                    Text("Conflicting Progress").font(.headline)
                    ForEach(model.conflicts) { conflict in
                        HStack(spacing: 26)
                        {
                            VStack(alignment: .leading, spacing: 8)
                            {
                                Text(conflict.gameTitle).font(.headline)
                                Text(conflict.kindDescription).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resolve") { selectedConflict = conflict; focusedAction = "cancel" }
                                .focused($focusedAction, equals: "resolve:" + conflict.id)
                                .disabled(model.isBusy || model.session != nil)
                                .accessibilityLabel("Resolve \(conflict.gameTitle), \(conflict.kindDescription)")
                        }
                        .padding(24)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    }
                }

                VStack(alignment: .leading, spacing: 18)
                {
                    Text("Apple TV can remove cached files when it needs space. Only files whose iCloud upload has completed can be recovered.")
                    Text("Restore checks this app’s iCloud backup and keeps pending local changes. A missing local file does not delete its cloud backup.")
                    Text("This Apple TV backup is separate from Delta Sync on iPhone and iPad. Existing Google Drive or Dropbox libraries are not imported automatically.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Text("Delta was created by Riley Testut and contributors. This Apple TV port is part of the jmonster/Delta fork. Delta is licensed under AGPL-3.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVTheme.background)
        .tint(TVTheme.purple)
        .onAppear { focusedAction = "back" }
        .onExitCommand(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: .tvControllerNavigation)) { notification in
            guard let raw = notification.object as? String, let command = TVNavigationCommand(rawValue: raw) else { return }
            if command == .back { selectedConflict == nil ? close() : cancelConflict(); return }
            guard !model.isBusy else { return }
            let actions: [String]
            if selectedConflict != nil { actions = ["local", "cloud", "cancel"] }
            else {
                actions = (!model.cloud.isWorking && model.cloud.allowsRetry ? ["retry"] : [])
                    + (!model.cloud.isWorking ? ["restore"] : []) + ["back"]
                    + (model.session == nil ? model.conflicts.map { "resolve:" + $0.id } : [])
            }
            if command == .select {
                if let conflict = selectedConflict {
                    if focusedAction == "local" { resolve(conflict, keepLocal: true) }
                    else if focusedAction == "cloud" { resolve(conflict, keepLocal: false) }
                    else { cancelConflict() }
                } else if focusedAction == "retry", actions.contains("retry") { Task { await model.refresh() } }
                else if focusedAction == "restore", actions.contains("restore") { Task { await model.restoreLibrary() } }
                else if focusedAction == "back" { close() }
                else if let conflict = model.conflicts.first(where: { "resolve:" + $0.id == focusedAction }), model.session == nil {
                    selectedConflict = conflict; focusedAction = "cancel"
                }
            } else {
                let index = actions.firstIndex(where: { $0 == focusedAction }) ?? 0
                focusedAction = actions[min(actions.count - 1, max(0, index + (command == .up || command == .left ? -1 : 1)))]
            }
        }
    }

    private func cancelConflict() { selectedConflict = nil; focusedAction = "back" }
    private func resolve(_ conflict: TVConflictItem, keepLocal: Bool) {
        selectedConflict = nil; focusedAction = "back"
        Task { await model.resolveConflict(conflict, keepLocal: keepLocal) }
    }
}
