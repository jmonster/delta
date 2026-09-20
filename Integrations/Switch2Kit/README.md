# Experimental Switch 2 controllers in Delta

This opt-in build connects Delta directly to the pinned [Switch2Kit](https://github.com/jmonster/Switch2Kit) Swift engine. It follows the in-process ownership and explicit discovery approach used by the maintained Cemu and Dolphin integrations, but feeds DeltaCore's native controller registry rather than SDL. No dashboard, network bridge, virtual-controller driver, or system SDL replacement is needed.

**Status: experimental integration, not hardware-qualified iOS support.** The [native workflow](../../.github/workflows/switch2kit.yml) checks the real engine and complete Delta application against Apple's SDK. See the PR's current checks for the tested revision and results. A Simulator build does not establish Bluetooth pairing or gameplay on an iPhone/iPad; portable mapping tests do not establish that either.

## Build on a Mac

Requirements: Xcode 26 / Swift 6.2 or newer, Python 3.9+, and Delta's normal source-build dependencies. The generated application targets **iOS/iPadOS 18 or later**, because the engine uses `Synchronization.Mutex`. The ordinary checked-in project retains its existing deployment settings.

From this branch's repository root:

```sh
# Per-command HTTPS rewrite also covers Delta's existing SSH submodules.
# It does not change your global Git configuration.
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive

# Configuration also prepares the shared engine sources.
python3 Integrations/Switch2Kit/configure.py
swift test --package-path Integrations/Switch2Kit
python3 -m unittest discover -s Integrations/Switch2Kit/tests -v
swift test --package-path Integrations/Switch2Kit/Engine
open Delta-Switch2Kit.xcworkspace
```

Select the **Delta** scheme, your iPhone/iPad and your own signing team. Do not run `pod install` against the generated project: use Delta's normal workspace first for any ordinary dependency setup, then generate this workspace. No signed IPA or release is provided by this change.

For a signing-free compile check:

```sh
bash Integrations/Switch2Kit/build-app.sh simulator
bash Integrations/Switch2Kit/build-app.sh device
```

The application checks target ARM64: the pinned melonDS project includes ARM64 JIT assembly, so a universal Intel/ARM Simulator application build is not supported by that project. The standalone engine check still builds both Simulator architectures. Device compilation uses the actual iOS SDK without code signing; it does not create an installable release.

### Engine portability

`prepare_engine.py` copies the pinned SDK sources into ignored `Engine/Generated/Switch2Kit`. Its only source adaptation guards both the IOBluetooth import and the `IOBluetoothHostController` call. CoreBluetooth's presence does not imply IOBluetooth is available. The vendor checkout is not edited, and macOS bridge tests and iOS builds use the same staged source.

When IOBluetooth is unavailable, host-address lookup returns `nil`, preserving the engine's existing unknown-address path. This does **not** discover an iPhone's Bluetooth MAC address, write a fabricated address, or establish a protocol bond. Use explicit Find/Sync; automatic button-wake reconnection on iOS is not claimed. Physical connection and reconnect behavior require the acceptance checks below.

To test only the engine without configuring the Delta application:

```sh
python3 Integrations/Switch2Kit/prepare_engine.py
swift test --package-path Integrations/Switch2Kit/Engine
cd Integrations/Switch2Kit/Engine
xcodebuild -scheme DeltaSwitch2Bridge -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../../build/switch2kit-engine CODE_SIGNING_ALLOWED=NO build
```

The wrapper declares the required iOS deployment floor without including the SDK's C ABI, desktop app, or SDL targets. The SDK and DeltaCore submodule revisions are unchanged by this integration repair. Configuration verifies the existing pins and rejects unexpected dependency edits. Source-staging tests check preservation of unrelated source, idempotence, missing/changed inputs, changed output, and symlink rejection; they supplement, not replace, native builds.

### What application configuration changes

`configure.py` creates ignored `Delta-Switch2Kit.xcodeproj`, `Delta-Switch2Kit.xcworkspace`, and `Integrations/Switch2Kit/Generated` directories. It links the Swift packages, includes the adapter/service/UI sources, enables `DELTA_SWITCH2KIT`, raises only the generated application target's iOS floor to 18, and supplies a copied Info.plist with a Bluetooth usage description. The original project, workspace, Info.plist, Pods and other targets are not rewritten.

DeltaCore's public controller registry currently has no registration API. Configuration appends a small, exact-source-checked extension to its existing manager source, using the same array and notifications as native controllers. It does not fake Apple `GCController` events or alter native discovery. That dependency appears dirty while the local overlay is installed; do not commit it as a new gitlink. To remove **only the unchanged generated extension**:

```sh
python3 Integrations/Switch2Kit/configure.py --restore-core
```

Changed dependency source or changed generated output is rejected rather than overwritten. Move generated directories aside before regeneration after changing their configuration, preserving any edits first. Nothing resets the Git worktree. A future upstream DeltaCore registration API can replace this temporary overlay.

## Connect and play

Open **Settings → Controllers → Switch 2 Controllers**, choose **Find Switch 2 Controllers**, grant Bluetooth access, and hold the controller's Sync button. Quit any other app currently managing that controller first. Discovery runs for 60 seconds; existing ready controllers remain usable when that window ends. Connect inside Delta rather than forcing operating-system pairing.

Return to Controllers and choose a Player to assign or customize controls. New controllers use a free player slot when Delta's automatic assignment is enabled; a fifth physical device is not admitted. Existing native controllers are not removed or replaced. Assignments are remembered only for this service's lifetime, with bounded bookkeeping; a reconnect never steals an occupied native player slot. No controller UUIDs or serials are persisted by the adapter.

| Model | Mapping |
| --- | --- |
| Switch 2 Pro | Label-preserving A/B/X/Y, D-pad, both sticks, L/R/ZL/ZR; Plus = Start, Minus = Select, Home = Delta menu. |
| NSO GameCube | Face buttons, D-pad, both sticks and digital trigger clicks; Plus = Start, Capture = Select, Home = menu. Customize per-system shoulder/trigger bindings as needed. Analog travel is not silently converted to a click. |
| Joy-Con 2 left | One horizontal controller, stick on left. Rotated directional buttons become face buttons; SL/SR = shoulders, Minus = Start, Capture = menu, L/ZL = triggers. No default Select button. |
| Joy-Con 2 right | One horizontal controller, stick on left. Rotated face buttons and stick; SL/SR = shoulders, Plus = Start, Home = menu, C = Select, R/ZR = triggers. |

Sticks use a radial 15% dead zone with rescaled travel. Opposite-direction changes release the old input before activating the new one. The adapter uses Delta's existing MFi input vocabulary, default per-system mappings, and custom mapping storage; it does not replace saved mappings.

**Not implemented:** combining Joy-Con halves into one controller, motion/gyro, optical mouse, game rumble, analog trigger output, stick-click/GL/GR bindings, NFC or audio. This is Bluetooth support, not a USB backend. Controller/player LED commands are forwarded; physical LED behavior still needs testing.

**Disconnect All** stops the engine, cancels observation and releases both physical and sustained (Hold Buttons) inputs before unregistering controllers. Interruptions neutralize input. Backgrounding stops the engine; returning does not silently restart discovery. Choose Find again. Bluetooth permission denial, Bluetooth-off state and typed connection failures are shown in the screen.

## Validation and physical acceptance

CI runs the portable input/scene tests and configuration/staging regressions, native macOS bridge tests against the real SDK, the iOS Simulator engine compile, and complete ARM64 Delta Simulator and iOS device application builds. It also verifies reversible DeltaCore registration and an unchanged SDK vendor checkout. Application build failures preserve a complete diagnostic log; no failing compiler command is converted into a success. Multi-window policy tests distinguish temporary permission alerts from the last foreground scene entering the background.

Before describing iOS controller support as hardware-qualified, record tested revision, device/iOS version, controller model and firmware, then check:

- First-use permission grant/denial/retry, Sync connection and first input readiness for each advertised model; reconnect behavior without a host-address bond.
- All mapped controls, diagonal and centered sticks, independent GameCube analog travel versus clicks, Home/menu, and Customize Controls in NES/SNES/N64 gameplay.
- Multiple same-model controllers, coexistence with a native controller, reassignment while a button is held, reconnect in reversed order, and preservation of an intentionally unassigned controller.
- Link loss and Bluetooth toggles while inputs are held, background/foreground, explicit Stop followed by Find, bounded-event snapshot reconciliation, and no stuck Hold Buttons or stale reconnect input.

This remains opt-in experimental support until physical qualification is complete; successful compilation alone is not a claim that every model or firmware works on iOS.
