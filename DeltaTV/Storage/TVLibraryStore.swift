// Copyright © 2026 Delta contributors. All rights reserved.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Foreground-only cloud recovery. Neither the live files nor its journal are durable on tvOS.
/// The app must stage progress while the core is paused, then call synchronize().
@MainActor
final class TVLibraryStore
{
    private struct Entry: Codable
    {
        var record: TVCloudRecord
        var acknowledgedRevision: String?
        var pending: Bool
        var conflict: TVCloudRecord?
    }

    private struct BatteryPublication: Codable
    {
        let record: TVCloudRecord
        let expectedRevision: String?
        // Absent on old cloud-restore markers; false preserves a local pending checkpoint.
        var acknowledgesCloudRevision: Bool?
    }

    private struct Journal: Codable
    {
        var version = 1
        var accountIdentifier: String?
        var entries: [String: Entry] = [:]
        var missingCloudRecords: Set<String>?
    }

    let rootURL: URL
    private let cloud: TVCloudTransport?
    private let limits: TVStorageLimits
    private var journal: Journal
    private var isSynchronizing = false
    private var uploadingRevisions: Set<String> = []
    private var missingCloudRecords: Set<String> {
        get { journal.missingCloudRecords ?? [] }
        set { journal.missingCloudRecords = newValue }
    }
    /// Prevent remote writes into a core's open files or changing its progress baseline.
    var activeGameID: String?
    var onChange: (() -> Void)?
    private(set) var status = TVCloudStatus(phase: .idle, message: "Checking library", pendingCount: 0, conflictCount: 0)

    nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DeltaTV", isDirectory: true)
    }

    init(rootURL: URL = TVLibraryStore.defaultRootURL, cloud: TVCloudTransport? = nil, limits: TVStorageLimits = TVStorageLimits()) throws
    {
        self.rootURL = rootURL
        self.cloud = cloud
        self.limits = limits
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let journalURL = rootURL.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: journalURL.path)
        {
            self.journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard self.journal.version == 1, self.journal.entries.count <= limits.maximumRecords else { throw TVCloudError.invalidRecord }
            for (id, entry) in self.journal.entries
            {
                try Self.validate(entry.record)
                if let conflict = entry.conflict
                {
                    try Self.validate(conflict)
                    guard conflict.id == id, conflict.game == entry.record.game, conflict.kind == entry.record.kind, conflict.slot == entry.record.slot else { throw TVCloudError.invalidRecord }
                }
                guard id == entry.record.id else { throw TVCloudError.invalidRecord }
            }
        }
        else
        {
            self.journal = Journal()
        }
        // Finish an interrupted two-file battery publication before exposing any game.
        let restores = rootURL.appendingPathComponent("RestoringBattery", isDirectory: true)
        if let markers = try? FileManager.default.contentsOfDirectory(at: restores, includingPropertiesForKeys: nil)
        {
            for marker in markers
            {
                let publication = try JSONDecoder().decode(BatteryPublication.self, from: Data(contentsOf: marker))
                try Self.validate(publication.record)
                guard publication.record.kind == .batterySave else { throw TVCloudError.invalidRecord }
                let current = journal.entries[publication.record.id]
                let targetIsCurrent = current?.record.revision == publication.expectedRevision || current?.record.revision == publication.record.revision
                let record = targetIsCurrent ? publication.record : (current?.record ?? publication.record)
                if FileManager.default.fileExists(atPath: snapshotURL(record).path)
                {
                    try installBattery(record, from: snapshotURL(record))
                    if targetIsCurrent && publication.acknowledgesCloudRevision != false
                    {
                        journal.entries[record.id] = Entry(record: record, acknowledgedRevision: record.revision, pending: false)
                    }
                    try persist()
                    try FileManager.default.removeItem(at: marker)
                }
                else if targetIsCurrent && publication.acknowledgesCloudRevision != false
                {
                    // A partial purge can remove the downloaded snapshot too. Retain the
                    // marker and cloud metadata; no launch until restore repairs the pair.
                    journal.entries[record.id] = Entry(record: record, acknowledgedRevision: record.revision, pending: false)
                    try persist()
                }
            }
        }
        // Crashes can leave unreferenced snapshots. Never remove a journal-referenced file.
        let stagedDirectory = rootURL.appendingPathComponent("Staged", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: stagedDirectory, includingPropertiesForKeys: nil)
        {
            let retained = Set(self.journal.entries.values.map { self.snapshotURL($0.record).lastPathComponent })
            for file in files where !retained.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
        self.updateStatus()
    }

    var games: [TVGame] {
        journal.entries.values.filter { $0.record.kind == .rom }.map { $0.record.game }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var conflicts: [TVSyncConflict] {
        journal.entries.values.filter { $0.conflict != nil }.map {
            TVSyncConflict(id: $0.record.id, game: $0.record.game, kind: $0.record.kind, slot: $0.record.slot)
        }
    }

    func romURL(for game: TVGame) -> URL { rootURL.appendingPathComponent(game.relativeROMPath) }
    func batterySaveURL(for game: TVGame) -> URL { gameDirectory(game).appendingPathComponent("battery.sav") }
    func batteryRTCURL(for game: TVGame) -> URL { gameDirectory(game).appendingPathComponent("battery.rtc") }
    func saveStateURL(for game: TVGame, slot: String = "resume") -> URL {
        // External callers cannot construct a traversal path, even before staging validates it.
        gameDirectory(game).appendingPathComponent("state-\(Self.safeSlot(slot) ? slot : "invalid").state")
    }
    func isAvailableLocally(_ game: TVGame) -> Bool {
        guard FileManager.default.fileExists(atPath: romURL(for: game).path),
              !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("RestoringBattery/\(game.id).batterySave.battery.json").path) else { return false }
        if let battery = journal.entries["\(game.id).batterySave.battery"] { return isLiveAssetAvailable(battery.record) }
        return true
    }
    /// Before opening a core, rebuild its live RAM/RTC pair from the last journaled
    /// checkpoint. File existence cannot detect a crash between the core's two writes.
    func prepareForLaunch(_ game: TVGame) async throws
    {
        guard activeGameID == nil else { throw TVCloudError.unavailable("Stop the active game before preparing another checkpoint.") }
        guard let entry = journal.entries["\(game.id).batterySave.battery"] else { return }
        let record = entry.record
        let prepared: TVPreparedBattery
        do
        {
            prepared = try await TVFileWorker.shared.prepareBattery(from: snapshotURL(record), record: record,
                maximumBytes: limits.maximumSaveBytes, beside: batterySaveURL(for: game))
        }
        catch is CancellationError { throw CancellationError() }
        catch
        {
            // A concurrent stage or game launch owns the new state. Do not mark or touch it.
            guard activeGameID == nil, journal.entries[record.id]?.record.revision == record.revision else { throw error }
            try writePublicationMarker(record, acknowledgesCloudRevision: false)
            let detail = entry.pending
                ? "The latest unsynced battery checkpoint is unavailable. Its live files cannot safely be used; keep this game stopped."
                : "The saved battery checkpoint is unavailable locally. Restore it from iCloud before playing."
            status = TVCloudStatus(phase: .error, message: detail, pendingCount: pendingCount, conflictCount: conflicts.count)
            onChange?()
            throw TVCloudError.unavailable(detail)
        }
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try Task.checkCancellation()
        guard activeGameID == nil, journal.entries[record.id]?.record.revision == record.revision else
        {
            throw TVCloudError.unavailable("Progress changed while preparing this game. Try launching again.")
        }
        do
        {
            try writePublicationMarker(record, acknowledgesCloudRevision: false)
            if let save = prepared.save { try Self.installPrepared(save, at: batterySaveURL(for: game)) }
            else { try removeIfPresent(batterySaveURL(for: game)) }
            if let rtc = prepared.rtc { try Self.installPrepared(rtc, at: batteryRTCURL(for: game)) }
            else { try removeIfPresent(batteryRTCURL(for: game)) }
            // The journal and acknowledgment remain exactly as they were, including a
            // newer pending revision. The marker makes a crash between renames repairable.
            finishPublication(record)
            updateStatus()
        }
        catch
        {
            status = TVCloudStatus(phase: .error, message: "The battery checkpoint could not be prepared. This game must stay stopped until recovery succeeds.", pendingCount: pendingCount, conflictCount: conflicts.count)
            onChange?()
            throw error
        }
    }

    func hasSaveState(_ game: TVGame, slot: String = "resume") -> Bool {
        FileManager.default.fileExists(atPath: saveStateURL(for: game, slot: slot).path)
    }
    func saveStateIsCompatible(_ game: TVGame, coreIdentifier: String, coreVersion: String, slot: String = "resume") -> Bool
    {
        guard hasSaveState(game, slot: slot), let entry = journal.entries["\(game.id).saveState.\(slot)"] else { return false }
        return entry.record.coreIdentifier == coreIdentifier && entry.record.coreVersion == coreVersion
    }
    func hasCloudBackup(_ game: TVGame) -> Bool {
        let entries = journal.entries.values.filter { $0.record.game.id == game.id }
        return !entries.isEmpty && entries.allSatisfy { !$0.pending && $0.conflict == nil && !missingCloudRecords.contains($0.record.id) && $0.acknowledgedRevision == $0.record.revision }
    }

    @discardableResult
    func importGame(at source: URL, title: String, system: String) async throws -> TVGame
    {
        let fileExtension = source.pathExtension.lowercased()
        guard TVSystem(rawValue: system)?.fileExtensions.contains(fileExtension) == true,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 256,
              TVSystem(rawValue: system) != nil else { throw TVCloudError.invalidRecord }
        let id = UUID().uuidString
        let game = TVGame(id: id, title: title, system: system, relativeROMPath: "Games/\(id)/game.\(fileExtension)")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: gameDirectory(game)) } }
        guard try Self.fileSize(source) <= min(limits.maximumROMBytes, Int64(TVSystem(rawValue: system)!.maximumROMBytes)) else { throw TVCloudError.capacityExceeded }
        try await TVFileWorker.shared.copy(source, to: romURL(for: game))
        let prepared = try await TVFileWorker.shared.prepareCopy(source, beside: rootURL.appendingPathComponent("Staged/rom"))
        defer { try? FileManager.default.removeItem(at: prepared) }
        do
        {
            try Task.checkCancellation()
            try self.stage(game: game, kind: .rom, slot: "rom", source: romURL(for: game), preparedSnapshot: prepared)
        }
        catch
        {
            try? FileManager.default.removeItem(at: gameDirectory(game))
            throw error
        }
        committed = true
        self.updateStatus()
        return game
    }

    func stageBatterySave(for game: TVGame) throws
    {
        try stageBatterySave(for: game, from: batterySaveURL(for: game))
    }

    /// The core callback may pass a stable snapshot copied before emulation resumes.
    func stageBatterySave(for game: TVGame, from snapshotURL: URL) throws
    {
        let rtcURL = snapshotURL.deletingPathExtension().appendingPathExtension("rtc")
        let hasSaveFile = FileManager.default.fileExists(atPath: snapshotURL.path)
        let size = hasSaveFile ? try Self.fileSize(snapshotURL) : 0
        let hasRTC = FileManager.default.fileExists(atPath: rtcURL.path)
        let rtcSize = hasRTC ? try Self.fileSize(rtcURL) : 0
        guard size + rtcSize > 0, size + rtcSize <= limits.maximumSaveBytes else { throw TVCloudError.capacityExceeded }
        let snapshot = TVBatterySnapshot(formatVersion: 1, save: hasSaveFile ? try Data(contentsOf: snapshotURL) : Data(), rtc: hasRTC ? try Data(contentsOf: rtcURL) : nil)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let temporary = rootURL.appendingPathComponent(UUID().uuidString + ".battery")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encoder.encode(snapshot).write(to: temporary, options: .atomic)
        try stage(game: game, kind: .batterySave, slot: "battery", source: temporary, preparedSnapshot: temporary, hasRTC: hasRTC, hasBatteryRAM: size > 0)
    }

    func stageSaveState(for game: TVGame, slot: String = "resume", coreIdentifier: String? = nil, coreVersion: String? = nil) throws
    {
        try stage(game: game, kind: .saveState, slot: slot, source: saveStateURL(for: game, slot: slot),
                  coreIdentifier: coreIdentifier, coreVersion: coreVersion)
    }

    /// Restore is a safe merge, not a reset. Local pending progress always wins locally until resolved.
    func restore() async { await synchronize() }

    func synchronize() async
    {
        guard !isSynchronizing else { return }
        if Task.isCancelled { return }
        guard let cloud = cloud else { updateStatus(); return }
        isSynchronizing = true
        status = TVCloudStatus(phase: .syncing, message: "Checking iCloud and syncing files", pendingCount: pendingCount, conflictCount: conflicts.count)
        onChange?()
        defer { isSynchronizing = false }
        do
        {
            try Task.checkCancellation()
            let account = try await cloud.accountIdentifier()
            if let previousAccount = journal.accountIdentifier, previousAccount != account { throw TVCloudError.accountChanged }
            if journal.accountIdentifier == nil
            {
                journal.accountIdentifier = account
                try persist()
            }
            let remoteRecords = try await cloud.records()
            guard try await cloud.accountIdentifier() == account else { throw TVCloudError.accountChanged }
            guard remoteRecords.count <= limits.maximumRecords else { throw TVCloudError.capacityExceeded }
            var seen = Set<String>()
            for remote in remoteRecords
            {
                try Task.checkCancellation()
                try Self.validate(remote)
                guard seen.insert(remote.id).inserted else { throw TVCloudError.invalidRecord }
                try await merge(remote, cloud: cloud)
            }
            // A cloud reset/deletion is not permission to silently resurrect old progress.
            missingCloudRecords = Set(journal.entries.values.filter { !$0.pending && $0.acknowledgedRevision != nil && !seen.contains($0.record.id) }.map { $0.record.id })
            try persist()
            if !missingCloudRecords.isEmpty
            {
                throw TVCloudError.unavailable("Previously confirmed files are missing from iCloud. Re-import or recover the library before continuing.")
            }
            // A purged journal is recovered above. A missing file in an existing journal is
            // also rehydrated, rather than trusting the mere presence of its metadata.
            let pendingIDs = journal.entries.keys.filter { journal.entries[$0]?.pending == true }.sorted()
            for id in pendingIDs
            {
                try Task.checkCancellation()
                guard let entry = journal.entries[id], entry.conflict == nil else { continue }
                let record = entry.record
                let stagedURL = snapshotURL(record)
                guard FileManager.default.fileExists(atPath: stagedURL.path) else { throw TVCloudError.missingAsset }
                uploadingRevisions.insert(record.revision)
                do
                {
                    try await cloud.upload(record, fileURL: stagedURL, replacing: entry.acknowledgedRevision)
                    guard try await cloud.accountIdentifier() == account else { throw TVCloudError.accountChanged }
                    // A newer save may have been staged while the upload was suspended.
                    // Only acknowledge this revision; leave the newer save pending against it.
                    if var latest = journal.entries[id]
                    {
                        latest.acknowledgedRevision = record.revision
                        if latest.record.revision == record.revision { latest.pending = false }
                        journal.entries[id] = latest
                        try persist()
                    }
                    uploadingRevisions.remove(record.revision)
                    cleanupSnapshot(record)
                }
                catch
                {
                    uploadingRevisions.remove(record.revision)
                    if case TVCloudError.conflict = error
                    {
                        // Refetch next time before choosing a winner. Never use last-writer-wins.
                        if let remote = try await cloud.records().first(where: { $0.id == id })
                        {
                            try Self.validate(remote)
                            guard remote.id == record.id, remote.game == record.game, remote.kind == record.kind, remote.slot == record.slot else { throw TVCloudError.invalidRecord }
                            journal.entries[id]?.conflict = remote
                            try persist()
                        }
                        else { throw error }
                    }
                    else { throw error }
                }
            }
            updateStatus()
        }
        catch is CancellationError
        {
            updateStatus()
        }
        catch
        {
            status = TVCloudStatus(phase: .error, message: error.localizedDescription + " Unsynced progress exists only in this Apple TV's purgeable cache.", pendingCount: pendingCount, conflictCount: conflicts.count)
            onChange?()
        }
    }

    /// Explicit resolution only. A further concurrent cloud change will conflict again.
    /// keepLocal=false retains the losing local snapshot in this bounded record's conflict file.
    func resolveConflict(recordID: String, keepLocal: Bool) async throws
    {
        guard !isSynchronizing, let cloud = cloud else { throw TVCloudError.invalidRecord }
        isSynchronizing = true
        defer { isSynchronizing = false }
        guard try await cloud.accountIdentifier() == journal.accountIdentifier else { throw TVCloudError.accountChanged }
        guard var entry = journal.entries[recordID], entry.record.game.id != activeGameID, let remote = entry.conflict else { throw TVCloudError.invalidRecord }
        try Self.validate(remote)
        guard remote.id == entry.record.id, remote.game == entry.record.game, remote.kind == entry.record.kind, remote.slot == entry.record.slot else { throw TVCloudError.invalidRecord }
        if keepLocal
        {
            entry.acknowledgedRevision = remote.revision
            entry.pending = true
            entry.conflict = nil
            journal.entries[recordID] = entry
            try persist()
        }
        else
        {
            // Keep a local recovery copy before replacing the working file.
            let recoveryURL = rootURL.appendingPathComponent("Conflicts/\(recordID).local")
            try Self.copyReplacing(snapshotURL(entry.record), to: recoveryURL)
            let downloadedURL = snapshotURL(remote)
            try await cloud.download(remote, to: downloadedURL)
            try validateDownloadedAsset(remote, at: downloadedURL)
            let prepared = try await TVFileWorker.shared.prepareCopy(downloadedURL, beside: liveURL(remote))
            defer { try? FileManager.default.removeItem(at: prepared) }
            try Task.checkCancellation()
            guard journal.entries[recordID]?.record.revision == entry.record.revision, remote.game.id != activeGameID else { throw TVCloudError.conflict }
            try publish(remote, prepared: prepared)
            journal.entries[recordID] = Entry(record: remote, acknowledgedRevision: remote.revision, pending: false)
            try persist()
            finishPublication(remote)
            cleanupSnapshot(entry.record)
        }
        updateStatus()
    }

    private func stage(game: TVGame, kind: TVCloudAssetKind, slot: String, source: URL, coreIdentifier: String? = nil, coreVersion: String? = nil, preparedSnapshot: URL? = nil, hasRTC: Bool? = nil, hasBatteryRAM: Bool? = nil) throws
    {
        guard Self.safeSlot(slot) else { throw TVCloudError.invalidRecord }
        if kind != .rom, !games.contains(where: { $0.id == game.id }) { throw TVCloudError.invalidRecord }
        let id = "\(game.id).\(kind.rawValue).\(slot)"
        let old = journal.entries[id]
        let size = try Self.fileSize(source)
        guard size > 0, size <= (kind == .rom ? limits.maximumROMBytes : limits.maximumSaveBytes),
              old != nil || journal.entries.count < limits.maximumRecords else { throw TVCloudError.capacityExceeded }
        if kind == .saveState && old == nil
        {
            guard journal.entries.values.filter({ $0.record.game.id == game.id && $0.record.kind == .saveState }).count < limits.maximumSaveSlots else { throw TVCloudError.capacityExceeded }
        }
        let pendingBytes = try journal.entries.values.filter { $0.pending && $0.record.id != id }.reduce(Int64(0)) { total, entry in
            total + (try Self.fileSize(snapshotURL(entry.record)))
        }
        guard pendingBytes + size <= limits.maximumPendingBytes else { throw TVCloudError.capacityExceeded }
        let record = TVCloudRecord(id: id, game: game, kind: kind, slot: slot, revision: UUID().uuidString, modifiedAt: Date(), coreIdentifier: coreIdentifier, coreVersion: coreVersion, hasRTC: hasRTC, hasBatteryRAM: hasBatteryRAM)
        try Self.validate(record)
        if let preparedSnapshot = preparedSnapshot { try Self.installPrepared(preparedSnapshot, at: snapshotURL(record)) }
        else { try Self.copyReplacing(source, to: snapshotURL(record)) }
        journal.entries[id] = Entry(record: record, acknowledgedRevision: old?.acknowledgedRevision, pending: true, conflict: old?.conflict)
        do { try persist() }
        catch
        {
            journal.entries[id] = old
            try? FileManager.default.removeItem(at: snapshotURL(record))
            throw error
        }
        if let old = old { cleanupSnapshot(old.record) }
        updateStatus()
    }

    private func merge(_ remote: TVCloudRecord, cloud: TVCloudTransport) async throws
    {
        guard journal.entries[remote.id] != nil || journal.entries.count < limits.maximumRecords else { throw TVCloudError.capacityExceeded }
        if remote.game.id == activeGameID, remote.kind != .rom
        {
            guard var local = journal.entries[remote.id] else { return }
            if !local.pending
            {
                if local.record.revision != remote.revision
                {
                    local.conflict = remote
                    journal.entries[remote.id] = local
                    try persist()
                }
                return
            }
        }
        if var local = journal.entries[remote.id], local.pending || local.conflict != nil
        {
            if local.record.revision == remote.revision
            {
                if !isLiveAssetAvailable(remote)
                {
                    let destination = snapshotURL(remote)
                    if !FileManager.default.fileExists(atPath: destination.path) { try await cloud.download(remote, to: destination) }
                    try validateDownloadedAsset(remote, at: destination)
                    // Stage calls may have reentered during download.
                    guard journal.entries[remote.id]?.record.revision == remote.revision else { return }
                    let prepared = try await TVFileWorker.shared.prepareCopy(destination, beside: liveURL(remote))
                    defer { try? FileManager.default.removeItem(at: prepared) }
                    try Task.checkCancellation()
                    guard journal.entries[remote.id]?.record.revision == remote.revision, remote.game.id != activeGameID else { return }
                    try publish(remote, prepared: prepared)
                }
                local.acknowledgedRevision = remote.revision
                local.pending = false
                local.conflict = nil
                journal.entries[remote.id] = local
                try persist()
                finishPublication(remote)
            }
            else if local.acknowledgedRevision != remote.revision
            {
                local.conflict = remote
                journal.entries[remote.id] = local
                try persist()
            }
            return
        }
        let needsDownload = journal.entries[remote.id]?.record.revision != remote.revision || !isLiveAssetAvailable(remote)
        if needsDownload
        {
            let destination = snapshotURL(remote)
            try await cloud.download(remote, to: destination)
            try validateDownloadedAsset(remote, at: destination)
            let prepared = try await TVFileWorker.shared.prepareCopy(destination, beside: liveURL(remote))
            defer { try? FileManager.default.removeItem(at: prepared) }
            try Task.checkCancellation()
            // A local save might have arrived during download. Do not overwrite it.
            if journal.entries[remote.id]?.pending == true || (remote.game.id == activeGameID && remote.kind != .rom)
            {
                try await merge(remote, cloud: cloud)
                return
            }
            try publish(remote, prepared: prepared)
            let old = journal.entries[remote.id]?.record
            journal.entries[remote.id] = Entry(record: remote, acknowledgedRevision: remote.revision, pending: false)
            try persist()
            finishPublication(remote)
            if let old = old { cleanupSnapshot(old) }
        }
    }

    private func isLiveAssetAvailable(_ record: TVCloudRecord) -> Bool
    {
        if record.kind != .batterySave || record.hasBatteryRAM == true
        {
            guard FileManager.default.fileExists(atPath: liveURL(record).path) else { return false }
        }
        if record.kind == .batterySave
        {
            if FileManager.default.fileExists(atPath: publicationMarker(record).path) { return false }
            if record.hasRTC == true && !FileManager.default.fileExists(atPath: batteryRTCURL(for: record.game).path) { return false }
        }
        return true
    }
    private func publicationMarker(_ record: TVCloudRecord) -> URL { rootURL.appendingPathComponent("RestoringBattery/\(record.id).json") }
    private func publish(_ record: TVCloudRecord, prepared: URL) throws
    {
        if record.kind == .batterySave
        {
            try writePublicationMarker(record, acknowledgesCloudRevision: true)
            try installBattery(record, from: prepared)
        }
        else { try Self.installPrepared(prepared, at: liveURL(record)) }
    }
    private func writePublicationMarker(_ record: TVCloudRecord, acknowledgesCloudRevision: Bool) throws
    {
        let marker = publicationMarker(record)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let publication = BatteryPublication(record: record, expectedRevision: journal.entries[record.id]?.record.revision,
            acknowledgesCloudRevision: acknowledgesCloudRevision)
        try JSONEncoder().encode(publication).write(to: marker, options: .atomic)
    }
    private func removeIfPresent(_ url: URL) throws
    {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func finishPublication(_ record: TVCloudRecord)
    {
        if record.kind == .batterySave { try? FileManager.default.removeItem(at: publicationMarker(record)) }
    }
    private func installBattery(_ record: TVCloudRecord, from source: URL) throws
    {
        let snapshot = try Self.decodeBattery(from: source, record: record, maximumBytes: limits.maximumSaveBytes)
        let saveURL = batterySaveURL(for: record.game)
        let rtcURL = batteryRTCURL(for: record.game)
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !snapshot.save.isEmpty { try snapshot.save.write(to: saveURL, options: .atomic) }
        else if FileManager.default.fileExists(atPath: saveURL.path) { try FileManager.default.removeItem(at: saveURL) }
        if let rtc = snapshot.rtc { try rtc.write(to: rtcURL, options: .atomic) }
        else if FileManager.default.fileExists(atPath: rtcURL.path) { try FileManager.default.removeItem(at: rtcURL) }
    }

    nonisolated static func decodeBattery(from source: URL, record: TVCloudRecord, maximumBytes: Int64) throws -> TVBatterySnapshot
    {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumBytes else { throw TVCloudError.missingAsset }
        let snapshot = try PropertyListDecoder().decode(TVBatterySnapshot.self, from: Data(contentsOf: source))
        guard snapshot.formatVersion == 1, !snapshot.save.isEmpty || snapshot.rtc?.isEmpty == false,
              !snapshot.save.isEmpty == record.hasBatteryRAM,
              (snapshot.rtc != nil) == record.hasRTC,
              snapshot.save.count + (snapshot.rtc?.count ?? 0) <= maximumBytes else { throw TVCloudError.invalidRecord }
        return snapshot
    }

    private func validateDownloadedAsset(_ record: TVCloudRecord, at url: URL) throws
    {
        let size = try Self.fileSize(url)
        guard size > 0, size <= (record.kind == .rom ? limits.maximumROMBytes : limits.maximumSaveBytes) else { throw TVCloudError.capacityExceeded }
    }

    private var pendingCount: Int { journal.entries.values.filter { $0.pending }.count }
    private func gameDirectory(_ game: TVGame) -> URL { rootURL.appendingPathComponent("Games/\(game.id)", isDirectory: true) }
    private func liveURL(_ record: TVCloudRecord) -> URL
    {
        switch record.kind
        {
        case .rom: return romURL(for: record.game)
        case .batterySave: return batterySaveURL(for: record.game)
        case .saveState: return saveStateURL(for: record.game, slot: record.slot)
        }
    }
    private func snapshotURL(_ record: TVCloudRecord) -> URL { rootURL.appendingPathComponent("Staged/\(record.id).\(record.revision)") }
    private func cleanupSnapshot(_ record: TVCloudRecord)
    {
        guard !uploadingRevisions.contains(record.revision), journal.entries[record.id]?.record.revision != record.revision else { return }
        try? FileManager.default.removeItem(at: snapshotURL(record))
    }
    private func persist() throws
    {
        try JSONEncoder().encode(journal).write(to: rootURL.appendingPathComponent("library.json"), options: .atomic)
    }
    private func updateStatus()
    {
        let count = pendingCount
        let conflictCount = conflicts.count
        let phase: TVCloudStatus.Phase
        let message: String
        if cloud == nil
        {
            phase = .unavailable
            message = "iCloud is not configured. Files exist only in this Apple TV's purgeable cache."
        }
        else if journal.entries.values.contains(where: { $0.record.kind == .batterySave && FileManager.default.fileExists(atPath: publicationMarker($0.record).path) })
        {
            phase = .error
            message = "A battery checkpoint needs recovery before this game can start. Missing unsynced checkpoints cannot be recovered from iCloud."
        }
        else if !missingCloudRecords.isEmpty
        {
            phase = .error
            message = "Previously confirmed files are missing from iCloud. This library needs recovery."
        }
        else if conflictCount > 0
        {
            phase = .conflict
            message = "Different progress exists on another device. Choose a version before syncing these files."
        }
        else if count > 0
        {
            phase = .pending
            message = "\(count) file(s) await iCloud confirmation. Unsynced progress can be lost if tvOS clears its cache."
        }
        else if !journal.entries.isEmpty
        {
            phase = .synced
            message = "All tracked revisions were confirmed by iCloud. New play still needs to sync."
        }
        else
        {
            phase = .idle
            message = "Import a game or restore your library from iCloud."
        }
        status = TVCloudStatus(phase: phase, message: message, pendingCount: count, conflictCount: conflictCount)
        onChange?()
    }
    private static func safeSlot(_ slot: String) -> Bool
    {
        !slot.isEmpty && slot.count <= 40 && slot.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
    }
    static func validate(_ record: TVCloudRecord) throws
    {
        guard UUID(uuidString: record.game.id) != nil, UUID(uuidString: record.revision) != nil,
              safeSlot(record.slot), record.id == "\(record.game.id).\(record.kind.rawValue).\(record.slot)",
              record.game.title.count <= 256, !record.game.title.isEmpty,
              TVSystem(rawValue: record.game.system) != nil else { throw TVCloudError.invalidRecord }
        guard (record.kind != .rom || record.slot == "rom"),
              (record.kind != .batterySave || record.slot == "battery"),
              (record.kind != .batterySave || (record.hasRTC != nil && record.hasBatteryRAM != nil && (record.hasRTC == true || record.hasBatteryRAM == true))),
              (record.kind == .batterySave || (record.hasRTC == nil && record.hasBatteryRAM == nil)) else { throw TVCloudError.invalidRecord }
        let path = record.game.relativeROMPath
        let ext = (path as NSString).pathExtension
        guard TVSystem(rawValue: record.game.system)?.fileExtensions.contains(ext) == true,
              path == "Games/\(record.game.id)/game.\(ext)",
              (record.coreIdentifier?.count ?? 0) <= 256, (record.coreVersion?.count ?? 0) <= 256 else { throw TVCloudError.invalidRecord }
    }
    private static func fileSize(_ url: URL) throws -> Int64
    {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { throw TVCloudError.missingAsset }
        return Int64(size)
    }
    nonisolated static func copyReplacing(_ source: URL, to destination: URL) throws
    {
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try installPrepared(temporary, at: destination)
    }
    nonisolated static func installPrepared(_ temporary: URL, at destination: URL) throws
    {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct TVPreparedBattery: Sendable
{
    let directory: URL
    let save: URL?
    let rtc: URL?
}

/// Serial bounded disk work stays off the UI actor. Publication is an atomic rename on
/// the store's actor only after its revision/account/active-game checks are repeated.
actor TVFileWorker
{
    static let shared = TVFileWorker()
    func prepareBattery(from source: URL, record: TVCloudRecord, maximumBytes: Int64, beside destination: URL) throws -> TVPreparedBattery
    {
        try Task.checkCancellation()
        let snapshot = try TVLibraryStore.decodeBattery(from: source, record: record, maximumBytes: maximumBytes)
        let directory = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do
        {
            let save = snapshot.save.isEmpty ? nil : directory.appendingPathComponent("battery.sav")
            let rtc = snapshot.rtc == nil ? nil : directory.appendingPathComponent("battery.rtc")
            if let save = save { try snapshot.save.write(to: save, options: .atomic) }
            if let rtc = rtc, let data = snapshot.rtc { try data.write(to: rtc, options: .atomic) }
            try Task.checkCancellation()
            return TVPreparedBattery(directory: directory, save: save, rtc: rtc)
        }
        catch
        {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func copy(_ source: URL, to destination: URL) throws
    {
        try Task.checkCancellation()
        try TVLibraryStore.copyReplacing(source, to: destination)
    }
    func prepareCopy(_ source: URL, beside destination: URL) throws -> URL
    {
        try Task.checkCancellation()
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prepared = directory.appendingPathComponent(UUID().uuidString + ".prepared")
        do
        {
            try FileManager.default.copyItem(at: source, to: prepared)
            return prepared
        }
        catch
        {
            try? FileManager.default.removeItem(at: prepared)
            throw error
        }
    }
}
