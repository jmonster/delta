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

## ROM files and controls

Import a direct HTTPS link for a game you own. The app accepts these uncompressed formats:

| System | Extensions | Import cap | Runtime qualification |
| --- | --- | --- | --- |
| GB / GBC | `.gb`, `.gbc` | 16 MiB | Real ROM files, including RTC saves |
| NES | `.nes` (iNES / NES 2) | 16 MiB | Real ROM file |
| SNES | `.sfc`, `.smc` | 16 MiB | Real ROM file; another tested title stalled |
| GBA | `.gba` | 32 MiB | Real ROM file; 8 KiB EEPROM preserved |
| N64 | `.z64`, `.v64`, `.n64` | 64 MiB | Real ROM file; bounded physical run at nominal VI speed with cached interpreter |
| DS | `.nds` | 512 MiB | Real DS ROM file and mapped stylus |
| Genesis / Mega Drive | `.gen`, `.md`, `.bin` | 16 MiB | Build and invalid-firmware rejection only |

Archives, interleaved SMD, Sega CD, Pico and DSi-only firmware boot are not supported. DS uses the pinned core’s replacement BIOS and direct boot; microphone, Wi-Fi, DSi NAND and JIT are disabled. No user ROMs or firmware are included. Keep private testing inputs and saves out of commits, CI, shared artifacts and app bundles.

Pair supported standard controllers in Apple TV Settings. The native provider accepts sparse NES/SNES profiles as well as extended pads; the Siri Remote browses the library. Start remains a game input. Click the left stick to pause, or use Start + Select. Official NES controllers use their top shoulder buttons; SNES controllers use ZL/ZR. Native Home belongs to tvOS.

The Controllers screen offers player assignment and explicit **Find / Disconnect Switch 2 Controllers**, using the same pinned Switch2Kit and Delta adapter as iOS. For the official Switch 2 GameCube controller, open **Controllers**, select **Find Switch 2 Controllers**, then hold the controller’s Sync button. Direct Bluetooth is capped at two controllers and stops in background; reconnecting may require Find and Sync again. Raw Home opens the app menu. Trigger clicks are mapped separately from travel; rumble, motion, mouse and combined Joy-Con pairs are not exposed. **No physical Nintendo controller or tvOS Bluetooth handshake was verified.** Upstream Switch2Kit declares iOS/macOS support; its native tvOS target compiles here, which does not establish official platform or hardware support.

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

Xcode 27 unsigned simulator and device builds pass. Thirty-eight strict Swift 6 storage scenarios pass. Actual-ROM automation verified NES/SNES/GBA/N64/DS video, non-silent audio processing, mapped input, state reload and fresh battery restoration; GB/GBC/RTC were also verified. Thirty-four controller scenarios ran in a task-owned simulator with a fake radio and production registry, service and adapters; the reusable XCTest bundle builds. DS contact, bounds and release passed through the production stylus mapping. Save integrity checks also passed with actual NES/SNES/GBA/DS ROM files: failed writes preserved prior save/state bytes, truncated battery files blocked startup, and current states reloaded. A batteryless SNES ROM file saved successfully without creating SRAM. Native DS I/O fault tests cover short reads/writes, missing sections and close failures. These results apply to the tested ROM files; arbitrary state-field corruption and full-system compatibility remain outside this qualification.

The expanded app was signed with existing Development assets, installed and launched on an already configured physical Apple TV. Its existing journal retained three acknowledged GB/GBC test records with no pending revisions. A bounded N64 cartridge run on a third-generation Apple TV 4K with tvOS 26.6 measured 60.02 virtual interrupts/second (about 100% emulation speed) and 59.79 successful OpenGL presentations/second over 30.1 seconds. Median frame spacing was 16.65 ms, with a 95th percentile of 18.26 ms. Display refresh was counted separately. The Debug simulator measured roughly 14–16 VI/second; that result does not describe physical-device speed. These measurements cover one cartridge's automated boot/menu workload, not every title or gameplay stress case. No native controller was connected during the read-only hardware snapshot; Nintendo hardware gameplay remains unverified.

A second bounded physical run instrumented the exact pinned plugin callbacks and measured thread CPU between native VI callbacks. It sustained 60.07 VI/second and 60.00 OpenGL presentations/second, using about 6.50 ms of native thread CPU per VI. RSP callbacks consumed 8.29 of 11.74 seconds of measured native thread CPU, while graphics callbacks consumed 0.20 seconds. RSP timing includes any nested graphics work, so these counters must not be added. Remaining CPU includes the cached core, device/audio callbacks and instrumentation; it is not a pure interpreter sample. Instruments could not attach despite developer-tool process liveness, so no sampled call-tree attribution is claimed. The full-speed result did not warrant an architecture change.

Signed physical Apple TV backup acknowledgment and byte-identical recovery passed for one GB/GBC RTC cartridge in a private CloudKit **Development** container, including a normal coordinator relaunch. A subsequent isolated Development test acknowledged and restored nine ROM/save/state records across GBA, N64 and DS into an empty library, preserving the existing production library and recoverable backups. The recovered DS game booted and loaded its state using the bundled replacement BIOS without external firmware. NES/SNES/Genesis live cloud recovery remains unverified. See [acceptance gates](UI/VALIDATION.md).
