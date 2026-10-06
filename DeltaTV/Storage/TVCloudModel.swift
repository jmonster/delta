// Copyright © 2026 Delta contributors. All rights reserved.

import Foundation

/// Stable journal IDs shared by import, recovery and the runtime core catalog.
enum TVSystem: String, CaseIterable, Sendable
{
    case gb, gbc, nes, snes, gba, n64, ds, genesis
    var name: String {
        switch self {
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .nes: "Nintendo Entertainment System"
        case .snes: "Super Nintendo"
        case .gba: "Game Boy Advance"
        case .n64: "Nintendo 64"
        case .ds: "Nintendo DS"
        case .genesis: "Genesis / Mega Drive"
        }
    }
    var fileExtensions: [String] {
        switch self {
        case .gb: ["gb"]
        case .gbc: ["gbc"]
        case .nes: ["nes"]
        case .snes: ["sfc", "smc"]
        case .gba: ["gba"]
        case .n64: ["z64", "v64", "n64"]
        case .ds: ["nds"]
        case .genesis: ["gen", "md", "bin"]
        }
    }
    var maximumROMBytes: Int {
        switch self {
        case .ds: 512 * 1024 * 1024
        case .n64: 64 * 1024 * 1024
        case .gba: 32 * 1024 * 1024
        default: 16 * 1024 * 1024
        }
    }
    static var supportedExtensions: Set<String> { Set(allCases.flatMap(\.fileExtensions)) }
    static func system(forExtension ext: String) -> Self? {
        allCases.first { $0.fileExtensions.contains(ext.lowercased()) }
    }
}

/// All paths are relative to the current, purgeable tvOS cache. Never persist sandbox URLs.
struct TVGame: Codable, Identifiable, Equatable, Sendable
{
    let id: String
    let title: String
    let system: String
    let relativeROMPath: String
}

enum TVCloudAssetKind: String, Codable, Sendable
{
    case rom, batterySave, saveState
}

struct TVCloudRecord: Codable, Equatable, Sendable
{
    let id: String
    let game: TVGame
    let kind: TVCloudAssetKind
    let slot: String
    let revision: String
    let modifiedAt: Date
    var coreIdentifier: String?
    var coreVersion: String?
    var hasRTC: Bool?
    var hasBatteryRAM: Bool?
}

struct TVCloudStatus: Equatable, Sendable
{
    enum Phase: String, Sendable { case unavailable, idle, syncing, pending, synced, conflict, error }
    var phase: Phase
    var message: String
    var pendingCount: Int
    var conflictCount: Int
}

struct TVSyncConflict: Identifiable, Sendable
{
    let id: String
    let game: TVGame
    let kind: TVCloudAssetKind
    let slot: String
}

enum TVCloudError: LocalizedError
{
    case unavailable(String)
    case conflict
    case accountChanged
    case invalidRecord
    case missingAsset
    case capacityExceeded
    case retryLater(Date)

    var errorDescription: String? {
        switch self
        {
        case .unavailable(let message): return message
        case .conflict: return "Another device has different progress. Both versions have been kept."
        case .accountChanged: return "The iCloud account changed. This library is still tied to its original account; sign back in before syncing."
        case .invalidRecord: return "A library record is invalid or unsupported. Nothing was overwritten."
        case .missingAsset: return "A local file is missing. Unsynced files cannot be recovered from iCloud."
        case .capacityExceeded: return "The library or pending upload limit was reached. Sync before adding more data."
        case .retryLater(let date): return "iCloud asked Delta to retry after \(date.formatted())."
        }
    }
}

/// Adapters must report success only after the server acknowledges the entire asset record.
/// A failed/ambiguous write may have reached the server: retries use the same revision ID.
@MainActor
protocol TVCloudTransport: AnyObject
{
    func accountIdentifier() async throws -> String
    func records() async throws -> [TVCloudRecord]
    func download(_ record: TVCloudRecord, to destination: URL) async throws
    func upload(_ record: TVCloudRecord, fileURL: URL, replacing revision: String?) async throws
}

/// No queue grows without a limit. Repeated saves coalesce by game/kind/slot.
struct TVStorageLimits: Sendable
{
    var maximumRecords = 512
    var maximumPendingBytes: Int64 = 1_073_741_824
    var maximumROMBytes: Int64 = 536_870_912
    var maximumSaveBytes: Int64 = 67_108_864
    var maximumSaveSlots = 8
}

/// One server record acknowledges battery RAM and its optional RTC companion together.
struct TVBatterySnapshot: Codable, Sendable
{
    let formatVersion: Int
    let save: Data
    let rtc: Data?
}
