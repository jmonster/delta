// Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
import DeltaCore
import GBCDeltaCore
import NESDeltaCore
import SNESDeltaCore
import GBADeltaCore
import N64DeltaCore
import MelonDSDeltaCore
import GPGXDeltaCore

@MainActor
extension TVSystem
{
    var core: DeltaCoreProtocol {
        switch self {
        case .gb, .gbc: GBC.core
        case .nes: NES.core
        case .snes: SNES.core
        case .gba: GBA.core
        case .n64: N64.core
        case .ds: MelonDS.core
        case .genesis: GPGX.core
        }
    }
    // Include the tvOS bridge format in state compatibility, independently of battery assets.
    var coreRevision: String {
        switch self {
        case .gb, .gbc: "0871ccaad2bbd7cbd2de0ce06f9e26dc3d1bfdde"
        case .nes: "c88ef1e7c68ad723194d1b691362ac7d7394f968.tv1"
        case .snes: "35add3af36e6c42d777c554a277e098766a78995.tv1"
        case .gba: "869c34aeca9dd2b3fbd329092bb2743b0ae80c98.tv1"
        case .n64: "56aefef59d947edbf2eb34b0a0288d751b006f30.tv1"
        case .ds: "eb9b07ec17307cfd4986cb607f8ee5f6492d73cb.tv1"
        case .genesis: "4af2ff5d68cffd12121b63157ffb79267573bfcc.tv1"
        }
    }
    var maximumPlayers: Int {
        switch self { case .n64: 4; case .nes, .snes, .genesis: 2; default: 1 }
    }
    var aspectRatio: Double {
        switch self {
        case .gb, .gbc: 160 / 144
        case .nes: 256 / 240
        case .snes: 256 / 224
        case .gba: 240 / 160
        case .ds: 256 / 384 // Both screens, with touch on the lower half.
        case .n64, .genesis: 4 / 3
        }
    }
    nonisolated var loadedSuccessfully: Bool {
        switch self {
        case .gb, .gbc: GBCEmulatorBridge.shared.lastLoadResult == 0
        case .nes: NESEmulatorBridge.shared.lastLoadResult
        case .snes: SNESEmulatorBridge.shared.lastLoadResult
        case .gba: GBAEmulatorBridge.shared.lastLoadResult
        case .n64: N64EmulatorBridge.shared.lastLoadResult
        case .ds: MelonDSEmulatorBridge.shared.lastLoadResult
        case .genesis: GPGXEmulatorBridge.shared.lastLoadResult
        }
    }
    nonisolated var batterySavedSuccessfully: Bool {
        switch self {
        case .gb, .gbc: GBCEmulatorBridge.shared.lastBatterySaveResult
        case .nes: NESEmulatorBridge.shared.lastBatterySaveResult
        case .snes: SNESEmulatorBridge.shared.lastBatterySaveResult
        case .gba: GBAEmulatorBridge.shared.lastBatterySaveResult
        case .n64: N64EmulatorBridge.shared.lastBatterySaveResult
        case .ds: MelonDSEmulatorBridge.shared.lastBatterySaveResult
        case .genesis: GPGXEmulatorBridge.shared.lastBatterySaveResult
        }
    }
    var stateSavedSuccessfully: Bool {
        switch self {
        case .gb, .gbc: GBCEmulatorBridge.shared.lastSaveStateResult
        case .nes: NESEmulatorBridge.shared.lastSaveStateResult
        case .snes: SNESEmulatorBridge.shared.lastSaveStateResult
        case .gba: GBAEmulatorBridge.shared.lastSaveStateResult
        case .n64: N64EmulatorBridge.shared.lastSaveStateResult
        case .ds: MelonDSEmulatorBridge.shared.lastSaveStateResult
        case .genesis: GPGXEmulatorBridge.shared.lastSaveStateResult
        }
    }
    var stateLoadedSuccessfully: Bool {
        switch self {
        case .gb, .gbc: GBCEmulatorBridge.shared.lastLoadStateResult
        case .nes: NESEmulatorBridge.shared.lastLoadStateResult
        case .snes: SNESEmulatorBridge.shared.lastLoadStateResult
        case .gba: GBAEmulatorBridge.shared.lastLoadStateResult
        case .n64: N64EmulatorBridge.shared.lastLoadStateResult
        case .ds: MelonDSEmulatorBridge.shared.lastLoadStateResult
        case .genesis: GPGXEmulatorBridge.shared.lastLoadStateResult
        }
    }
}
