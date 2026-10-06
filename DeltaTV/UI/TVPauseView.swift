//
//  TVPauseView.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import SwiftUI

@MainActor
struct TVPauseView: View
{
    @ObservedObject var model: DeltaTVViewModel
    var session: TVSessionState
    @FocusState private var focusedAction: Action?
    @State private var confirmsLoad = false

    private enum Action: Hashable { case resume, touch, save, load, exit, confirmLoad, cancelLoad }

    var body: some View
    {
        ZStack
        {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 24)
            {
                Text("Paused").font(.callout).foregroundStyle(.secondary)
                Text(session.title).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)

                if let error = model.errorMessage
                {
                    TVErrorMessage(message: error) { model.errorMessage = nil }
                }

                if confirmsLoad {
                    Text("Load saved state?").font(.headline)
                    Text("Progress since that state will be lost.").foregroundStyle(.secondary)
                    Button("Cancel") { cancelLoad() }.focused($focusedAction, equals: .cancelLoad)
                    Button("Load State") { loadState() }.focused($focusedAction, equals: .confirmLoad)
                } else {
                Button("Resume") { Task { await model.resume() } }
                    .focused($focusedAction, equals: .resume)
                    .disabled(model.isBusy)
                if session.hasDSTouch {
                    Button(session.touchCursorMode ? "Use Right Stick Stylus" : "Use D-Pad Stylus") { model.actions.toggleTouchCursor() }
                        .focused($focusedAction, equals: .touch)
                    Text(session.touchCursorMode ? "D-Pad moves the stylus. A touches; B returns to game controls." : "Right stick moves the stylus. R2 touches the lower screen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Save State") { Task { await model.saveState() } }
                    .focused($focusedAction, equals: .save)
                    .disabled(model.isBusy || !session.canSaveState)
                Button("Load State") { confirmLoad() }
                    .focused($focusedAction, equals: .load)
                    .disabled(model.isBusy || !session.canLoadState)
                Button("Return to Library") { Task { await model.exitGame() } }
                    .focused($focusedAction, equals: .exit)
                    .disabled(model.isBusy)
                }

                if let title = model.busyTitle
                {
                    HStack(spacing: 18) { ProgressView(); Text(title) }.font(.callout)
                }
                else if let notice = model.notice
                {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }

                Label(model.cloud.title, systemImage: TVTheme.cloudSymbol(model.cloud))
                    .font(.callout)
                    .foregroundStyle(TVTheme.cloudColor(model.cloud))
                Text("Save State replaces this game’s previous Apple TV state. In-game saves and save states are separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 850)
            .padding(50)
        }
        .onAppear { focusedAction = .resume }
        .onReceive(NotificationCenter.default.publisher(for: .tvControllerNavigation)) { notification in
            guard let raw = notification.object as? String, let command = TVNavigationCommand(rawValue: raw),
                  !model.isBusy else { return }
            if confirmsLoad {
                if command == .back { cancelLoad() }
                else if command == .select { focusedAction == .confirmLoad ? loadState() : cancelLoad() }
                else { focusedAction = focusedAction == .cancelLoad ? .confirmLoad : .cancelLoad }
                return
            }
            let actions: [Action] = [.resume] + (session.hasDSTouch ? [.touch] : []) + (session.canSaveState ? [.save] : []) + (session.canLoadState ? [.load] : []) + [.exit]
            if command == .select {
                switch focusedAction {
                case .resume: Task { await model.resume() }
                case .touch: model.actions.toggleTouchCursor()
                case .save: Task { await model.saveState() }
                case .load: confirmLoad()
                case .exit: Task { await model.exitGame() }
                case .confirmLoad, .cancelLoad, nil: break
                }
            } else if command == .back { Task { await model.resume() } }
            else {
                let index = actions.firstIndex(where: { $0 == focusedAction }) ?? 0
                focusedAction = actions[min(actions.count - 1, max(0, index + (command == .up || command == .left ? -1 : 1)))]
            }
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if !isBusy, focusedAction == nil { focusedAction = .resume }
        }
    }

    private func confirmLoad() { confirmsLoad = true; focusedAction = .cancelLoad }
    private func cancelLoad() { confirmsLoad = false; focusedAction = .load }
    private func loadState() { confirmsLoad = false; focusedAction = .load; Task { await model.loadState() } }
}
