# On-device Switch shader translator port

## What the source inspection established

The upstream translator is not just a small conversion routine. Its `Program.cs` contains:

1. **Translation core** — `SwshXlate.Accessor` implements Ryujinx's `IGpuAccessor`, supplies hardware/resource answers, creates a Ryujinx translation context, and produces SPIR-V plus resource metadata.
2. **Command-line shell** — `Main(string[] args)` reads JSON jobs and shader-code files, writes `.spv` and `.res.json` files, and reports per-shader failures.

The iPhone app needs the translation core behind a native-callable interface, not a desktop process.

## Probe now added to this repository

- `translator-probe/SwshXlate.cs` contains the upstream translator entrypoint, with its main method made callable by the native wrapper.
- `translator-probe/NxNativeShaderTranslator.csproj` targets `.NET 10 iOS`, NativeAOT, and iPhone ARM64. It references the Ryujinx shader and common projects in the checked-out shell source.
- `translator-probe/NativeExports.cs` exposes a C ABI function named `nxn_translate_shader_jobs`. Its file paths are intended to point only into the app's own sandbox.
- `.github/workflows/build-universal-shell.yml` now installs the .NET 10 iOS workload, attempts to publish this translator as an iOS ARM64 NativeAOT library, checks the exported symbols, and uploads the build log/library as the `nxnative-shader-translator-ios-probe` artifact.

The probe is now built as an iOS ARM64 NativeAOT framework, embedded and signed in the shell IPA, and successfully loaded by the app on an iPhone 14. The app's Swift bridge resolves both exported functions and the native initialization probe returns success. This proves the translator library can run on the device; it does not yet prove that a real Switch shader has been translated.

## Important build-version finding

The upstream `dmsh_xlate.csproj` targets **.NET 10.0** and references:

- `Ryujinx.Graphics.Shader`
- `Ryujinx.Common`

The existing LibHac metadata probe uses .NET 9. It does not establish that Ryujinx can be compiled for iOS. The new probe uses .NET 10 and the iOS workload.

The Ryujinx shader project also references `Spv.Generator`; `Ryujinx.Common` brings NuGet dependencies including RecyclableMemoryStream, MsgPack.Cli, Humanizer, and Gommon. Their iOS NativeAOT compatibility is one of the things this test is intended to discover.

## What this test does and does not prove

A successful publish, IPA inspection, and on-device probe now prove that the upstream translator code and its dependency graph can be linked into an iOS ARM64 NativeAOT library, embedded in the app, and loaded through its callable native entry point. It still does **not** prove that a real Cuphead shader translates correctly.

The next validation after a successful build is to call the exported function on-device with a tiny known shader fixture, then compare its SPIR-V/resource output with the upstream desktop translator. Only after that should we connect Cuphead's extracted shader jobs.


## Cuphead source discovery: first on-device pass

Upstream's Cuphead profile (title ID 0100A5C00D162000) identifies Unity 2017.4.9f1 IL2CPP. Its 3,118 shader programs were extracted from the player's serialized Unity files under Data and the AssetBundles under StreamingAssets; the upstream parser handles UnityFS bundles, serialized files, Shader class 48 type trees, and the pre-2019.3 single-stage program layout. Four additional GLSLC outputs are present in main.

The IPA overlay now includes UnityShaderSourceScanner.swift and a Scan Unity Shader Sources control. It reads the DMROMFS1 index of the locally extracted RomFS.img, inventories files under Data and StreamingAssets, and checks likely bundle/data files for the UnityFS signature by reading only their first eight bytes. It does not expand the multi-gigabyte RomFS, rewrite game files, or send content off-device. The report is saved as Documents/PreparedGame/shader-source-scan.txt.

This is intentionally an inventory pass, not the shader extractor. The next implementation stage is a bounded UnityFS reader and Unity 2017.4 serialized-file/Shader-object parser, followed by extraction of one program's stage code and required metadata into a local translator job.

## Remaining conversion stages

1. Port Cuphead's Unity 2017.4 shader discovery/splitting logic to run locally.
2. Verify actual shader translation on-device using the new C ABI bridge.
3. Build SPIRV-Cross as an iOS native library to convert SPIR-V to MSL.
4. Feed MSL into the existing Swift Metal compiler endpoint.
5. Port the executable compatibility rewrites and complete local packaging/launch.

Cuphead's upstream profile remains a useful reference (Unity 2017.4.9f1; 13,057 shaders), but that profile does not mean this app can currently translate those shaders.

## Non-negotiable boundary

GitHub Actions may compile generic app components and libraries. It must never receive the user's NSP/XCI files or prod.keys, or perform a user's game conversion. The translator's runtime inputs must be files already imported into the app's own iPhone sandbox.

## Cuphead shader-object scan results — 2026-11-14

The expanded on-device scan was run against 543 indexed files. It classified 256 serialized-file candidates and 287 bundle candidates, identified 286 UnityFS bundles, and directly inspected 82 SerializedFiles totaling 249,390,016 bytes.

Across those serialized files, the scanner found and wrote 65 complete Unity Shader class objects (5,786,672 bytes total). The per-file extraction batches completed without a reported short extraction. These are raw serialized Shader objects, not yet decoded shader programs.

The forensic byte-signature pass found no SPIR-V, DXBC, MTLB, DXIL, or SHDR signatures in the 65 object payloads. This is expected to be inconclusive: Unity 2017.4 stores compiled programs inside the Shader object's compressedBlob, with platform/offset/compressed-length/decompressed-length tables. The current scanner inventories object bytes and printable strings but does not yet parse those fields or decompress the program records.

### Next implementation step

Replace signature hunting as the primary extraction method with a Unity 2017.4.9f1 Shader object parser. It must walk the serialized m_ParsedForm structure safely, read the platform and offset/length arrays, extract each bounded slice from compressedBlob, and LZ4-decompress it using the recorded decompressed length. Then parse the decompressed ShaderProgram / SerializedProgram records and emit per-stage program code plus the metadata needed to map each program back to its pass and variant.

Do not treat a successful LZ4 decode alone as proof of a usable shader. Validate record boundaries, program types, stage counts, and extracted code sizes, then feed one real extracted program into the already-built on-device translator probe. Keep all game data and conversion inputs on the iPhone; GitHub Actions remains build-only.

### Additional B-report triage: large serialized Shader candidate

A deeper pass over the same B report identified one standout object in Data/resources.assets: Shader object index 142 is 5,064,092 bytes (about 4.83 MiB). Its printable strings identify it as `Hidden/Post FX/Uber Shader`, with properties/keywords including `_AutoExposure`, `_BloomTex`, `_Bloom_DirtTex`, `_GrainTex`, `_LogLut`, `_UserLut`, `_Vignette_Mask`, `_ChromaticAberration_Spectrum`, and `_DitheringTex`. This makes it the highest-value first target for parsing `m_ParsedForm` and locating the compressed program blob; it is not yet proof that its entire 5 MB payload is executable code.

Across all 65 extracted Shader objects, the current marker inventory reports 75 `Vertex` string hits and 2 `Pass` hits, appearing in 18 objects. These are structural/string clues only: the scan still reports zero hits for the five tested raw binary signatures. Prioritize object 142 for layout discovery, then compare its parsed offsets/lengths and decompressed records against a smaller known Shader object (for example object 143, 46,656 bytes) to validate the parser before scaling to all assets.

## B-report recheck — 2026-11-14 (repeat scan)

The latest `B` artifact was fetched again and remains revision `prioritize-all-serialized-shader-objects-v7` (5,799 lines; 717,165 characters). Its top-level inventory is unchanged: 543 indexed files, 256 serialized candidates, 287 bundle candidates, 286 UnityFS bundles, and 82 directly inspected SerializedFiles totaling 249,390,016 bytes. The report still identifies the same 65 extracted Shader objects and the same `Data/resources.assets` object 142 (5,064,092 bytes) / object 143 (46,656 bytes) candidates. No new shader-program extraction, compressed-blob layout, or decompression evidence appears in this report revision.

This recheck is recorded to establish that the current B artifact has not advanced beyond the v7 raw-object inventory. Do not repeat the byte-signature scan as the next milestone. The next useful report should come from implementing and exercising the Unity 2017.4.9f1 Shader serialized-layout parser on object 142, then cross-checking its bounded program records against object 143. A valid milestone requires parsed platform/offset/compressed-size/decompressed-size fields, successful bounded decompression, and identifiable program/stage records—not just printable strings or an LZ4 success flag.
