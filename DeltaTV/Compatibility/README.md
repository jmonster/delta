# DeltaTV compatibility

DeltaTV compiles the existing DeltaCore runtime, GBCDeltaCore bridge, and Gambatte emulator directly from pinned submodules. No mock emulator, dependency rewrite script, or unpublished gitlink is used.

## Pinned sources

- DeltaCore: `633dfa86967816315fe19b482511dab1ce517f28`
- GBCDeltaCore: `0871ccaad2bbd7cbd2de0ce06f9e26dc3d1bfdde`
- Gambatte: `f8a810b103c4549f66035dd2be4279c8f0d95e77`

[sources.json](sources.json) lists every source, public header, resource, and required build setting. [provenance.json](provenance.json) maps the seven adapted files to their original paths and SHA-256 hashes. Original copyright notices and the root/Gambatte `COPYING` files remain unchanged; this port grants no new redistribution rights.

## Target selection

The first slice supports GB/GBC bitmap video, audio, saves, and extended game controllers. It excludes touch skins, keyboard handling, ZIPFoundation, CocoaPods, and other emulator cores. Only uncompressed `.gb`/`.gbc` cartridges are accepted. No JIT is introduced.

Use `FRAMEWORK` for Swift resource lookup, C++14 with `HAVE_CSTDINT`, and the two mapping resources in the manifest. Compile Gambatte’s `file.cpp`, not the alternative `file_zip.cpp`.

## Adaptations

Five DeltaCore copies provide tvOS playback audio, public scene-focus checks, purgeable cache storage, skin-free rendering, and safe controller callbacks that preserve system Home behavior. The GBC bridge/header copies expose operation results, isolate cartridge save directories, atomically replace save files, and bound LCD-off frame callbacks. iOS targets retain their original sources.

## Verification limits

Initial Xcode 27 unsigned tvOS Simulator/device builds passed. A local Simulator harness using these built frameworks verified real GB/GBC ROM frame output, audio samples, input and save roundtrips. ROMs were not published. Physical Apple TV display/audio and paired-controller behavior remain unverified. tvOS caches remain purgeable; durable progress requires external backup.
