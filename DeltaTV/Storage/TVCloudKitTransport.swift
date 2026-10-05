// Copyright © 2026 Delta contributors. All rights reserved.

#if canImport(CloudKit)
import CloudKit
import Foundation
import os

/// Private iCloud storage for the tvOS library. This does not read Harmony/Delta Sync.
/// Provision an explicit owner-controlled CloudKit container before constructing this adapter.
@MainActor
final class TVCloudKitTransport: TVCloudTransport
{
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "DeltaTVLibrary-v1", ownerName: CKCurrentUserDefaultName)
    private var account: String?
    private var retryNotBefore: Date?
    private let maximumRecords = 512
    private lazy var sender = ForegroundSender(database: database)

    init(containerIdentifier: String)
    {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
    }

    func accountIdentifier() async throws -> String
    {
        try Task.checkCancellation()
        try checkRetryDelay()
        do
        {
            guard try await container.accountStatus() == .available else
            {
                throw TVCloudError.unavailable("Sign into iCloud in Apple TV Settings to back up and restore this library.")
            }
            let identifier = try await container.userRecordID().recordName
            if let previous = account, previous != identifier { throw TVCloudError.accountChanged }
            account = identifier
            return identifier
        }
        catch { throw translated(error) }
    }

    func records() async throws -> [TVCloudRecord]
    {
        _ = try await accountIdentifier()
        try await ensureZone()
        // Zone changes are authoritative and do not depend on eventually consistent queries.
        // A nil token also recovers after a whole cache purge or reinstall.
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.desiredKeys = ["metadata"]
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = true
        let resultBox = RecordScan(maximumRecords: maximumRecords)
        let result: [TVCloudRecord]
        do
        {
            result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    operation.recordWasChangedBlock = { _, result in
                        switch result
                        {
                        case .success(let record): resultBox.receive(record)
                        case .failure(let error): resultBox.fail(error)
                        }
                    }
                    operation.recordWithIDWasDeletedBlock = { recordID, _ in resultBox.remove(recordID) }
                    operation.recordZoneFetchResultBlock = { _, result in
                        if case .failure(let error) = result { resultBox.fail(error) }
                    }
                    operation.fetchRecordZoneChangesResultBlock = { result in
                        if case .failure(let error) = result { resultBox.fail(error) }
                        continuation.resume(with: resultBox.result())
                    }
                    database.add(operation)
                }
            } onCancel: {
                // CKOperation is Apple's Sendable cancellation boundary. No actor state is touched.
                operation.cancel()
            }
            try Task.checkCancellation()
        }
        catch { throw translated(error) }
        _ = try await accountIdentifier()
        return result
    }

    func download(_ record: TVCloudRecord, to destination: URL) async throws
    {
        _ = try await accountIdentifier()
        do
        {
            let remote = try await database.record(for: recordID(record.id))
            let metadata = try Self.metadata(remote)
            guard metadata == record else { throw TVCloudError.conflict }
            guard let asset = remote["asset"] as? CKAsset, let source = asset.fileURL else { throw TVCloudError.missingAsset }
            // CKAsset's staging URL is ephemeral. Copy before returning from this request.
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let maximum = record.kind == .rom ? 16_777_216 : 4_194_304
            guard size > 0, size <= maximum else { throw TVCloudError.capacityExceeded }
            try await TVFileWorker.shared.copy(source, to: destination)
            _ = try await accountIdentifier()
        }
        catch { throw translated(error) }
    }

    func upload(_ record: TVCloudRecord, fileURL: URL, replacing revision: String?) async throws
    {
        _ = try await accountIdentifier()
        try TVLibraryStore.validate(record)
        do
        {
            var remote: CKRecord
            do
            {
                remote = try await database.record(for: recordID(record.id))
                let current = try Self.metadata(remote)
                // The last request may have succeeded while its response was lost.
                if current.revision == record.revision
                {
                    _ = try await accountIdentifier()
                    return
                }
                guard current.revision == revision else { throw TVCloudError.conflict }
            }
            catch let error as CKError where error.code == .unknownItem
            {
                guard revision == nil else { throw TVCloudError.conflict }
                remote = CKRecord(recordType: "DeltaTVAsset", recordID: recordID(record.id))
            }
            remote["metadata"] = try JSONEncoder().encode(record) as NSData
            remote["asset"] = CKAsset(fileURL: fileURL)
            _ = try await accountIdentifier()
            try Task.checkCancellation()
            // The fetched record's change tag closes the race between fetch and save.
            // Never use .allKeys/.changedKeys: they silently overwrite concurrent progress.
            let acknowledged = try await sender.send(remote)
            guard try Self.metadata(acknowledged).revision == record.revision else { throw TVCloudError.invalidRecord }
            _ = try await accountIdentifier()
        }
        catch { throw translated(error) }
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    private func ensureZone() async throws
    {
        do
        {
            do { _ = try await database.recordZone(for: zoneID) }
            catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem
            {
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
            }
        }
        catch { throw translated(error) }
    }
    private func checkRetryDelay() throws
    {
        if let date = retryNotBefore, date > Date() { throw TVCloudError.retryLater(date) }
    }
    private func translated(_ error: Error) -> Error
    {
        guard let error = error as? CKError else { return error }
        if error.code == .serverRecordChanged { return TVCloudError.conflict }
        if error.code == .partialFailure, let errors = error.partialErrorsByItemID
        {
            if let conflict = errors.values.first(where: { ($0 as? CKError)?.code == .serverRecordChanged }) { return translated(conflict) }
            if let first = errors.values.first { return translated(first) }
        }
        if let delay = error.retryAfterSeconds
        {
            let date = Date().addingTimeInterval(max(1, delay))
            retryNotBefore = date
            return TVCloudError.retryLater(date)
        }
        switch error.code
        {
        case .quotaExceeded: return TVCloudError.unavailable("iCloud storage is full. Free space or upgrade storage in your Apple account; new progress has not been backed up.")
        case .notAuthenticated: return TVCloudError.unavailable("iCloud is signed out. New progress has not been backed up.")
        case .badContainer, .missingEntitlement: return TVCloudError.unavailable("This build is not provisioned for its iCloud container. Contact the build owner; new progress has not been backed up.")
        case .networkFailure, .networkUnavailable: return TVCloudError.unavailable("iCloud is offline. Retry when connected; new progress has not been backed up.")
        default: return error
        }
    }
    nonisolated private static func metadata(_ record: CKRecord) throws -> TVCloudRecord
    {
        guard record.recordType == "DeltaTVAsset", let data = record["metadata"] as? Data, data.count <= 16_384 else { throw TVCloudError.invalidRecord }
        let metadata = try JSONDecoder().decode(TVCloudRecord.self, from: data)
        guard metadata.id == record.recordID.recordName else { throw TVCloudError.invalidRecord }
        return metadata
    }

    /// CKSyncEngine owns the outgoing CloudKit operation and its serialized delegate
    /// events. Explicit foreground mode is deliberate: the store owns the only durable
    /// pending journal, and an immutable CKAsset file is retained only for this call.
    /// Do not enable automatic scheduling without extending that file-lifetime contract.
    @MainActor
    private final class ForegroundSender: CKSyncEngineDelegate
    {
        private let database: CKDatabase
        private var record: CKRecord?
        private var result: Result<CKRecord, Error>?
        private var batchProvided = false
        private var accountChanged = false
        private lazy var engine: CKSyncEngine = {
            var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: nil, delegate: self)
            configuration.automaticallySync = false
            return CKSyncEngine(configuration)
        }()

        init(database: CKDatabase) { self.database = database }

        func send(_ record: CKRecord) async throws -> CKRecord
        {
            guard self.record == nil else { throw TVCloudError.unavailable("A cloud send is already in progress.") }
            self.record = record
            self.result = nil
            self.batchProvided = false
            self.accountChanged = false
            let engine = self.engine
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            defer
            {
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                self.record = nil
                self.result = nil
            }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .recordIDs([record.recordID])))
            } onCancel: {
                Task { await engine.cancelOperations() }
            }
            if accountChanged { throw TVCloudError.accountChanged }
            guard let result = result else { throw TVCloudError.unavailable("iCloud has not acknowledged this file. Retry to check its status.") }
            return try result.get()
        }

        func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch?
        {
            guard !batchProvided, let record = record, context.options.scope.contains(record.recordID) else { return nil }
            batchProvided = true
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: [record], recordIDsToDelete: [], atomicByZone: true)
        }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async
        {
            switch event
            {
            case .sentRecordZoneChanges(let sent):
                guard let record = record else { return }
                if let saved = sent.savedRecords.first(where: { $0.recordID == record.recordID }) { result = .success(saved) }
                if let failed = sent.failedRecordSaves.first(where: { $0.record.recordID == record.recordID }) { result = .failure(failed.error) }
            case .accountChange(let change):
                switch change.changeType
                {
                case .signIn: break // Initial account discovery is not an account switch.
                case .signOut, .switchAccounts: accountChanged = true
                @unknown default: accountChanged = true
                }
            default:
                // No fetch token is persisted: recovery performs a full metadata-only
                // zone scan. Pending writes are reconstructed from TVLibraryStore.
                break
            }
        }
    }

    /// A checked Sendable wrapper: every mutable field is scoped inside Apple's lock.
    /// No CKRecord or actor-owned object escapes a CloudKit callback through this buffer.
    private final class RecordScan: Sendable
    {
        private struct State: Sendable
        {
            var records: [String: TVCloudRecord] = [:]
            var error: Error?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let maximumRecords: Int
        init(maximumRecords: Int) { self.maximumRecords = maximumRecords }
        func receive(_ record: CKRecord)
        {
            do
            {
                let value = try TVCloudKitTransport.metadata(record)
                state.withLock { state in
                    guard state.error == nil else { return }
                    guard state.records[value.id] != nil || state.records.count < maximumRecords else
                    {
                        state.error = TVCloudError.capacityExceeded
                        return
                    }
                    state.records[value.id] = value
                }
            }
            catch { fail(error) }
        }
        func remove(_ id: CKRecord.ID)
        {
            state.withLock { state in _ = state.records.removeValue(forKey: id.recordName) }
        }
        func fail(_ error: Error)
        {
            state.withLock { state in state.error = state.error ?? error }
        }
        func result() -> Result<[TVCloudRecord], Error>
        {
            state.withLock { state in
                if let error = state.error { return .failure(error) }
                return .success(Array(state.records.values))
            }
        }
    }
}
#endif
