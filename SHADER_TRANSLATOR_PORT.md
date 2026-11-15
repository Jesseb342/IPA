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

## B report recheck — 2026-11-14

A subsequent request to re-read the repository's current `B` file returned the same v9 report as the preceding analysis: 6,593 lines, 65 decoded chunks, 65 structurally parsed SerializedProgram tables, 5,698/5,698 records parsed with zero failures. Object 142 remains 5,184/5,184, object 143 remains 19/19, and the sampled object-142 payloads remain 2,912 bytes with an eight-zero-byte prefix. No new scanner revision, payload profile, or translation result is present. This is a duplicate/recheck of the existing evidence, not a new test result; no scanner source change is justified by an unchanged B report.

## v10 payload profiling and record-boundary hardening — 2026-11-14

The next scanner revision is `unity2017-shader-payload-profile-v10`.

Changes committed:

- Each SerializedProgram record is now bounded by the next physical record offset. Code lengths, keyword strings, and metadata must fit inside that record's own range, rather than merely fitting somewhere before the end of the entire decompressed chunk. Duplicate record offsets are rejected.
- The scanner profiles extracted code payloads locally and reports zero-byte percentage, printable-byte percentage, first nonzero offset, a leading hex preview, a hex window beginning at the first nonzero byte, a bounded ASCII preview, and hits for common SPIR-V/DXBC/DXIL/Metal/SHDR/NVN markers.
- It reports code-payload length distributions per object/chunk. The existing local-only save cap remains 64 payloads / 8 MiB per chunk.

The workflow source-validation check now requires the v10 scanner revision.

### What this test should tell us

For object 142, the new B report should distinguish between an all-zero/mostly-zero payload and a structured binary whose meaningful bytes begin after a zero-filled header. The length distribution will show whether the 2,912-byte sample size is representative or whether there are multiple code layouts. Signature hits are exploratory only; no signature match does not mean the payload is invalid.

**Verification status:** source and workflow validation are committed, but this revision has not yet been built or run on-device. The build remains a manual `workflow_dispatch`; after dispatch, install the resulting IPA and rerun the shader scan to generate a new B report. Do not interpret the v10 source commit as a successful build or as evidence that a shader has translated.


## B report: v10 payload profiling result — 2026-11-14

The current repository `B` file is a fresh v10 report (6,723 lines; 1,109,090 bytes), not the previous v9 report. It identifies scanner revision `unity2017-shader-payload-profile-v10`.

### Confirmed results

- Inventory: 543 files, 286 UnityFS bundles, 82 direct SerializedFile scans covering 249,390,016 bytes.
- 65 shader-program chunks decoded and 65 SerializedProgram tables parsed.
- 5,698/5,698 records parsed successfully; zero failures. All 5,698 records contain program-code payloads and report GPU program type 26.
- The report contains 534 payload profiles. The profiler samples at most 24 payloads per chunk, so this is a bounded sample, not all 5,698 payloads.
- The sampled payloads have 26 distinct lengths, from 2,400 to 11,104 bytes. The most frequent sampled sizes are 2,912 bytes (260 samples), 3,168 bytes (86), 2,656 bytes (74), and 3,424 / 3,680 bytes (23 each).
- All 534 sampled payloads report `signatures=none` for the scanner's SPIR-V, DXBC, DXIL, MTLB, SHDR, and NVN marker checks.


### Target-object detail

The large target, `Data/resources.assets` object 142, parsed all 5,184 records with zero failures. Its full length histogram contains 14 sizes: 2,912 (2,592 records), 3,168 (12), 3,424 (44), 3,680 (120), 3,936 (230), 4,192 (332), 4,448 (354), 4,704 (340), 4,960 (312), 5,216 (332), 5,472 (276), 5,728 (166), 5,984 (58), and 6,240 (16) bytes. The first 24 profiled samples are 2,912-byte records with the same leading structure and approximately 80.5% zero bytes.

The smaller object 143 also parsed all 19 records with zero failures. Its nine observed code lengths range from 2,656 to 6,496 bytes. Its first three profiles show the same repeated header-like words, but varying length and zero/printable ratios. This cross-check suggests the pattern is not unique to object 142.


### What the payload profiles reveal

The samples are not random-looking byte arrays. They repeatedly share a structured leading sequence. Common examples begin:

- `0000000000000000500800000003000034127698010000000f00000020010000`
- `0100000000000000500800000002000034127698010000000f00000020010000`

The eight-byte zero prefix seen in the earlier v9 samples is therefore not the whole story: other records begin with a 32-bit `1` followed by zeros, and the first nonzero byte can be at offset 0 or 8. The repeated fields after that prefix (including the `0x0850`, small count/version-like values, and repeated fixed words) strongly suggest an internal container/header or structured instruction representation. That is a useful lead, but the profile alone does not establish the field meanings or prove that these bytes are directly executable shader machine code.

### Interpretation

The v10 result validates the bounded record parser against all 5,698 records and gives us a repeatable payload fingerprint. It does **not** yet identify the actual console shader encoding, establish that the payload is NVN, or demonstrate a successful translation. The absence of the six tested signatures is not proof that the payload is invalid; those checks only look for those literal markers.

Do not send these type-26 payloads to the SPIR-V/NxNative translator yet. The next step is to identify the repeated payload header/layout using the locally saved representative payloads, map its fields and instruction encoding against a known Unity 2017.4 console shader format, and only then write a format-specific decoder or translator adapter. Keep all game files and extracted payload bytes on-device; the B report contains only bounded metadata and previews.

**Verification status:** this B report confirms that the installed v10 scanner executed and completed the structural parse/profile pass. It does not confirm that the v10 IPA build workflow itself succeeded unless the corresponding Actions build result is checked separately, and it does not confirm shader translation or rendering.


## B report recheck — 2026-11-14 (v10)

A subsequent repository check confirms that `B` is unchanged from the previously analyzed v10 upload: Git blob SHA `59777c2b4173ffec386c3491197d2a4187a1b719`, 6,723 lines, scanner revision `unity2017-shader-payload-profile-v10`. The report still shows 65 decoded chunks, 65 parsed SerializedProgram tables, 5,698/5,698 valid records with zero failures, and 534 payload profile samples. Objects 142 and 143 remain 5,184/5,184 and 19/19 records respectively; object 142's 14-length distribution is unchanged. No translator invocation or translation output appears in the report.

This is a duplicate/recheck of the existing v10 evidence, not a new scan or new test result. No scanner-source change is justified by an identical B file. The next useful input remains either a genuinely new B generated by a later scanner revision or locally available representative payload data / a format reference that can resolve the repeated header and console program encoding.


## B report recheck — 2026-11-14 (post-"Update B" commit)

Checked the repository again after commit `01b6df6e72718bca36e78406260cf7dfc57d90f2` ("Update B"). The commit's tree SHA is identical to its parent commit's tree SHA (`b7d2b22ea7820abe6b1a590011af9ff04a4daa1b`), and the `B` file remains Git blob `59777c2b4173ffec386c3491197d2a4187a1b719` (1,109,099 bytes; 6,723 lines). Its scanner revision and v10 parse/profile results are unchanged.

This upload therefore contains no new scanner output: 65 decoded shader-program chunks, 5,698/5,698 parsed records with zero failures, and 534 bounded payload profiles remain the recorded results. The sampled signatures remain negative for the six tested markers, and there is still no translator invocation or translation result. No scanner change is justified by this recheck. A new diagnostic result requires a B file with a different blob SHA, generated by a changed scanner/build and a fresh on-device scan.



## Scanner revision v11 — distributed payload fingerprints

Committed scanner revision `unity2017-shader-payload-profile-v11-distributed`.

Changes:
- Adds a unique scan UUID and UTC start timestamp to each report, so a newly executed scan can be distinguished from an older copied B file.
- Continues parsing every SerializedProgram record, but selects up to 64 profile records at evenly spaced positions across each chunk's record-index range. This avoids repeatedly profiling only the first 24 records.
- Computes a deterministic 64-bit FNV-1a fingerprint for every non-empty program-code payload encountered. Per-chunk summaries report unique fingerprints and duplicate-record counts; each distributed sample includes its fingerprint.
- Leaves the bounded local payload-save cap unchanged (64 files / 8 MiB per chunk). No payload bytes are uploaded by the scanner.

The manual build workflow's source gate now requires the v11 revision.

**What this can establish:** whether payloads later in the 5,184-record object 142 chunk differ from the previously sampled prefix, and how many distinct byte payloads exist by fingerprint. The FNV-1a value is a compact diagnostic fingerprint, not a cryptographic identity guarantee; collisions are theoretically possible. It does not identify the console bytecode format or translate shaders.

**Verification status:** source and workflow gate are committed, but no v11 IPA build or on-device scan has been run yet. The workflow remains manual. After a successful manual dispatch, install that IPA and run one fresh scan; the resulting B should contain revision v11 plus a new scan UUID. Compare its distributed profiles and unique/duplicate counts before deciding on a format-specific decoder.



## B report: v11 distributed profiling — 2026-11-14

Fetched the current repository `B` directly after the v11 scanner commit. The file is 1,159,500 bytes and 6,769 lines. It is a new report, not a repeat of the v10 report.

### Scan identity and parser results

- Scanner revision: `unity2017-shader-payload-profile-v11-distributed`.
- Scan ID: `045009B5-FE1B-491C-8D45-10E3290D7C6A`.
- Scan started: `2026-11-14T19:54:22Z`.
- Inventory: 543 files, 286 UnityFS bundles, 82 direct SerializedFile scans covering 249,390,016 bytes.
- Target object 142 in `Data/resources.assets`: 5,184/5,184 records parsed, zero failures; 5,184 non-empty code payloads; GPU program type 26.
- Object 142 now has 64 distributed profiles, spanning record indices 40 through 5,143, rather than the previous prefix-only sample.
- The full payload length histogram remains 14 sizes: 2,912 (2,592), 3,168 (12), 3,424 (44), 3,680 (120), 3,936 (230), 4,192 (332), 4,448 (354), 4,704 (340), 4,960 (312), 5,216 (332), 5,472 (276), 5,728 (166), 5,984 (58), and 6,240 (16).

### What v11 adds to our understanding

- The scanner calculated fingerprints for all 5,184 non-empty payloads in object 142.
- It reports 2,592 unique FNV-1a 64-bit fingerprints and 2,592 duplicate payload records. This indicates substantial exact repetition in the code bytes, with many records reusing identical payloads despite different keyword metadata.
- The distributed samples span multiple payload lengths and header count fields. The sample at record index 5,143 is 5,728 bytes; its leading structure includes the same repeated fields seen in smaller records, while the field at offset 12 changes with the payload size/profile.
- The six literal signature checks (SPIR-V, DXBC, DXIL, MTLB, SHDR, NVN) remain negative in the sampled profiles.

### Interpretation and next technical step

This is meaningful new evidence: the earlier conclusion based on the first 24 records was incomplete. The payload family is not limited to one 2,912-byte shape. It includes multiple sizes, and v11's all-record fingerprint pass shows that half of the records in object 142 are duplicate byte payloads under the scanner's 64-bit fingerprint. Since FNV-1a is not cryptographic, this is strong diagnostic evidence of repetition rather than a formal collision-proof identity claim.

The next useful investigation is to map the repeated header fields and compare representative saved payloads from several length classes. In particular, determine whether the size/count fields describe an internal instruction stream or a nested container, and identify the actual platform-19 / GPU-program-type-26 encoding before attempting translation. The current report still does not establish the bytecode format or contain evidence of a translator invocation or successful translation. Do not feed these payloads to the SPIR-V translator based on these findings alone.

**Verification status:** this B proves that a v11 scanner executed on-device and completed the full 5,184-record parse and fingerprint pass. It does not prove shader translation or game rendering.


## B report: v11 distributed payload scan — 2026-11-15

The latest on-device report was uploaded in commit [3049381](https://github.com/Jesseb342/IPA/commit/3049381eb147b8cb52690209ea2efbec883d74e8). It is a new scan, not a repeat: scanner revision `unity2017-shader-payload-profile-v11-distributed`, scan ID `61DAC771-C0D4-428E-824A-AA65458F4556`, started at `2026-11-15T13:11:43Z`. The inventory remains 543 files, 286 UnityFS bundles, and 82 direct SerializedFile scans totaling 249,390,016 bytes.

### Build used for this scan

The manual shell workflow completed successfully at [run 43717208277](https://github.com/Jesseb342/IPA/actions/runs/43717208277), built from workflow commit `6e83aa7b98f459136b4e945eeb14e39e5800c969`. All job steps succeeded, including the v11 source-contract gate, Swift parser syntax check, translator NativeAOT build, app packaging, framework signing, IPA packaging, and game-free payload checks. It produced the `nxnative-universal-shell-ipa` artifact (about 25.3 MB). This proves the generic shell built; it is not a shader translation test.

### Parsing and payload findings

- 65 Shader objects have validated platform-19 compressed-blob layouts and successful bounded LZ4 chunk decodes.
- All 65 decoded chunks parsed: 5,698 subprogram records, 5,698 valid records, 5,698 code records, zero parse failures. Every record is GPU program type 26.
- Main target `Data/resources.assets` object 142 (5,064,092 bytes): one validated platform-19 blob (3,731,029 bytes), 5,184 parsed code records, and 14 distinct code lengths from 2,912 to 6,240 bytes.
- v11 fingerprints all 5,184 code payloads in object 142 and reports 2,592 unique FNV-1a hashes plus 2,592 duplicate records. This suggests substantial payload reuse across variants; FNV-1a is non-cryptographic, so treat it as a grouping signal rather than collision-proof identity.
- Smaller cross-check object 143 (46,656 bytes) also has a validated platform-19 blob (25,654 bytes), one decoded chunk, and all 19 code records parsed without failures. It has nine code lengths and 19 unique sampled fingerprints.
- Distributed samples still report no tested SPIR-V, DXBC, DXIL, MTLB, SHDR, or NVN signatures. Repeated prefixes and structured little-endian fields are visible, but their meanings and the actual instruction/container encoding remain unidentified.

### Interpretation and next step

This is a real advance over the prior v11 B: object 143 is now a second decoded and parsed reference, and both objects confirm the same 8-byte Unity 2017 program-record layout. The 5,698 records are structurally parsed payload records, not proof that their code bytes are already a translator-compatible format.

Next, compare locally saved payloads from objects 142 and 143 across length families and header fields. Determine which bytes are metadata versus instruction payload, then identify the platform-19 / GPU-type-26 encoding using authoritative format evidence. Do not feed these payloads to the Ryujinx SPIR-V translator until the input format is positively identified. Validate the bridge with a known-good supported shader fixture before attempting Cuphead translation. Game data remains on-device; Actions only builds the generic shell.


## B report: v11 distributed scan refresh — 2026-11-15 13:22 UTC

A newer B report is now present (blob SHA `86acb06ad80c7672d93fabb942b88f9b6c288d4e`), with scan ID `8B220F95-E9F7-4613-B2F2-48F72B839C23`, started at `2026-11-15T13:22:03Z`. It uses the same `unity2017-shader-payload-profile-v11-distributed` scanner revision and the same inventory totals: 543 files, 286 UnityFS bundles, and 82 direct SerializedFile scans (249,390,016 bytes). This is a fresh on-device scan, not the prior 13:11 scan.

### What the refreshed B confirms

- 65 platform-19 Shader chunks decoded and parsed successfully: 5,698 subprogram records, 5,698 valid records, 5,698 code records, and zero parse failures. Every parsed record is GPU program type 26, using the validated 8-byte Unity 2017 record layout.
- Main object `Data/resources.assets` object 142 remains the dominant dataset: 5,184 records in a 3,731,029-byte compressed platform-19 blob. The code lengths span 14 classes from 2,912 to 6,240 bytes. The scanner's full-payload fingerprint pass reports 2,592 unique FNV-1a hashes and 2,592 duplicate records in this object.
- Object 143 again parses all 19 records without failure; its 19 payload fingerprints are unique within that object. It has nine code-length classes, including a 6,496-byte record.
- Additional reference object 146 now provides another useful cross-check: 24 records, seven code-length classes (2,656 through 10,080 bytes), and 20 unique fingerprints / four duplicate records.
- The report contains per-object fingerprint summaries for all 65 parsed chunks. Across those summaries, 5,698 records were profiled; 578 representative payload profiles were emitted, while the full per-object hash accounting reports 2,986 unique hashes and 2,712 duplicate records when summed across objects. These are per-object totals, not a globally deduplicated count across the entire game.
- The tested literal signatures remain absent from the inspected shader-object samples. The report still does not identify the actual instruction/container format.

### Interpretation and next step

The important new value is breadth: the refreshed scan confirms the same parser behavior across 65 chunks and adds object 146 as a third substantial reference alongside objects 142 and 143. The strong repetition in object 142 and the additional repeats in object 146 suggest payload reuse is common, but keyword metadata and repeated bytecode must still be treated separately. FNV-1a remains a non-cryptographic grouping signal.

The next investigation should move from scanning more records to decoding the internal code-payload structure. Compare representative saved payloads from objects 142, 143, and 146, including the 2,912-byte family and the longer 8,032-/10,080-byte object-146 records. Map the repeated little-endian header fields and locate the boundary between metadata and executable instructions. Identify the platform-19 / GPU-type-26 encoding with authoritative evidence before writing a decoder or connecting it to the translator. No translator invocation or successful shader translation is demonstrated by this B.

**Verification status:** fresh on-device scan; 65/65 chunks and 5,698/5,698 records parsed. Shader translation and Cuphead rendering remain unverified.



## On-device raw sample analysis and NVN split — 2026-11-15

The uploaded `UnityShaderSamples.nxsamples` archive was parsed locally. Its `NXSAMP1` container is internally consistent: 64 sample entries / 240,640 payload bytes; all entry names, lengths, and final offsets validate. The archive contains 58 unique payloads and six exact duplicate pairs.

### Unity wrapper and NVN code-area structure

All 64 records use the same bounded outer layout:

- +0x00: wrapper flag, observed values 0 and 1 (semantics unresolved).
- +0x04: reserved zero.
- +0x08: control-section length, always 0x850.
- +0x0C: code-area length; control and code areas exactly account for the complete record after the 16-byte wrapper.

The control section starts with magic `0x98761234`; its declared length at control-relative +0x20 is 0x850. The code area starts with graphics magic `0x12345678` in all 64 samples. Its 0x30-byte NVN header is followed by a 0x50-byte Maxwell SPH, with instructions beginning at code-area offset 0x80.

### Correct interpretation of the control offsets

The previous note that treated control +0x700 as a constant and +0x708 as a computed length was incorrect; this section supersedes that interpretation.

The NVN reference documents control +0x700 as the c1 offset in the code area and +0x704 as code size. In the uploaded Cuphead samples:

- +0x700 is at or before +0x704.
- +0x704 exactly equals the wrapper's code-area length.
- +0x708 is 0x30 in all 64 samples. This matches the observed NVN code-header size, but the field's own semantics remain unconfirmed.
- The c1 tail is the code-area range [c1 offset, code size): 42 samples have no c1 tail; 22 have a 0x100-byte c1 tail.

This resolves the previous uncertainty about c1 for the sample corpus. The translator's input should be the 0x50-byte SPH plus instruction bytes, extracted from code-area offset 0x30 up to (but not including) the c1 offset; c1 is supplied separately. Do not include the leading 0x30-byte NVN header or append c1 to the instruction stream.

Reference: [NX Native shader layout notes](https://nx-native.com/docs/reference/shaders), which describe the graphics code-area header/SPH arrangement and the control +0x700/+0x704 fields. The observed Cuphead values have been checked directly against the uploaded sample bytes; the reference does not establish the meaning of Cuphead's wrapper flag or control +0x708 field.

### On-device implementation added

The app now has a **Validate & split NVN graphics** action. It reads only the already extracted local `ProgramCode` samples, validates the wrapper bounds, control magic/declared length, graphics code magic, 0x30-byte header, SPH minimum size, c1 offset, and code-size equality. It then creates a user-shareable `UnityShaderNVNSplits.nvnsplit` archive containing, per sample:

- the complete 0x850-byte control section;
- the 0x30-byte NVN code header;
- the SPH-plus-instructions translator input;
- the SPH and instruction bytes separately for inspection;
- a separate c1 file when the sample has a non-empty c1 tail.

The manifest preserves the wrapper flag and raw +0x708 value without assigning unverified meanings. The splitter does not invoke the translator, guess shader stage, or synthesize resource metadata. All inputs remain in the iPhone app sandbox until the user explicitly shares the generated archive.

### Next validation

1. Build and install the updated shell.
2. Run **Inspect Unity Shader Objects** on the extracted Cuphead game.
3. Run **Validate & split NVN graphics** and share the resulting `.nvnsplit` archive for independent validation.
4. Confirm the split archive reports the expected 64/64 bounded samples and c1 distribution.
5. Then resolve stage identity and resource metadata from Unity's surrounding serialized ShaderProgram/pass/variant structures before creating a real translator job.

No shader translation, SPIR-V output, Metal compilation, or Cuphead rendering has yet been demonstrated.


## Cuphead SPH decode and first translator probe — 2026-11-15

The uploaded on-device UnityShaderNVNSplits.nvnsplit archive was parsed independently. All 342 split entries validate, and reconstructing the original 64 wrapped program records from their split components produces byte-for-byte equality for all 64. No data was lost or reordered by the splitter.

### SPH CommonWord0 resolves the shader stages

The 0x50-byte SPH at the start of each translator program is the NVIDIA Maxwell Shader Program Header. NVIDIA's published SPH specification defines CommonWord0 as:

- bits 0–4: SphType (1 = VTG, 2 = pixel shader);
- bits 5–9: SPH Version;
- bits 10–13: ShaderType (1 = vertex, 5 = pixel);
- bit 14: MrtEnable;
- bit 15: KillsPixels;
- bits 17–20: SassVersion.

Observed values in the 64 Cuphead samples:

| CommonWord0 | Count | Decoded stage and flags |
|---|---:|---|
| 0x02060461 | 28 | VTG, version 3, vertex, SASS version 3 |
| 0x00065462 | 33 | Pixel, version 3, pixel, MRT enabled, SASS version 3 |
| 0x0006D462 | 3 | Pixel, version 3, pixel, MRT enabled, kills-pixels enabled, SASS version 3 |

This gives **28 vertex and 36 pixel/fragment programs**. The wrapper flag is 0 on all 28 vertex samples and 1 on all 36 pixel samples, but the implementation continues to preserve it as raw metadata rather than treating that correlation as its definition.

The NVIDIA specification page's overview sentence reverses the VTG/PS SphType values shown in its own enum table. The decode follows the table and is independently corroborated by devkitPro/uam's source header, which explicitly defines NvSphType_VTG = 1, NvSphType_PS = 2, NvShaderType_Vertex = 1, and NvShaderType_Pixel = 5.

The stage is now established from the SPH itself. This supersedes the earlier note that stage identity was unresolved.

### Stage-specific interface fields

- All 36 pixel samples have OmapTarget[0] = 0xF, meaning RGBA components are enabled for color target 0. The pixel output flags at SPH +0x4C are zero in all 36 samples (sample-mask and depth outputs are not enabled).
- Three of the 36 pixel samples set KillsPixels; the other 33 do not.
- Pixel generic input maps contain 10 distinct patterns. Every active component in these maps uses interpolation mode 2 (Perspective), according to NVIDIA's PixelImap enum.
- Vertex generic input/output maps contain 9 distinct input/output map pairs. The maps encode active generic attribute components; they are not a substitute for the actual integer/float attribute-type answers required by the translator.
- CommonWord1 through CommonWord4 are zero in all 64 samples. These fields cover local-memory sizes, per-patch/thread counts, geometry output topology/vertex count, and store-request ranges.

The 0x30-byte NVN code header is also uniform in this corpus: graphics magic 0x12345678 followed by zero bytes.

### Instruction payload is Maxwell SASS v3

Every one of the 64 instruction areas has a length divisible by 32 bytes. Across the archive there are 2,800 such 32-byte bundles (11,200 64-bit words total). The Maxwell/Pascal pre-Volta SASS layout uses one 64-bit scheduling/control word followed by three 64-bit instruction words in each bundle. This matches the observed alignment and the SPH's SassVersion=3 field.

The instruction data is therefore not SPIR-V, DXBC, DXIL, Metal library data, or NVN wrapper metadata. It is the native Maxwell SASS stream expected by the existing Ryujinx translator path. The translator job's code file must contain the 0x50-byte SPH followed by the SASS instructions; it must not include the leading 0x30-byte NVN code header. A non-empty c1 tail is supplied separately in the job's c1 field.

### First on-device translation test added

The import screen now has **Translate one Cuphead vertex shader**. It:

1. checks the embedded Ryujinx translator's native probe;
2. selects the smallest bounded vertex sample with an empty c1 tail and complete SASS bundles;
3. writes the exact 0x50-byte SPH plus SASS instruction stream into Documents/ShaderTranslatorProbe;
4. creates a one-job JSON file with stage vs and invokes nxn_translate_shader_jobs;
5. validates that the output is a SPIR-V module and reports the translator's resource reflection and diagnostic notes. On failure, the translator writes a per-shader .error.txt file with the exception detail and stack trace, which the app surfaces in its report.

For this first diagnostic only, resource answers are intentionally left at the translator's defaults: vertex attributes default to float, unknown texture types default to 2D, and unknown image formats default to RGBA8 UNORM. A successful SPIR-V output proves the Cuphead code passed through the translator; it does not prove those fallback resource types are correct, nor does it prove Metal compilation or game rendering.

### Next manual test

1. Run **Build Universal NxNative Shell** manually from the latest main; no workflow is dispatched automatically by a commit.
2. Install the new IPA and open the extracted Cuphead game in the app.
3. Tap **Translate one Cuphead vertex shader**.
4. Share the resulting translation report. If translation succeeds, inspect its reflection and notes before attempting pixel shaders or a Metal pipeline.

### First real Cuphead vertex translation — 2026-11-15

The first on-device report confirms:

- Sample: `data-resources-assets-shader-object-151-p19-c0-s14-t26-len2656.bin`
- Stage: vertex, decoded from SPH
- SASS: 384 instruction bytes / 12 bundles
- Output: 1,940-byte SPIR-V module with valid magic
- Translator notes: none
- Reflected textures, images, constant buffers, and storage buffers: zero in each category

This is the first confirmed Cuphead program translated through the embedded Ryujinx path. It is a small shader with no reflected descriptor resources in those four categories. That does not establish that it has no vertex inputs/outputs, and the current resource report does not include an attribute inventory. The result also does not validate semantic correctness, Metal compilation, or game rendering.

### Next diagnostic: survey all vertex programs

The on-device action has been expanded from one smallest-sample probe to a batch survey of all bounded SPH-version-3 / SASS-version-3 Cuphead vertex samples. It preserves each sample's c1 tail and passes it through the job's `c1` field, rather than excluding non-empty c1 cases. For each job, the app validates SPIR-V output, reads the resource reflection, records translator errors, and ranks successful shaders by reflected resource count and instruction size. This should identify more representative vertex programs and show whether the first sample's empty reflection was simply a property of that small shader.

The survey remains a diagnostic: absent `attr` answers still use the translator's float default, and texture/image type answers remain defaults unless inferred by the translator from instructions. The next step after the batch report is to select a resource-bearing shader (if one exists), then reconcile its resource and interface requirements with Unity's serialized ShaderProgram/pass/variant metadata.

No successful Cuphead shader rendering is claimed.

### References

- NVIDIA, [Shader Program Header Specification](https://nvidia.github.io/open-gpu-doc/Shader-Program-Header/Shader-Program-Header.html) — SPH CommonWord0, stage values, and stage-specific interface layouts.
- devkitPro, [uam source/nv_shader_header.h](https://github.com/devkitPro/uam/blob/5a5afc2bae8b55409ab36ba45be63fcb73f68993/source/nv_shader_header.h) — explicit VTG/PS and vertex/pixel enum values, plus the packed 80-byte structure.
- NVIDIA, [CUDA Binary Utilities — Instruction Set Reference](https://docs.nvidia.com/cuda/archive/12.3.1/cuda-binary-utilities/index.html) — Maxwell/Pascal SASS instruction-set reference.
- NervanaSystems, [Maxas Control Codes](https://github.com/NervanaSystems/maxas/wiki/Control-Codes) — Maxwell's one control word for each group of three instructions.
- NX Native, [Shader format notes](https://nx-native.com/docs/reference/shaders) — NVN code/control layout and c1 placement.


## Cuphead vertex survey — 95/95 translated; expanded reflection diagnostics — 2026-11-15

The user ran the on-device batch survey against the current Cuphead extraction and reported:

- 95 vertex jobs submitted.
- 95 valid SPIR-V modules produced.
- Zero failed or invalid outputs.
- Translator exit code zero.
- Aggregate translator reflection: 1 texture, 0 images, 103 constant-buffer entries, and 2 storage-buffer entries.
- The eight highest-ranked samples include resource-bearing programs. The leading sample is Shader object 138, subprogram 12, with 1 texture and 2 constant buffers. Shader object 141, subprograms 8 and 9, each report 2 constant buffers and 1 storage buffer. Object 143 subprogram 2 and object 133 subprogram 2 are larger examples with 2 constant buffers each.
- The two object-141 records are named as a duplicate in the survey output; confirm payload identity before treating them as distinct programs.

This is strong evidence that the on-device Ryujinx translator can translate the surveyed Cuphead vertex programs into structurally valid SPIR-V. It does not establish correct attribute typing, correct descriptor/resource semantics, successful MSL generation, Metal compilation, or correct rendering. The aggregate resource totals count reflection entries across jobs; they are not counts of unique game resources.

### Follow-on diagnostic implementation

The survey/report path has been extended to make the next run more informative:

1. **Unity record sidecars:** when the Unity 2017.4 SerializedProgram parser saves a program-code sample, it now saves adjacent JSON metadata containing the Shader object index, platform, chunk, subprogram index, record version, GPU program type, keyword count, and parsed keyword strings. The vertex survey copies a matching sidecar into its output directory.
2. **SPIR-V interfaces:** the app now parses the generated SPIR-V instruction stream and reports vertex input/output variables, location decorations, built-ins, and their scalar/vector/matrix/array/struct type descriptions.
3. **Descriptor inventory:** the report lists SPIR-V descriptor set/binding, storage class, variable name, and type.
4. **Buffer layout:** for uniform/storage-buffer struct variables, the report lists member names, member indices, explicit byte offsets where present, and member types.
5. **Translator resource details:** the top eight candidates now include the translator's individual texture, image, constant-buffer, and storage-buffer reflection records, rather than only counts, plus translator notes.

The parser reports only the metadata it actually decodes. It now includes interface-block member decorations and reports explicit member offsets plus array/matrix strides when those SPIR-V decorations are present. This is still not a complete ABI layout: row/column-major interpretation, every packing/alignment rule, implicit padding, and host-side binding correctness still need validation. The Unity sidecar ties a sample to its Shader object and subprogram index and preserves its keyword list; it does not yet identify a human-readable ShaderLab pass name or prove the exact pass/variant linkage.

### Next manual test

The new sidecars are generated during the Unity Shader-object inspection, so the existing extraction alone is not sufficient to populate them. Manually build and install the latest shell, then:

1. Run **Inspect Unity Shader Objects** again against the already extracted Cuphead game. This regenerates the local program samples and their Unity metadata sidecars.
2. Run **Survey all Cuphead vertex shaders**.
3. Share the full survey report, especially unity_metadata_sidecars, unity_record, interface_input, interface_output, spirv_descriptor, spirv_buffer_layout, spirv_buffer_member, and resource_* lines.

Use those records to determine whether the vertex input locations and numeric types can be recovered from the Maxwell SPH/SASS and Unity keyword/pass metadata, and whether the constant-buffer offsets agree with the host layout. Do not silently accept the translator's current float attribute fallback as authoritative. After the vertex interfaces and resource layouts are understood, proceed to SPIR-V-to-MSL and Metal compilation for selected representative shaders; only then expand to pixel shader translation.

**Build status:** source changes are committed, but no Actions build has been dispatched and no new IPA has been built or tested with these diagnostics. The workflow remains manual (workflow_dispatch); commits do not trigger a build. All game files and generated shader data remain on the iPhone.
