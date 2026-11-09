# On-device conversion architecture

## Non-negotiable requirement

Game conversion runs on the iPhone. GitHub Actions may compile and package the converter application and its native libraries, but it must never receive a user's NSP/XCI files or prod.keys and must never perform a user's game conversion.

The app's file picker remains the only source of game packages and keys. Imported files stay in the app's Documents/Imports directory. Prepared files stay in Documents/PreparedGame until conversion or cleanup.

## Current implementation baseline

- The Swift import screen copies selected files into app-owned storage and remembers selections.
- The LibHac NativeAOT framework is packaged in the app. Its metadata inspection and NSP/DLC extraction exports are called by the app using local file paths.
- The Capstone AArch64 framework is packaged in the app and performs local disassembly and analysis.
- The current NSO rewriter is also packaged in the app and runs locally. With an empty patch manifest, it decompresses/rebuilds NSO containers and verifies segment hashes. It does **not** yet apply the game-specific or general Switch-to-Apple compatibility rewrites needed to make a game runnable.
- A native Swift Metal compiler component is now included in the app. It accepts MSL text and asks the iPhone's Metal driver to compile it locally. The import screen includes a compute-shader smoke test. This validates the device-side MSL compilation endpoint; it is not yet the Switch shader translator.
- The current UI exposes extraction, NSO rewriting, and diagnostic controls. It is not yet the finished one-button converter.
- The universal-shell workflow builds a game-free app and its embedded native libraries. It is a development/distribution build only, not a game conversion service.
- The Ryujinx shader translator is now built as an iOS ARM64 NativeAOT framework, embedded and signed in the game-free IPA, and successfully loaded through its Swift bridge on an iPhone 14. This validates the native translator startup path, not real shader translation.

## Required on-device conversion stages

1. **Import and validate** — already implemented for prod.keys, base NSP, optional update, and DLC.
2. **Extract locally** — already implemented through the embedded LibHac NativeAOT framework.
3. **Rewrite executable modules locally** — current code only performs lossless NSO decompression/repacking and optional exact-match patches. Port/adapt the complete upstream rewrite rules and runtime compatibility transformations, then verify every output module.
4. **Extract and translate shaders locally** — the iPhone-side MSL compiler endpoint and smoke test are in place, and the Ryujinx translator loads on-device. A first metadata-only scanner now inventories the local RomFS index for Unity serialized files and StreamingAssets bundles. Still required: parse UnityFS and Unity 2017.4 serialized Shader objects, extract a real shader program, translate it to SPIR-V, convert SPIR-V to MSL with SPIRV-Cross, and compile the MSL locally.
   - Upstream's Cuphead profile is already a proven reference: it identifies Unity 2017.4.9f1 and reports 13,057 shaders, with all shader programs building for iOS. Its translator chain is Ryujinx's C# NVN-to-SPIR-V translator (`dmsh_xlate`) followed by SPIRV-Cross (SPIR-V-to-MSL). The practical port target is therefore the C# translator as an iOS NativeAOT library plus SPIRV-Cross as an iOS native library, with the existing Cuphead shader extraction rules adapted to run on-device. The NativeAOT build and on-device startup probe are complete; a real on-device shader translation test is still required. The final MSL compile stage is now provided by `OnDeviceMetalCompiler.swift`.
5. **Prepare game assets locally** — organize RomFS, DLC, icon, metadata, and generated shader libraries in the app's prepared-game layout.
6. **Package locally** — create the game-specific app payload from the prepared files and the installed NxNative runtime. The app must not need a cloud service to finish this step.
7. **Validate and launch** — check required files, architecture, bundle layout, and compatibility profile before offering the finished app for installation/launch.

## Build-versus-convert boundary

Allowed on GitHub Actions:
- Compile Swift, C/C++, and NativeAOT source into iOS-compatible app components.
- Run unit tests and static checks against synthetic fixtures.
- Assemble and sign the game-free converter app.

Not allowed on GitHub Actions:
- Receive, download, decrypt, extract, rewrite, or package the user's game files.
- Receive prod.keys or title keys.
- Produce a game-specific IPA from the user's selected content.

## Device constraints

The iPhone 14 uses an A15 GPU. Shader output must use a compatible fallback profile rather than assuming newer Apple GPU features. Conversion must be staged, cancellable, storage-aware, and avoid loading multi-gigabyte RomFS/DLC images wholly into memory. Temporary files and failed staging folders must be cleaned safely without deleting the user's imported originals.

## Acceptance criteria

A conversion milestone is not complete merely because a report or rewritten NSO is produced. The final acceptance test is that, with network access disabled after the app and its required components are installed, the iPhone can import locally stored content, perform every conversion stage, produce a valid game-specific app package, and launch the game through the bundled runtime.
