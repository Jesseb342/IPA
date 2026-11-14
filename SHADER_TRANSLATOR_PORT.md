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


## Shader translator build verification — workflow runs 94 and 95 (2026-11-14)

The two supplied Actions runs were inspected from their job logs and uploaded artifacts:

- Run 94: [43605868160](https://github.com/Jesseb342/IPA/actions/runs/43605868160), source revision `1a11645e6af8e160ce511f2760fb5e6d571d48c9`.
- Run 95: [43609906545](https://github.com/Jesseb342/IPA/actions/runs/43609906545), source revision `d5f90c4581007f9e99da0882d06f76871acdc7f3`.

Both jobs completed successfully. The .NET 10 iOS NativeAOT publish produced an ARM64 `NxNativeShaderTranslator` binary (3,727,832 bytes) and packaged it as `NxNativeShaderTranslator.framework`. The workflow checked for both exported C ABI symbols (`nxn_translate_shader_jobs` and `nxn_shader_translator_probe`), verified that the framework was embedded in the app, and passed app code-signature verification. Each run also produced a roughly 24.2 MiB shell IPA artifact and uploaded the translator build diagnostics.

The two runs are not two independent code milestones: comparing their source revisions shows only `SHADER_TRANSLATOR_PORT.md` changed between them; the app/translator source was unchanged. Their translator publish logs show the same build result, with only restore timings differing.

### AOT warning to resolve

Both publish logs contain 16 analyzer warnings: eight IL2026 trimming warnings and eight IL3050 dynamic-code/AOT warnings. They point to generic `System.Text.Json.Nodes.JsonArray.Add<T>` calls in `SwshXlate.cs` around lines 237–241. NativeAOT publish still succeeded, but these warnings identify a real risk that JSON job construction/serialization could rely on members or runtime code removed by trimming. Before treating the translator as production-ready, replace those paths with an AOT-safe serialization approach (for example, explicit primitive JSON nodes or source-generated serialization metadata), then verify the serialized job payload on-device.

### What runs 94/95 prove—and what they do not

These runs prove that the translator can be compiled into an iOS ARM64 NativeAOT framework, its expected exports are present, and the framework can be embedded and signed as part of the generic shell. The workflow's checks are static build/package checks; neither run invokes the exported translator against a shader fixture or a Cuphead shader, and neither run demonstrates generated SPIR-V, resource metadata, MSL, or successful Metal compilation. The source-validation step explicitly says that game files are not accessed by Actions and that extraction/translation must execute in the app sandbox.

The next meaningful translator milestone is a small deterministic on-device fixture test: call `nxn_shader_translator_probe`, then call `nxn_translate_shader_jobs` with a known valid shader job, and compare the resulting SPIR-V and resource metadata with the desktop Ryujinx translator. Only after that passes should a parsed Cuphead Shader object's program records be connected to the bridge.


## NativeAOT JSON warning remediation attempt — 2026-11-14

Commit [e6a1c687](https://github.com/Jesseb342/IPA/commit/e6a1c6876e6ce8e9c0161323cdd387d750f0049d) changes the four resource-array insertion sites in `SwshXlate.cs` to pass values as explicit `JsonNode` instances. This is intended to force overload resolution to `JsonArray.Add(JsonNode?)` rather than the generic `Add<T>` path that generated IL2026/IL3050 warnings in runs 94/95.

**Status: source change committed, not yet build-verified.** The workflow is `workflow_dispatch` only, so this commit does not automatically start a build. The next run must inspect the NativeAOT publish log and confirm those warnings are gone (or identify any remaining call sites) before the remediation is considered complete. Do not claim the translator is AOT-clean until that run passes.

After the clean publish, upgrade the current Swift button test from an initialization-only call to an actual translation fixture. The fixture must be a known-valid Maxwell shader binary and job metadata; success criteria are exit code 0, a nonempty `.spv`, a parseable `.res.json`, SPIR-V magic `0x07230203`, and a comparison against desktop Ryujinx output. An empty job list or the current probe function is not a shader translation test.

## B report check after latest repo update — 2026-11-14

The repository's latest `Update B` commit is [70d3b8c6](https://github.com/Jesseb342/IPA/commit/70d3b8c616eb4c8cfc687d783b1b4bc71aa6364a). I compared the checked-in `B` file at this commit with the copy at the prior translator-log commit `f4c2067`: both resolve to the same blob SHA (`9b43722289a00e0eb64dc9a0d27fef3a46151196`). The latest commit therefore did not change the diagnostic report content.

The current report remains 5,799 lines / 717,165 characters, with 65 extracted Shader objects totaling 5,786,672 bytes. Its tested raw signatures remain zero for SPIR-V, DXBC, MTLB, DXIL, and SHDR. It still contains no parsed `compressedBlob` records, platform/offset/length tables, decompressed ShaderProgram records, or stage-code extraction. The large `Data/resources.assets` object 142 remains a useful parser target, but the report itself has not advanced the extraction milestone.

**Interpretation:** this latest B upload is a repository update, not a new scan result. Do not restart signature hunting or mark shader extraction complete. The next useful B report should come from the Unity 2017.4.9f1 serialized Shader parser and show validated bounded program records and stage payloads. Separately, the NativeAOT JSON remediation in `e6a1c687` still needs a manually dispatched build before it can be called verified.


## Unity 2017 Shader blob-table probe — 2026-11-14

The on-device scanner now has a first bounded extraction pass after raw Shader-object extraction. It searches each Shader object for the Unity 5.5–2019 serialized tail sequence used by Unity 2017.4:

1. `platforms[]`
2. `offsets[]`
3. `compressedLengths[]`
4. `decompressedLengths[]`
5. `compressedBlob[]`

A candidate is considered only when the platform count is bounded, platform enum values are plausible, all four array counts agree, every offset/length pair fits inside the declared blob, and the declared blob fits inside the object. The scanner then attempts raw-LZ4 decompression for each bounded chunk. A decoded chunk is written locally only when its output size matches the declared decompressed length and its leading SerializedProgram subprogram count is plausible. The report records the platform, offset, compressed/decompressed sizes, subprogram count, and local output filename.

This is deliberately a structural probe rather than a complete Unity Shader parser. It does not yet decode the full `m_ParsedForm` hierarchy, map each subprogram to a vertex/fragment pass, or validate the internal code payload format. A plausible table plus successful LZ4/header checks is meaningful new evidence, but it is not yet proof of a usable Switch shader or a successful Ryujinx translation.

### How to validate the next B report

After building and installing the updated IPA, run the existing shader-source scan again. For the large `Data/resources.assets` Shader object 142, look for:

- `shader_program_blob_layout|...|status=validated_candidate`
- one or more `shader_program_chunk|...|status=decoded` lines
- matching local files under `Documents/PreparedGame/ShaderSources/ShaderPrograms/`

If the report says `no_bounded_layout_candidate`, the serialized tail layout or array alignment assumption needs correction. If it finds candidates but no valid LZ4/program header, inspect the candidate offsets and decompression result before changing the format assumptions. Object 143 remains the smaller cross-check.

**Verification status:** source committed; not yet built or run on-device. The Actions workflow is manually dispatched, and a fresh B report requires the user to install the new IPA and rerun the scan. Do not describe the scanner as having extracted Cuphead shader programs until a new B report confirms decoded chunks.

## B report: v8 blob-table extraction result — 2026-11-14

The latest checked-in `B` report now identifies scanner revision `unity2017-shader-blob-table-probe-v8` (5,929 lines). The on-device probe reports 65 validated compressed-blob layouts and 65 successful raw-LZ4 chunk decodes. The decoded chunks total 25,056,584 bytes and report 5,698 subprograms in aggregate. Every accepted record in this run is platform value 19.

The large `Data/resources.assets` Shader object 142 was reached: its candidate layout begins at object offset 1,333,016, declares a 3,731,029-byte blob, and decodes to 23,182,308 bytes with a leading count of 5,184 subprograms. The smaller object 143 also produced a decoded chunk (25,654 compressed bytes to 113,340 bytes; 19 subprograms). These results establish that the v8 probe is finding bounded LZ4-compressed data and writing decoded chunk files locally.

**Important limits:** the B report does not contain the decoded chunk bytes themselves. The leading integer is still only being used as a plausibility check; the full SerializedProgram records have not yet been parsed or independently validated. The five generic binary-signature scans (SPIR-V, DXBC, MTLB, DXIL, SHDR) still report zero hits in the raw Shader-object payloads; that does not invalidate the decompression result because the code may be wrapped in Unity's serialized program records. No vertex/fragment stage mapping, shader-code extraction, translator invocation, SPIR-V output, or Metal compilation is demonstrated yet.

### Next milestone

Obtain and inspect the locally written decoded chunk for object 142 (and object 143 as a smaller comparison). Implement a bounded parser for the actual Unity 2017.4 SerializedProgram structure, validate record boundaries and subprogram metadata, and identify the program type/stage and code byte ranges. Only then create a translator job from a real extracted stage and test the existing on-device translator bridge. Keep all game data, raw Shader objects, and decoded program chunks on the iPhone; do not upload them to GitHub.

## Unity 2017.4 SerializedProgram record parser — 2026-11-14

The v9 scanner adds a second parsing layer after raw-LZ4 chunk extraction. It follows the UnityPy/AssetStudio layout for Unity 2017.4:

- Read the subprogram count at the start of the decoded SerializedProgram.
- Read the 8-byte offset-table entries used before Unity 2019.3; each record begins at the entry's 32-bit offset.
- Parse each record's version and GPU-program type, the 12-byte platform metadata, the version-gated 4-byte field, aligned keyword strings, and length-prefixed program-code bytes.
- Validate all offsets, counts, string lengths, code lengths, and buffer ranges before reading.
- Report record counts by numeric GPU-program type and sample record metadata. Save at most 64 nonempty code payloads per object/chunk, capped at 8 MiB, under the local `ShaderPrograms/ProgramCode` directory.

The scanner revision is now `unity2017-serialized-program-record-parser-v9`, and the manual build workflow's source validation was updated to require that exact revision.

**Status: source committed, not yet built or tested on the iPhone.** The 8-byte table and record field sequence are based on UnityPy's version-aware parser (Unity 2017.3/2017.4 uses the 201708220 program record version; the 12-byte table entries begin at Unity 2019.3). This implementation is an initial bounded parser, not yet independently validated against Cuphead's decoded chunks. In particular, the meaning of numeric GPU-program types, the alignment behavior, and whether every table offset is relative to the beginning of the decoded chunk must be confirmed by the next B report. A complete parse requires the expected record count with zero failures and plausible code payload lengths; partial records must not be treated as success.

### Next test

Manually dispatch the shell build, install the resulting IPA, and run the shader scan again. In B, look for `serialized_program_parse` lines for objects 142 and 143. If object 142 reports all 5,184 records parsed, inspect its type counts and sample code prefixes; if offsets or record boundaries fail, use the first failing subprogram index and offset to correct the parser before attempting translation. No raw game files or extracted code payloads should be uploaded to GitHub.

## B report: v9 SerializedProgram parsing result — 2026-11-14

The next on-device B report confirms the v9 parser ran in the installed build:

- Scanner revision: `unity2017-serialized-program-record-parser-v9`.
- Inventory remains 543 files, 82 direct serialized-file scans, and 249,390,016 directly scanned bytes.
- 65 shader chunks were decompressed and all 65 SerializedProgram tables were parsed.
- Across those chunks, 5,698/5,698 subprogram records were structurally parsed; zero record failures.
- Key target `Data/resources.assets`, Shader object 142: 5,184/5,184 records parsed; object 143: 19/19 parsed.
- Every reported record so far has numeric GPU program type 26. UnityPy's `ShaderGpuProgramType` enum identifies 26 as `kShaderGpuProgramConsoleVS` (console vertex shader), not Metal or SPIR-V. The 2017.4 record version is 201708220.
- Object 142's first 24 sampled code payloads are each 2,912 bytes and begin `0000000000000000`. The scanner saved 64 code payloads (186,368 bytes) locally for object 142; object 143 saved 19 (92,448 bytes). All saved data remains on-device.

### Interpretation and next validation

This is a major parser milestone: the offsets, record headers, keyword lists, and code-length fields are internally consistent across all 5,698 records, including the 5,184 variants in object 142. However, **it does not yet establish that the extracted code payloads are valid executable shader programs**. The fact that all observed records are ConsoleVS and that sampled payloads begin with eight zero bytes needs investigation. In particular, do not feed these directly to the existing SPIR-V/NxNative translator: ConsoleVS is a different program type and the payload format has not been identified.

Next scanner revision should profile the full code payload locally (byte histogram/zero and printable ratios, first printable strings, common binary signatures, and a bounded hex preview beyond the leading zero bytes), report payload length distributions, and preserve representative payloads from multiple program variants. Then identify the exact console platform represented by platform ID 19 and the Unity ConsoleVS payload format. Only after establishing a supported source format should we build a converter or translator path. No game data or shader payloads are to be uploaded to GitHub.
