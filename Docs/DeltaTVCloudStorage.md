# Delta TV cloud storage

## Scope and guarantees

The tvOS target imports user-provided GB/GBC, NES, SNES, GBA, N64, DS and Genesis cartridges into a separate CloudKit library. It does not read existing iOS Harmony Google Drive/Dropbox data or migrate iOS saves. Identical ROM imports currently create separate UUID entries.

The user's private database stores ROM/library metadata, compatible emulator states, and battery RAM plus optional RTC in one versioned asset. Only server-acknowledged revisions count as backed up. Pending changes coalesce within fixed limits; divergent progress requires an explicit choice. Account changes stop synchronization rather than uploading the previous account's library into another account.

Every local file, including the journal and pending/conflict snapshots, is purgeable on tvOS. Unsynced progress can be lost. Recovery reconstructs the library from cloud metadata and assets. A running game's files are protected from remote replacement. CKSyncEngine sends are foreground-only; automatic/background durability is not promised.

## Owner provisioning

Default unsigned builds leave `DeltaTVCloudContainerIdentifier` empty, construct no CloudKit container, and clearly show local-only storage.

To enable iCloud, the owner must:

1. Select their Apple Developer team and provision the app identifier and signing profile
2. Create/select an owner-controlled iCloud container; enable CloudKit and the remote-notification capability required by CKSyncEngine
3. Set `DeltaTVCloudContainerIdentifier` in the target's configuration to that exact entitled container identifier
4. Deploy the production schema for record type `DeltaTVAsset`, with fields `metadata` (Bytes) and `asset` (Asset). The app creates its private `DeltaTVLibrary-v1` zone; no query indexes are required
5. Build a signed app and test with the intended iCloud account on a physical Apple TV

These source changes do not create containers, change Apple accounts, grant access, or generate credentials. CloudKit provisioning and production schema deployment remain owner actions.

## Verification and release gates

Run portable storage tests from the repository root:

```sh
DeltaTVTests/run-storage-tests.sh
# If swiftc is not on PATH:
SWIFTC=/absolute/path/to/swiftc DeltaTVTests/run-storage-tests.sh
```

The 38 scenarios pass with Swift 6, complete concurrency checking, and warnings as errors. They use a fake transport, so they do not prove CloudKit runtime behavior.

The expanded native project passed local Xcode 27 unsigned Simulator/device builds. Real-ROM automation passed for GB/GBC, NES, SNES, GBA, N64 and DS, including native save restoration; Genesis cartridge execution remains unverified. The additional systems use the same opaque battery/state transport and pass fake-transport backup/restore tests.

A signed physical Apple TV build verified one GB/GBC RTC cartridge’s private CloudKit backup acknowledgment and byte-identical ROM, battery RAM/RTC, and save-state recovery in Development. A private harness restored into a new empty library and checked pre-cancelled synchronization and retry; a normal app relaunch then recovered the same files through the production coordinator with no pending revisions.

A subsequent bounded Development test used a separate validation zone with the same transport and store. GBA (8 KiB EEPROM), N64 (versioned cartridge/memory-pack checkpoint) and DS (8 KiB save) each uploaded a ROM, battery checkpoint and save state: nine records were acknowledged, then restored byte for byte into an initially empty library. Source libraries and recoverable backups were retained; the production zone and existing library were preserved. The recovered DS cartridge booted and loaded its restored state on physical tvOS without external firmware, using the pinned core's bundled replacement BIOS and DS direct boot. Optional external firmware and DSi NAND recovery are not implemented.

Live CloudKit validation for NES/SNES/Genesis, Production deployment, physical-controller gameplay, audible listening, actual OS-managed cache purge, reinstall/process-kill recovery, concurrent-device conflicts, quota/throttle, in-flight cancellation and account-change tests remain release gates.

Before launch, the app reconciles inactive battery/RTC files from the current journaled checkpoint, preserving pending progress. Tests cover interrupted publication, mixed native files, missing components, cancellation and newer revisions. A crash before a new checkpoint can still lose recent play; this does not make native-core writes transactional or prove live iCloud durability.

## Official guidance

- [tvOS storage and eviction](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/iCloudStorage.html)
- [CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- [Swift 6 data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)
