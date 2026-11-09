# On-device Switch shader translator port

## What the source inspection established

The upstream translator is not a command-line wrapper around a small conversion routine. `dm/gfx/tools/dmsh_xlate/Program.cs` contains two separable parts:

1. **Translation core** — `SwshXlate.Accessor` implements Ryujinx's `IGpuAccessor`, answers game-specific hardware/resource questions, creates a Ryujinx translation context, and produces SPIR-V plus resource metadata.
2. **Desktop command-line shell** — `Main(string[] args)` reads a JSON job file and shader-code files from disk, writes `.spv` and `.res.json` files, and reports per-shader failures to stderr.

The iPhone app needs the first part, not the desktop shell. The port should expose a small native-callable API that accepts one shader job and its code bytes, returns SPIR-V and resource metadata, and reports errors as data. It must not expect command-line arguments, desktop paths, or a process launch.

## Important build-version finding

The upstream `dmsh_xlate.csproj` targets **.NET 10.0** and references:

- `Ryujinx.Graphics.Shader`
- `Ryujinx.Common`

The current IPA workflow's isolated NativeAOT probe installs .NET 9. That probe is for the existing LibHac framework and does not prove the Ryujinx translator can be built. A translator probe must install the .NET 10 SDK separately and target iOS ARM64.

The Ryujinx shader project also references `Spv.Generator`; `Ryujinx.Common` brings NuGet dependencies including RecyclableMemoryStream, MsgPack.Cli, Humanizer, and Gommon. These dependencies must be tested under iOS NativeAOT rather than assumed compatible.

## Recommended implementation sequence

1. **Create an isolated iOS ARM64 NativeAOT feasibility probe** using .NET 10. Reference the exact upstream Ryujinx shader/common projects and compile a tiny exported function that creates a translator context for a synthetic shader or, at minimum, initializes the translator types.
2. **Record the actual compiler result and warnings.** If NativeAOT fails because of unsupported APIs, reflection, dynamic code, or platform dependencies, identify the smallest blocking dependency before changing the app.
3. **Separate the translation core from `Main`.** Preserve upstream shader-query behavior and game-specific facts, but replace file/CLI input-output with a stable C ABI bridge suitable for Swift. Keep the existing desktop tool intact for reference.
4. **Build and package the translator as an iOS ARM64 framework**, then call it from the app using local file data. No game content or keys go to GitHub; the workflow only compiles the generic framework.
5. **Test with synthetic shader fixtures first**, then Cuphead's already-extracted local shader jobs. Compare SPIR-V/resource outputs with the upstream desktop translator.
6. **Pass generated SPIR-V through an iOS build of SPIRV-Cross**, then compile resulting MSL using the app's existing Metal compiler endpoint.

## Current status and limits

- The Swift Metal source compiler endpoint exists, but has not yet been verified in an installed iPhone build.
- The Ryujinx translator has not yet been ported or compiled for iOS.
- The SPIRV-Cross iOS library has not yet been built.
- Cuphead's upstream profile is a useful reference (Unity 2017.4.9f1; 13,057 shaders), but this does not mean this app can currently translate those shaders.
- No game-specific conversion is performed by GitHub Actions. The final translator must execute on the iPhone against files already imported into its app sandbox.
