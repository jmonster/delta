// Copyright © 2026 Delta contributors. All rights reserved.

import Foundation

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
    var maximumPendingBytes: Int64 = 67_108_864
    var maximumROMBytes: Int64 = 16_777_216
    var maximumSaveBytes: Int64 = 4_194_304
    var maximumSaveSlots = 8
}

/// One server record acknowledges battery RAM and its optional RTC companion together.
struct TVBatterySnapshot: Codable, Sendable
{
    let formatVersion: Int
    let save: Data
    let rtc: Data?
}
