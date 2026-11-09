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

The probe is deliberately non-blocking for the ordinary shell build: if NativeAOT cannot compile the translator, the workflow still produces its normal shell artifact and uploads the diagnostic log. This avoids making the existing app build unusable while we identify compatibility blockers.

## Important build-version finding

The upstream `dmsh_xlate.csproj` targets **.NET 10.0** and references:

- `Ryujinx.Graphics.Shader`
- `Ryujinx.Common`

The existing LibHac metadata probe uses .NET 9. It does not establish that Ryujinx can be compiled for iOS. The new probe uses .NET 10 and the iOS workload.

The Ryujinx shader project also references `Spv.Generator`; `Ryujinx.Common` brings NuGet dependencies including RecyclableMemoryStream, MsgPack.Cli, Humanizer, and Gommon. Their iOS NativeAOT compatibility is one of the things this test is intended to discover.

## What this test does and does not prove

A successful publish would prove that the upstream translator code and its dependency graph can be linked into an iOS ARM64 NativeAOT library with a callable native entry point. It would **not yet prove** that a real Cuphead shader translates correctly or that the framework runs on the iPhone.

The next validation after a successful build is to call the exported function on-device with a tiny known shader fixture, then compare its SPIR-V/resource output with the upstream desktop translator. Only after that should we connect Cuphead's extracted shader jobs.

## Remaining conversion stages

1. Port Cuphead's Unity 2017.4 shader discovery/splitting logic to run locally.
2. Verify actual shader translation on-device using the new C ABI bridge.
3. Build SPIRV-Cross as an iOS native library to convert SPIR-V to MSL.
4. Feed MSL into the existing Swift Metal compiler endpoint.
5. Port the executable compatibility rewrites and complete local packaging/launch.

Cuphead's upstream profile remains a useful reference (Unity 2017.4.9f1; 13,057 shaders), but that profile does not mean this app can currently translate those shaders.

## Non-negotiable boundary

GitHub Actions may compile generic app components and libraries. It must never receive the user's NSP/XCI files or prod.keys, or perform a user's game conversion. The translator's runtime inputs must be files already imported into the app's own iPhone sandbox.
