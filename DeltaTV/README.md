# Delta for Apple TV

A development port using Delta’s pinned native cores for **GB/GBC, NES, SNES, GBA, N64, DS and Genesis / Mega Drive**. It includes a controller-first library, audio/video, in-game saves, one manual save-state slot and optional private iCloud recovery. Existing iOS targets retain their original sources.

Genesis is linked and builds, but cartridge execution has not yet been verified: no suitable owned Genesis cartridge was found in the authorized local test collection. N64 performance remains experimental. Linking a core does not establish compatibility with every game or peripheral.

## Build and run

The app targets **tvOS 18 or later, arm64**. Xcode 27 was used for validation. Initialize the selected submodules and their native engine dependencies:

```sh
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init \
  Cores/DeltaCore Cores/GBCDeltaCore Cores/NESDeltaCore Cores/SNESDeltaCore \
  Cores/GBADeltaCore Cores/N64DeltaCore Cores/MelonDSDeltaCore Cores/GPGXDeltaCore Cores/Switch2Kit
for core in GBC SNES GBA N64 MelonDS GPGX; do
  git -C "Cores/${core}DeltaCore" -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
done
xcodebuild -project DeltaTV/DeltaTV.xcodeproj -scheme DeltaTV \
  -sdk appletvsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The pinned N64 libpng dependency uses a SourceForge Git URL; if that transport is unavailable, use an HTTPS mirror containing the exact pinned commit. Git LFS may be needed for optional upstream assets; the tvOS target does not include controller skins. No CocoaPods installation or rewriting of submodule source is required. Open `DeltaTV/DeltaTV.xcodeproj` and select `DeltaTV` to run from Xcode. See [source pins and adaptations](Compatibility/README.md).

## Cartridges and controls

Import a direct HTTPS link for a game you own. The app accepts these uncompressed formats:

| System | Extensions | Import cap | Runtime qualification |
| --- | --- | --- | --- |
| GB / GBC | `.gb`, `.gbc` | 16 MiB | Real cartridges, including RTC saves |
| NES | `.nes` (iNES / NES 2) | 16 MiB | Real cartridge |
| SNES | `.sfc`, `.smc` | 16 MiB | Real cartridge; another tested title stalled |
| GBA | `.gba` | 32 MiB | Real cartridge; 8 KiB EEPROM preserved |
| N64 | `.z64`, `.v64`, `.n64` | 64 MiB | Real cartridge, cached interpreter; simulator performance limited |
| DS | `.nds` | 512 MiB | Real DS cartridge and mapped stylus |
| Genesis / Mega Drive | `.gen`, `.md`, `.bin` | 16 MiB | Build and invalid-firmware rejection only |

Archives, interleaved SMD, Sega CD, Pico and DSi-only firmware boot are not supported. DS uses the pinned core’s replacement BIOS and direct boot; microphone, Wi-Fi, DSi NAND and JIT are disabled. No user ROMs or firmware are included. Keep private testing inputs and saves out of commits, CI, shared artifacts and app bundles.

Pair supported standard controllers in Apple TV Settings. The native provider accepts sparse NES/SNES profiles as well as extended pads; the Siri Remote browses the library. Start remains a game input. Click the left stick to pause, or use Start + Select. Official NES controllers use their top shoulder buttons; SNES controllers use ZL/ZR. Native Home belongs to tvOS.

The Controllers screen offers player assignment and explicit **Find / Disconnect Switch 2 Controllers**, using the same pinned Switch2Kit and Delta adapter as iOS. For the official Switch 2 GameCube controller, choose Find and hold Sync. Direct Bluetooth is capped at two controllers and stops in background; reconnecting may require Find and Sync again. Raw Home opens the app menu. Trigger clicks are mapped separately from travel; rumble, motion, mouse and combined Joy-Con pairs are not exposed. **No physical Nintendo controller or tvOS Bluetooth handshake was verified.** Upstream Switch2Kit declares iOS/macOS support; its native tvOS target compiles here, which does not establish official platform or hardware support.

DS shows both screens. Move the stylus with the right stick and touch with R2, or select D-Pad Stylus from Pause: D-Pad moves, A touches, B returns to game controls. Pause, stop and disconnection release touch and held inputs. Core player limits are one for GB/GBC/GBA/DS, two for NES/SNES/Genesis and four for N64.

## Saving and validation

Default unsigned builds are **local-only**. tvOS caches are purgeable, and a local save is not a completed cloud backup. In-game saves and states are separate. Failed local saves keep the game paused for retry. Native N64 battery data bundles cartridge storage and four memory packs in a versioned checkpoint; save-state compatibility includes the core revision and tvOS bridge version.

Enabling iCloud requires separately configured, authorized signing and a CloudKit container. Battery RAM and optional RTC share one checkpoint. Conflicts require an explicit choice. This library does not automatically import iOS Delta Sync data. See [cloud setup and verification boundaries](../Docs/DeltaTVCloudStorage.md).

```sh
bash DeltaTVTests/run-storage-tests.sh
# Actual owned cartridge inputs are opt-in; no cartridge is synthesized.
LOCAL_IMPORT_ROM=/private/path/game.gb bash DeltaTVTests/run-import-tests.sh
LOCAL_IMPORT_ROM_DIRECTORY=/private/path/cartridge-inputs bash DeltaTVTests/run-real-import-tests.sh
# Reusable controller XCTest target; select your own tvOS simulator.
xcodebuild -project DeltaTV/DeltaTV.xcodeproj -scheme DeltaTVControllerTests \
  -destination 'platform=tvOS Simulator,id=YOUR_SIMULATOR_ID' CODE_SIGNING_ALLOWED=NO test
```

Xcode 27 unsigned simulator and device builds pass. Thirty-eight strict Swift 6 storage scenarios pass. Actual-ROM automation verified NES/SNES/GBA/N64/DS video, non-silent audio processing, mapped input, state reload and fresh battery restoration; GB/GBC/RTC were also verified. Thirty-two controller assertions ran in a task-owned simulator with a fake radio and production registry, service and adapters; the reusable XCTest bundle builds. DS contact, bounds and release passed through the production stylus mapping. N64 measured about 16 FPS in this Debug simulator configuration; physical performance is unmeasured. These are per-cartridge results, not full compatibility or audible-listening claims.

The expanded app was signed with existing Development assets, installed and launched on an already configured physical Apple TV. Its existing journal retained three acknowledged GB/GBC test records with no pending revisions. This verifies app startup and cache preservation; it does not establish expanded-core physical gameplay.

Signed physical Apple TV backup acknowledgment and byte-identical recovery previously passed for one GB/GBC RTC cartridge in a private CloudKit **Development** container, including a normal coordinator relaunch. The expanded systems’ assets pass the fake-transport storage tests; live CloudKit backup for each expanded system remains unverified. See [acceptance gates](UI/VALIDATION.md).
