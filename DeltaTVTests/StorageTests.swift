import Foundation

private enum TestFailure: Error { case failed(String), offline }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws
{
    if !value() { throw TestFailure.failed(message) }
}

@MainActor
private final class FakeCloud: TVCloudTransport
{
    var account = "account-A"
    var values: [String: (TVCloudRecord, Data)] = [:]
    var offline = false
    var loseNextAcknowledgment = false
    var beforeUpload: (() throws -> Void)?
    var uploads = 0
    func accountIdentifier() async throws -> String
    {
        if offline { throw TestFailure.offline }
        return account
    }
    func records() async throws -> [TVCloudRecord] { values.values.map { $0.0 } }
    func download(_ record: TVCloudRecord, to destination: URL) async throws
    {
        guard let (metadata, bytes) = values[record.id], metadata.revision == record.revision else { throw TVCloudError.conflict }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
    }
    func upload(_ record: TVCloudRecord, fileURL: URL, replacing revision: String?) async throws
    {
        if values[record.id]?.0.revision == record.revision { return }
        guard values[record.id]?.0.revision == revision else { throw TVCloudError.conflict }
        let bytes = try Data(contentsOf: fileURL)
        let callback = beforeUpload
        beforeUpload = nil
        try callback?()
        values[record.id] = (record, bytes)
        uploads += 1
        if loseNextAcknowledgment
        {
            loseNextAcknowledgment = false
            throw TestFailure.offline
        }
    }
}

@main
struct StorageTests
{
    @MainActor static func main() async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeltaTVStorageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rom = directory.appendingPathComponent("owned.gb")
        try Data([1, 2, 3, 4]).write(to: rom)
        var passed = 0

        // Local-only and offline data must never be advertised as acknowledged.
        let local = try TVLibraryStore(rootURL: directory.appendingPathComponent("local"))
        let localGame = try await local.importGame(at: rom, title: "Owned Game", system: "gb")
        try require(local.status.phase == .unavailable && !local.hasCloudBackup(localGame), "Local-only import claimed a cloud backup")
        await local.synchronize()
        try require(local.status.pendingCount == 1, "Local-only import lost pending state")
        passed += 1

        let cloud = FakeCloud()
        let rootA = directory.appendingPathComponent("A")
        var a = try TVLibraryStore(rootURL: rootA, cloud: cloud)
        let game = try await a.importGame(at: rom, title: "Owned Game", system: "gb")
        cloud.offline = true
        await a.synchronize()
        try require(a.status.phase == .error && a.status.pendingCount == 1, "Offline save was acknowledged")
        a = try TVLibraryStore(rootURL: rootA, cloud: cloud)
        try require(a.status.pendingCount == 1, "Pending state did not survive restart")
        cloud.offline = false
        await a.synchronize()
        try require(a.hasCloudBackup(game), "Server acknowledgment was not recorded")
        passed += 1

        try Data([5]).write(to: a.batterySaveURL(for: game))
        try a.stageBatterySave(for: game)
        try Data([6]).write(to: a.saveStateURL(for: game))
        try a.stageSaveState(for: game, coreIdentifier: "test.core", coreVersion: "1")
        await a.synchronize()
        try require(a.status.phase == .synced && cloud.values.count == 3, "ROM/save/state did not sync")
        try FileManager.default.removeItem(at: rootA)
        a = try TVLibraryStore(rootURL: rootA, cloud: cloud)
        await a.restore()
        try require(a.games == [game] && a.hasCloudBackup(game), "Cold restore did not rebuild manifest")
        try require(tryData(a.romURL(for: game)) == Data([1, 2, 3, 4]), "Cold restore lost ROM")
        try require(tryData(a.batterySaveURL(for: game)) == Data([5]), "Cold restore lost battery save")
        try require(tryData(a.saveStateURL(for: game)) == Data([6]), "Cold restore lost save state")
        try require(a.saveStateIsCompatible(game, coreIdentifier: "test.core", coreVersion: "1"), "Restored state lost core compatibility")
        try require(!a.saveStateIsCompatible(game, coreIdentifier: "test.core", coreVersion: "2"), "Foreign core state was considered compatible")
        passed += 1

        try FileManager.default.removeItem(at: a.romURL(for: game))
        await a.restore()
        try require(a.isAvailableLocally(game), "Individual missing cache file was not restored")
        passed += 1

        let b = try TVLibraryStore(rootURL: directory.appendingPathComponent("B"), cloud: cloud)
        await b.restore()
        try Data([7]).write(to: a.batterySaveURL(for: game))
        try a.stageBatterySave(for: game)
        try Data([8]).write(to: b.batterySaveURL(for: game))
        try b.stageBatterySave(for: game)
        await a.synchronize()
        await b.synchronize()
        try require(b.status.phase == .conflict && b.conflicts.count == 1, "Concurrent progress silently overwrote")
        try require(tryData(b.batterySaveURL(for: game)) == Data([8]), "Conflict destroyed local progress")
        let saveID = b.conflicts[0].id
        try require(batteryBytes(cloud.values[saveID]?.1) == Data([7]), "Conflict destroyed remote progress")
        try await b.resolveConflict(recordID: saveID, keepLocal: true)
        await b.synchronize()
        try require(batteryBytes(cloud.values[saveID]?.1) == Data([8]) && b.status.phase == .synced, "Explicit local conflict resolution failed")
        passed += 1

        // An acknowledged older upload must not clear a newer save staged during that upload.
        try Data([9]).write(to: b.batterySaveURL(for: game))
        try b.stageBatterySave(for: game)
        cloud.beforeUpload = {
            try Data([10]).write(to: b.batterySaveURL(for: game))
            try b.stageBatterySave(for: game)
        }
        await b.synchronize()
        try require(b.status.pendingCount == 1 && batteryBytes(cloud.values[saveID]?.1) == Data([9]), "In-flight acknowledgment swallowed newer local progress")
        await b.synchronize()
        try require(b.status.phase == .synced && batteryBytes(cloud.values[saveID]?.1) == Data([10]), "Newer coalesced revision failed to upload")
        passed += 1

        cloud.loseNextAcknowledgment = true
        try Data([11]).write(to: b.batterySaveURL(for: game))
        try b.stageBatterySave(for: game)
        await b.synchronize()
        try require(b.status.phase == .error && b.status.pendingCount == 1, "Ambiguous response was incorrectly acknowledged")
        let uploads = cloud.uploads
        await b.synchronize()
        try require(b.status.phase == .synced && cloud.uploads == uploads, "Ambiguous success did not recover idempotently")
        passed += 1

        cloud.account = "account-B"
        try Data([12]).write(to: b.batterySaveURL(for: game))
        try b.stageBatterySave(for: game)
        await b.synchronize()
        try require(b.status.phase == .error && cloud.uploads == uploads, "Old user's data uploaded to a different iCloud account")
        cloud.account = "account-A"
        passed += 1

        let small = TVStorageLimits(maximumRecords: 3, maximumPendingBytes: 1_024, maximumROMBytes: 8, maximumSaveBytes: 256, maximumSaveSlots: 1)
        let bounded = try TVLibraryStore(rootURL: directory.appendingPathComponent("bounded"), cloud: FakeCloud(), limits: small)
        let boundedGame = try await bounded.importGame(at: rom, title: "Bounded", system: "gb")
        for byte in UInt8(0)..<30
        {
            try Data([byte]).write(to: bounded.batterySaveURL(for: boundedGame))
            try bounded.stageBatterySave(for: boundedGame)
        }
        let staged = try FileManager.default.contentsOfDirectory(atPath: bounded.rootURL.appendingPathComponent("Staged").path)
        try require(staged.count == 2 && bounded.status.pendingCount == 2, "Offline queue grew per save")
        try Data(repeating: 1, count: 257).write(to: bounded.batterySaveURL(for: boundedGame))
        do { try bounded.stageBatterySave(for: boundedGame); throw TestFailure.failed("Oversized save was accepted") }
        catch TVCloudError.capacityExceeded { }
        do { try bounded.stageSaveState(for: boundedGame, slot: "../../escape"); throw TestFailure.failed("Traversal slot was accepted") }
        catch TVCloudError.invalidRecord { }
        passed += 1

        // Untrusted cloud paths cannot write outside this app's intended game directory.
        let badCloud = FakeCloud()
        let evilGame = TVGame(id: UUID().uuidString, title: "Bad", system: "gb", relativeROMPath: "../escape.gb")
        let bad = TVCloudRecord(id: "\(evilGame.id).rom.rom", game: evilGame, kind: .rom, slot: "rom", revision: UUID().uuidString, modifiedAt: Date())
        badCloud.values[bad.id] = (bad, Data([1]))
        let victim = try TVLibraryStore(rootURL: directory.appendingPathComponent("victim"), cloud: badCloud)
        await victim.restore()
        try require(victim.status.phase == .error && victim.games.isEmpty, "Invalid remote metadata was trusted")
        passed += 1

        // Choosing cloud progress preserves the local losing revision for manual recovery.
        await a.synchronize()
        try Data([13]).write(to: a.batterySaveURL(for: game))
        try a.stageBatterySave(for: game)
        await a.synchronize()
        await b.synchronize()
        try require(b.conflicts.count == 1, "Expected explicit cloud-resolution conflict")
        try await b.resolveConflict(recordID: saveID, keepLocal: false)
        try require(tryData(b.batterySaveURL(for: game)) == Data([13]), "Chosen cloud progress was not restored")
        try require(batteryBytes(tryData(b.rootURL.appendingPathComponent("Conflicts/\(saveID).local"))) == Data([12]), "Discarded local progress was not retained")
        passed += 1

        // A remotely deleted record invalidates cloud-safe UI rather than silently resurrecting it.
        let saved = cloud.values.removeValue(forKey: saveID)
        await b.synchronize()
        try require(b.status.phase == .error && !b.hasCloudBackup(game), "Missing cloud data was still labeled backed up")
        cloud.values[saveID] = saved
        passed += 1

        // Cache eviction of unacknowledged data is detectable, never converted into a cloud ack.
        let doomedCloud = FakeCloud()
        let doomed = try TVLibraryStore(rootURL: directory.appendingPathComponent("doomed"), cloud: doomedCloud)
        _ = try await doomed.importGame(at: rom, title: "Doomed", system: "gb")
        try FileManager.default.removeItem(at: doomed.rootURL.appendingPathComponent("Staged"))
        await doomed.synchronize()
        try require(doomed.status.phase == .error && doomed.status.pendingCount == 1 && doomedCloud.values.isEmpty, "Purged unsynced data was falsely acknowledged")
        passed += 1

        // Limits apply to both local imports and untrusted remote assets.
        let oversized = try TVLibraryStore(rootURL: directory.appendingPathComponent("oversized"), cloud: cloud,
            limits: TVStorageLimits(maximumRecords: 10, maximumPendingBytes: 10, maximumROMBytes: 2, maximumSaveBytes: 2, maximumSaveSlots: 1))
        await oversized.restore()
        try require(oversized.status.phase == .error && !oversized.isAvailableLocally(game), "Oversized remote ROM bypassed limits")
        passed += 1

        // The cloud acknowledges battery RAM and RTC as one revision, and can recover RTC-only eviction.
        let rtcCloud = FakeCloud()
        let rtcRoot = directory.appendingPathComponent("rtc")
        var rtcStore = try TVLibraryStore(rootURL: rtcRoot, cloud: rtcCloud)
        let rtcGame = try await rtcStore.importGame(at: rom, title: "RTC Game", system: "gb")
        try Data([21]).write(to: rtcStore.batterySaveURL(for: rtcGame))
        try Data([22]).write(to: rtcStore.batteryRTCURL(for: rtcGame))
        try rtcStore.stageBatterySave(for: rtcGame)
        await rtcStore.synchronize()
        let rtcRecord = rtcCloud.values.values.first { $0.0.kind == .batterySave }!.0
        let rtcPayload = rtcCloud.values[rtcRecord.id]!.1
        let rtcSnapshot = try PropertyListDecoder().decode(TVBatterySnapshot.self, from: rtcPayload)
        try require(rtcSnapshot.save == Data([21]) && rtcSnapshot.rtc == Data([22]), "Battery and RTC were not one cloud asset")
        try FileManager.default.removeItem(at: rtcStore.batteryRTCURL(for: rtcGame))
        await rtcStore.restore()
        try require(tryData(rtcStore.batteryRTCURL(for: rtcGame)) == Data([22]), "RTC-only cache eviction did not recover")
        passed += 1

        // A crash midway through the local pair publication is repaired before launch.
        struct Marker: Codable { let record: TVCloudRecord; let expectedRevision: String? }
        let marker = rtcRoot.appendingPathComponent("RestoringBattery/\(rtcRecord.id).json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Marker(record: rtcRecord, expectedRevision: rtcRecord.revision)).write(to: marker)
        try Data([99]).write(to: rtcStore.batterySaveURL(for: rtcGame))
        rtcStore = try TVLibraryStore(rootURL: rtcRoot, cloud: rtcCloud)
        try require(tryData(rtcStore.batterySaveURL(for: rtcGame)) == Data([21]) && rtcStore.isAvailableLocally(rtcGame), "Interrupted battery publication did not repair")
        passed += 1

        // Replaying a stale marker must never replace a newer offline revision.
        try JSONEncoder().encode(Marker(record: rtcRecord, expectedRevision: rtcRecord.revision)).write(to: marker)
        try Data([23]).write(to: rtcStore.batterySaveURL(for: rtcGame))
        try Data([24]).write(to: rtcStore.batteryRTCURL(for: rtcGame))
        try rtcStore.stageBatterySave(for: rtcGame)
        rtcStore = try TVLibraryStore(rootURL: rtcRoot, cloud: rtcCloud)
        try require(tryData(rtcStore.batterySaveURL(for: rtcGame)) == Data([23]) && rtcStore.status.pendingCount == 1, "Stale restore marker overwrote newer offline progress")
        passed += 1

        // A new remote state for the currently playing game is deferred, not recursively downloaded.
        let remoteWriter = try TVLibraryStore(rootURL: directory.appendingPathComponent("remoteWriter"), cloud: rtcCloud)
        await remoteWriter.restore()
        rtcStore.activeGameID = rtcGame.id
        try Data([25]).write(to: remoteWriter.saveStateURL(for: rtcGame, slot: "new"))
        try remoteWriter.stageSaveState(for: rtcGame, slot: "new", coreIdentifier: "test.core", coreVersion: "1")
        await remoteWriter.synchronize()
        await rtcStore.synchronize()
        try require(!rtcStore.hasSaveState(rtcGame, slot: "new"), "Remote state was installed into active game's files")
        rtcStore.activeGameID = nil
        await rtcStore.restore()
        try require(rtcStore.hasSaveState(rtcGame, slot: "new"), "Deferred remote state never recovered after play stopped")
        passed += 1

        // An account switch during an upload cannot become an acknowledgment in the old journal.
        try Data([26]).write(to: rtcStore.batterySaveURL(for: rtcGame))
        try rtcStore.stageBatterySave(for: rtcGame)
        rtcCloud.beforeUpload = { rtcCloud.account = "account-B" }
        await rtcStore.synchronize()
        try require(rtcStore.status.phase == .error && rtcStore.status.pendingCount == 1, "Mid-upload account change was acknowledged")
        rtcCloud.account = "account-A"
        passed += 1

        // Fixed-slot validation prevents multiple remote records aliasing the same local file.
        let alias = TVCloudRecord(id: "\(game.id).rom.other", game: game, kind: .rom, slot: "other", revision: UUID().uuidString, modifiedAt: Date())
        do { try TVLibraryStore.validate(alias); throw TestFailure.failed("ROM alias slot was accepted") }
        catch TVCloudError.invalidRecord { }
        passed += 1

        // Timer-only MBC3 cartridges can have RTC bytes without a RAM save file.
        let timerCloud = FakeCloud()
        let timerRoot = directory.appendingPathComponent("timerOnly")
        var timer = try TVLibraryStore(rootURL: timerRoot, cloud: timerCloud)
        let timerGame = try await timer.importGame(at: rom, title: "Timer only", system: "gb")
        try Data([1, 2, 3, 4]).write(to: timer.batteryRTCURL(for: timerGame))
        try timer.stageBatterySave(for: timerGame)
        await timer.synchronize()
        try FileManager.default.removeItem(at: timerRoot)
        timer = try TVLibraryStore(rootURL: timerRoot, cloud: timerCloud)
        await timer.restore()
        try require(timer.status.phase == .synced && timer.isAvailableLocally(timerGame), "Timer-only cartridge did not restore")
        try require(tryData(timer.batteryRTCURL(for: timerGame)) == Data([1, 2, 3, 4]), "Timer-only clock bytes were lost")
        passed += 1

        // A ROM surviving alone must not let a fresh game overwrite evicted cloud progress.
        try FileManager.default.removeItem(at: timer.batteryRTCURL(for: timerGame))
        timerCloud.offline = true
        await timer.synchronize()
        try require(!timer.isAvailableLocally(timerGame), "ROM-only offline cache was incorrectly playable after save eviction")
        passed += 1

        // Both live files can exist yet belong to different native-core checkpoints.
        let reconcileCloud = FakeCloud()
        let reconcileRoot = directory.appendingPathComponent("reconcile")
        var reconcile = try TVLibraryStore(rootURL: reconcileRoot, cloud: reconcileCloud)
        let reconcileGame = try await reconcile.importGame(at: rom, title: "Reconcile", system: "gb")
        try Data([31]).write(to: reconcile.batterySaveURL(for: reconcileGame))
        try Data([32]).write(to: reconcile.batteryRTCURL(for: reconcileGame))
        try reconcile.stageBatterySave(for: reconcileGame)
        await reconcile.synchronize()
        try Data([99]).write(to: reconcile.batterySaveURL(for: reconcileGame))
        try require(reconcile.isAvailableLocally(reconcileGame), "Torn-write fixture must have both files present")
        try await reconcile.prepareForLaunch(reconcileGame)
        try require(tryData(reconcile.batterySaveURL(for: reconcileGame)) == Data([31]) && tryData(reconcile.batteryRTCURL(for: reconcileGame)) == Data([32]), "Torn native pair did not reconcile to journal checkpoint")
        try require(reconcile.status.pendingCount == 0 && reconcile.hasCloudBackup(reconcileGame), "Reconciliation changed acknowledged journal state")
        passed += 1

        // A newer pending checkpoint, rather than the older cloud version, is authoritative.
        try Data([33]).write(to: reconcile.batterySaveURL(for: reconcileGame))
        try Data([34]).write(to: reconcile.batteryRTCURL(for: reconcileGame))
        try reconcile.stageBatterySave(for: reconcileGame)
        try Data([99]).write(to: reconcile.batteryRTCURL(for: reconcileGame))
        try await reconcile.prepareForLaunch(reconcileGame)
        try require(tryData(reconcile.batterySaveURL(for: reconcileGame)) == Data([33]) && tryData(reconcile.batteryRTCURL(for: reconcileGame)) == Data([34]), "Reconciliation discarded newer offline progress")
        try require(reconcile.status.pendingCount == 1 && !reconcile.hasCloudBackup(reconcileGame), "Reconciliation falsely acknowledged pending data")
        passed += 1

        // Never replace files while any core is active.
        reconcile.activeGameID = reconcileGame.id
        try Data([97]).write(to: reconcile.batterySaveURL(for: reconcileGame))
        do { try await reconcile.prepareForLaunch(reconcileGame); throw TestFailure.failed("Prepared active game's files") }
        catch TVCloudError.unavailable { }
        try require(tryData(reconcile.batterySaveURL(for: reconcileGame)) == Data([97]), "Reconciliation touched an active core's files")
        reconcile.activeGameID = nil
        passed += 1

        // Missing pending bundle is an explicit block, even when both live files survive.
        let currentFiles = try FileManager.default.contentsOfDirectory(at: reconcileRoot.appendingPathComponent("Staged"), includingPropertiesForKeys: nil)
        let pendingSnapshot = currentFiles.first { $0.lastPathComponent.contains(".batterySave.battery.") }!
        try FileManager.default.removeItem(at: pendingSnapshot)
        do { try await reconcile.prepareForLaunch(reconcileGame); throw TestFailure.failed("Started without authoritative pending checkpoint") }
        catch TVCloudError.unavailable { }
        try require(!reconcile.isAvailableLocally(reconcileGame) && reconcile.status.phase == .error && reconcile.status.pendingCount == 1, "Missing pending checkpoint was not blocked truthfully")
        reconcile = try TVLibraryStore(rootURL: reconcileRoot, cloud: reconcileCloud)
        try require(!reconcile.isAvailableLocally(reconcileGame) && reconcile.status.phase == .error && reconcile.status.pendingCount == 1, "Restart discarded blocked pending checkpoint")
        passed += 1

        // A missing acknowledged bundle can be recovered online before launching.
        let recoveredRoot = directory.appendingPathComponent("recoveredCheckpoint")
        let recovered = try TVLibraryStore(rootURL: recoveredRoot, cloud: reconcileCloud)
        await recovered.restore()
        let acknowledgedRecord = reconcileCloud.values.values.first { $0.0.kind == .batterySave }!.0
        let acknowledgedSnapshot = recoveredRoot.appendingPathComponent("Staged/\(acknowledgedRecord.id).\(acknowledgedRecord.revision)")
        try FileManager.default.removeItem(at: acknowledgedSnapshot)
        do { try await recovered.prepareForLaunch(reconcileGame); throw TestFailure.failed("Trusted mixed live pair with missing checkpoint") }
        catch TVCloudError.unavailable { }
        try require(!recovered.isAvailableLocally(reconcileGame), "Missing acknowledged checkpoint did not block launch")
        await recovered.restore()
        try await recovered.prepareForLaunch(reconcileGame)
        try require(recovered.isAvailableLocally(reconcileGame) && tryData(recovered.batterySaveURL(for: reconcileGame)) == Data([31]), "Acknowledged checkpoint did not recover from cloud")
        passed += 1

        // A process crash between reconciliation's renames preserves pending status on restart.
        try Data([35]).write(to: recovered.batterySaveURL(for: reconcileGame))
        try Data([36]).write(to: recovered.batteryRTCURL(for: reconcileGame))
        try recovered.stageBatterySave(for: reconcileGame)
        let journalData = try Data(contentsOf: recoveredRoot.appendingPathComponent("library.json"))
        let journalObject = try JSONSerialization.jsonObject(with: journalData) as! [String: Any]
        let entries = journalObject["entries"] as! [String: Any]
        let batteryEntry = entries[acknowledgedRecord.id] as! [String: Any]
        let pendingRecordData = try JSONSerialization.data(withJSONObject: batteryEntry["record"]!)
        let pendingRecord = try JSONDecoder().decode(TVCloudRecord.self, from: pendingRecordData)
        struct ReconciliationMarker: Codable { let record: TVCloudRecord; let expectedRevision: String?; let acknowledgesCloudRevision: Bool }
        let interruptedMarker = recoveredRoot.appendingPathComponent("RestoringBattery/\(pendingRecord.id).json")
        try FileManager.default.createDirectory(at: interruptedMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ReconciliationMarker(record: pendingRecord, expectedRevision: pendingRecord.revision, acknowledgesCloudRevision: false)).write(to: interruptedMarker)
        try Data([96]).write(to: recovered.batteryRTCURL(for: reconcileGame))
        let replayed = try TVLibraryStore(rootURL: recoveredRoot, cloud: reconcileCloud)
        try require(tryData(replayed.batterySaveURL(for: reconcileGame)) == Data([35]) && tryData(replayed.batteryRTCURL(for: reconcileGame)) == Data([36]), "Interrupted reconciliation did not repair the pair")
        try require(replayed.status.pendingCount == 1 && !replayed.hasCloudBackup(reconcileGame), "Reconciliation marker replay falsely acknowledged offline data")
        passed += 1

        // Timer-only checkpoints remove stale RAM and restore their recorded clock.
        try Data([88]).write(to: timer.batterySaveURL(for: timerGame))
        try Data([89]).write(to: timer.batteryRTCURL(for: timerGame))
        try await timer.prepareForLaunch(timerGame)
        try require(!FileManager.default.fileExists(atPath: timer.batterySaveURL(for: timerGame).path) && tryData(timer.batteryRTCURL(for: timerGame)) == Data([1, 2, 3, 4]), "Timer-only reconciliation retained unrelated RAM")
        passed += 1

        // Independent review: pre-cancelled launch preparation must not publish files or markers.
        try Data([77]).write(to: replayed.batterySaveURL(for: reconcileGame))
        try Data([78]).write(to: replayed.batteryRTCURL(for: reconcileGame))
        let cancelledPreparation = Task { @MainActor in try await replayed.prepareForLaunch(reconcileGame) }
        cancelledPreparation.cancel()
        do { try await cancelledPreparation.value; throw TestFailure.failed("Cancelled preparation unexpectedly succeeded") }
        catch is CancellationError { }
        try require(tryData(replayed.batterySaveURL(for: reconcileGame)) == Data([77]) && tryData(replayed.batteryRTCURL(for: reconcileGame)) == Data([78]), "Cancelled preparation changed live files")
        try require(!FileManager.default.fileExists(atPath: interruptedMarker.path), "Cancelled preparation created a publication marker")
        try require(replayed.status.pendingCount == 1 && !replayed.hasCloudBackup(reconcileGame), "Cancellation changed pending acknowledgment")
        passed += 1

        // Opaque non-cartridge bytes exercise the same journal protocol for every
        // system. Actual cartridge loading is a separate opt-in runtime test.
        for system in TVSystem.allCases {
            let input = directory.appendingPathComponent("opaque." + system.fileExtensions[0])
            try Data([1, 2, 3, 4]).write(to: input)
            let transport = FakeCloud()
            let root = directory.appendingPathComponent("system-" + system.rawValue)
            let library = try TVLibraryStore(rootURL: root, cloud: transport)
            let item = try await library.importGame(at: input, title: "Owned input", system: system.rawValue)
            try Data([71]).write(to: library.batterySaveURL(for: item))
            try library.stageBatterySave(for: item)
            try Data([72]).write(to: library.saveStateURL(for: item))
            try library.stageSaveState(for: item, coreIdentifier: "core." + system.rawValue, coreVersion: "tv1")
            await library.synchronize()
            try require(library.hasCloudBackup(item), "System backup was not acknowledged")
            try FileManager.default.removeItem(at: root)
            let cold = try TVLibraryStore(rootURL: root, cloud: transport)
            await cold.restore()
            try await cold.prepareForLaunch(item)
            try require(cold.games == [item] && cold.hasCloudBackup(item), "System cold recovery lost the journal")
            try require(tryData(cold.batterySaveURL(for: item)) == Data([71]) && tryData(cold.saveStateURL(for: item)) == Data([72]), "System cold recovery lost progress")
            let wrong = TVGame(id: item.id, title: item.title, system: system == .nes ? "ds" : "nes", relativeROMPath: item.relativeROMPath)
            let record = TVCloudRecord(id: "\(item.id).rom.rom", game: wrong, kind: .rom, slot: "rom", revision: UUID().uuidString, modifiedAt: Date())
            do { try TVLibraryStore.validate(record); throw TestFailure.failed("Mismatched system and extension accepted") }
            catch TVCloudError.invalidRecord {}
            passed += 1
        }
        print("PASS: \(passed) storage scenarios (offline/restart, cold + partial purge, all systems, conflicts, in-flight saves, ambiguous acknowledgments, account isolation, bounded queue, untrusted paths)")
    }

    private static func batteryBytes(_ data: Data?) -> Data?
    {
        guard let data = data else { return nil }
        return (try? PropertyListDecoder().decode(TVBatterySnapshot.self, from: data))?.save
    }
    private static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
