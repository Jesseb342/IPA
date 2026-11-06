using System.Runtime.InteropServices;
using LibHac.Common.Keys;
using LibHac.Fs.Fsa;
using LibHac.Tools.FsSystem.NcaUtils;

// Deliberately tiny proof-of-concept: force the iOS NativeAOT compiler to
// analyze and link the same LibHac assembly used by nx_extract. This is not
// the production extractor and does not process or expose key material.
public static class LibHacAotProbe
{
    [UnmanagedCallersOnly(EntryPoint = "parabox_libhac_aot_probe")]
    public static int Probe()
    {
        // These are the same representative LibHac APIs used by nx_extract.
        return typeof(KeySet).Name.Length
             + typeof(IFileSystem).Name.Length
             + typeof(Nca).Name.Length;
    }
}
