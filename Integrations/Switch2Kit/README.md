# Experimental Switch 2 controllers in Delta

This opt-in build connects Delta directly to the pinned [Switch2Kit](https://github.com/jmonster/Switch2Kit) Swift engine. It follows the in-process ownership and explicit discovery approach used by the maintained Cemu and Dolphin integrations, but feeds DeltaCore's native controller registry rather than SDL. No dashboard, network bridge, virtual-controller driver, or system SDL replacement is needed.

**Status: implementation for review, not hardware-qualified iOS support.** The upstream SDK documents desktop support, not iOS acceptance. The native CI in this PR must establish that the engine and the complete Delta app build with the iOS SDK. A Simulator build cannot establish Bluetooth pairing or gameplay on an iPhone/iPad. Do not treat portable mapping tests as that evidence.

## Build on a Mac

Requirements: Xcode 26 / Swift 6.2 or newer, Python 3.9+, and Delta's normal source-build dependencies. The generated application targets **iOS/iPadOS 18 or later**, because the engine uses `Synchronization.Mutex`. The checked-in ordinary Delta project retains its existing deployment settings (the application currently specifies iOS 17.4; some dependencies specify iOS 14).

From this branch's repository root:

```sh
# Per-command HTTPS rewrite also covers Delta's existing SSH submodules.
# It does not change your global Git configuration.
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive

swift test --package-path Integrations/Switch2Kit
python3 -m unittest discover -s Integrations/Switch2Kit/tests -v
swift test --package-path Integrations/Switch2Kit/Engine
python3 Integrations/Switch2Kit/configure.py
open Delta-Switch2Kit.xcworkspace
```

Select the **Delta** scheme, your iPhone/iPad and your own signing team. Do not run `pod install` against the generated project: use Delta's normal workspace first for any ordinary dependency setup, then generate this workspace. Never replace signing identities with someone else's credentials. No signed IPA or release is provided by this change.

For a signing-free compile check:

```sh
xcodebuild -workspace Delta-Switch2Kit.xcworkspace -scheme Delta \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/switch2kit-app CODE_SIGNING_ALLOWED=NO build
```

### What configuration changes

`configure.py` creates ignored `Delta-Switch2Kit.xcodeproj`, `Delta-Switch2Kit.xcworkspace`, and `Integrations/Switch2Kit/Generated` directories. It links the Swift packages, adds the actual adapter/service/UI source files, enables `DELTA_SWITCH2KIT`, sets the generated app target's iOS floor to 18, and supplies a copied Info.plist with a Bluetooth usage description. The original project, workspace, Info.plist, Pods and other targets are not rewritten.

DeltaCore's public controller registry currently has no registration API. Configuration appends a small, exact-source-checked extension to its existing manager source, using the same array and notifications as native controllers. It does not fake Apple `GCController` events or alter existing native discovery. The dependency will appear dirty while that local overlay is installed; do not commit it as a new gitlink. To remove **only the unchanged generated extension**:

```sh
python3 Integrations/Switch2Kit/configure.py --restore-core
```

Changed dependency source or changed generated output is rejected rather than overwritten. Move your generated directories aside before regeneration after changing their configuration; preserve any edits first. Nothing resets your Git worktree. A future upstream DeltaCore registration API can replace this temporary overlay.

The engine wrapper compiles the **unmodified Swift source** at gitlink `6b5cba6233b21fca1020570e96b1bf247ba21f1e`. Its manifest declares the required iOS platform without changing the SDK repository or pulling in desktop apps/C/SDL targets. DeltaCore remains pinned to `633dfa86967816315fe19b482511dab1ce517f28`. Configuration verifies both revisions and rejects tracked SDK edits.

## Connect and play

Open **Settings → Controllers → Switch 2 Controllers**, choose **Find Switch 2 Controllers**, grant Bluetooth access, and hold the controller's Sync button. Quit any other app currently managing that controller first. Discovery runs for 60 seconds; existing ready controllers remain usable when that window ends. Pair inside Delta, not by forcing operating-system pairing.

Return to Controllers and choose a Player to assign or customize controls. New controllers use a free player slot when Delta's automatic assignment is enabled; a fifth physical device is not admitted. Existing native controllers are not removed or replaced. Assignments are remembered only for this service's lifetime, with bounded bookkeeping; a reconnect never steals an occupied native player slot. No controller UUIDs or serials are persisted by the adapter.

| Model | Mapping |
| --- | --- |
| Switch 2 Pro | Label-preserving A/B/X/Y, D-pad, both sticks, L/R/ZL/ZR; Plus = Start, Minus = Select, Home = Delta menu. |
| NSO GameCube | Face buttons, D-pad, both sticks and digital trigger clicks; Plus = Start, Capture = Select, Home = menu. Trigger clicks use Delta's trigger inputs; customize per-system shoulder/trigger bindings as needed. Analog travel is not silently converted to a click. |
| Joy-Con 2 left | One horizontal controller, stick on left. Rotated directional buttons become face buttons; SL/SR = shoulders, Minus = Start, Capture = menu, L/ZL = triggers. No default Select button. |
| Joy-Con 2 right | One horizontal controller, stick on left. Rotated face buttons and stick; SL/SR = shoulders, Plus = Start, Home = menu, C = Select, R/ZR = triggers. |

Sticks use a radial 15% dead zone with rescaled travel. Opposite-direction changes release the old input before activating the new one. The adapter uses Delta's existing MFi input vocabulary, default per-system mappings, and custom mapping storage; it does not replace saved mappings.

**Not implemented:** combining Joy-Con halves into one controller, motion/gyro, optical mouse, game rumble, analog trigger output, stick-click/GL/GR bindings, NFC or audio. This is Bluetooth support, not a USB backend. Controller/player LED commands are forwarded; physical LED behavior still needs testing.

**Disconnect All** stops the engine, cancels observation and releases both physical and sustained (Hold Buttons) inputs before unregistering controllers. Interruptions neutralize input. Backgrounding stops the engine; returning does not silently restart discovery. Choose Find again. Bluetooth permission denial, Bluetooth-off state and typed connection failures are shown in the screen.

## Validation and acceptance

Local evidence for this implementation: 16 executable Swift input/scene-policy tests and 10 Python configuration tests passed on Linux with Swift 6.2.1. These exercise production mapping/state code and project-generation logic, including both Joy-Con rotations, analog-stick bounds, neutralization, product/source wiring, preservation of the baseline project, Bluetooth plist generation, reversible overlay behavior and refusal to overwrite unexpected edits.

`switch2kit.yml` additionally defines native macOS bridge tests against the actual pinned SDK, an iOS Simulator SDK/bridge compile, and a full Delta Simulator application build. These are separate gates: parsing Swift files, testing a mock, or passing portable policy tests does not replace native compilation. No native build success is claimed in this document. Multi-window policy tests distinguish temporary permission alerts from the last foreground scene entering the background.

Before marking iOS controller support qualified, record tested commit, device/iOS version, controller model and firmware, then check:

- First-use permission grant/denial/retry, Sync pairing and first input readiness for each advertised model.
- All mapped controls, diagonal and centered sticks, independent GameCube analog travel versus clicks, Home/menu, and Customize Controls in at least NES/SNES/N64 gameplay.
- Multiple same-model controllers, coexistence with a native controller, reassignment while a button is held, reconnect in reversed order, and preservation of an intentionally unassigned controller.
- Link loss and Bluetooth toggles while inputs are held, background/foreground, explicit Stop followed by Find, bounded-event snapshot reconciliation, and no stuck Hold Buttons or stale reconnect input.

Until those native and physical checks are complete, keep this an opt-in experimental integration, not a claim that every model or firmware works on iOS.
