using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

public static unsafe class NxNativeShaderTranslatorExports
{
    // C ABI entry point for the iOS app. Both paths must point to files in the app's
    // own sandbox. This wrapper never performs network access or transfers content.
    [UnmanagedCallersOnly(EntryPoint = "nxn_translate_shader_jobs", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int TranslateShaderJobs(byte* jobFileUtf8, byte* outputDirectoryUtf8)
    {
        try
        {
            string jobFile = Marshal.PtrToStringUTF8((nint)jobFileUtf8);
            string outputDirectory = Marshal.PtrToStringUTF8((nint)outputDirectoryUtf8);
            if (string.IsNullOrWhiteSpace(jobFile) || string.IsNullOrWhiteSpace(outputDirectory))
                return -2;
            return SwshXlate.Main(new[] { jobFile, outputDirectory });
        }
        catch
        {
            return -1;
        }
    }

    // A lightweight exported symbol used by the build probe to ensure the
    // Ryujinx translator assembly is linked into the NativeAOT library.
    [UnmanagedCallersOnly(EntryPoint = "nxn_shader_translator_probe", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int Probe()
    {
        GC.KeepAlive(typeof(Ryujinx.Graphics.Shader.Translation.Translator));
        return 1;
    }
}
