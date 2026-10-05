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

    private enum Action: Hashable { case resume, save, load, exit }

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

                Button("Resume") { Task { await model.resume() } }
                    .focused($focusedAction, equals: .resume)
                    .disabled(model.isBusy)
                Button("Save State") { Task { await model.saveState() } }
                    .focused($focusedAction, equals: .save)
                    .disabled(model.isBusy || !session.canSaveState)
                Button("Load State") { confirmsLoad = true }
                    .focused($focusedAction, equals: .load)
                    .disabled(model.isBusy || !session.canLoadState)
                Button("Return to Library") { Task { await model.exitGame() } }
                    .focused($focusedAction, equals: .exit)
                    .disabled(model.isBusy)

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
        .onChange(of: model.isBusy) { _, isBusy in
            if !isBusy, focusedAction == nil { focusedAction = .resume }
        }
        .alert("Load saved state?", isPresented: $confirmsLoad)
        {
            Button("Cancel", role: .cancel) { focusedAction = .load }
            Button("Load State") { Task { await model.loadState() } }
        } message: {
            Text("This replaces your current game session with its saved state. Progress since that state will be lost.")
        }
    }
}
