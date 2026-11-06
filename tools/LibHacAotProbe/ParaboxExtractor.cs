using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Runtime.CompilerServices;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem.NcaUtils;

public static class ParaboxExtractor
{
    // C ABI:
    // int parabox_extract_base_romfs(const char* prodKeysPath,
    //     const char* baseNspPath, const char* destinationPath,
    //     char* errorUtf8, int errorCapacity);
    // Returns 0 on success; nonzero on failure. The destination is replaced
    // only after extraction has completed successfully.
    [UnmanagedCallersOnly(EntryPoint = "parabox_extract_base_romfs",
        CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int ExtractBaseRomFs(
        IntPtr keysPathPtr, IntPtr nspPathPtr, IntPtr destinationPathPtr,
        IntPtr errorPtr, int errorCapacity)
    {
        try
        {
            string keysPath = RequiredPath(keysPathPtr, "prod.keys");
            string nspPath = RequiredPath(nspPathPtr, "NSP");
            string destinationPath = RequiredPath(destinationPathPtr, "destination");

            if (!File.Exists(keysPath)) throw new FileNotFoundException("prod.keys was not found.");
            if (!File.Exists(nspPath)) throw new FileNotFoundException("The selected NSP was not found.");

            string parent = Path.GetDirectoryName(destinationPath);
            if (string.IsNullOrEmpty(parent)) throw new IOException("The destination must have a parent directory.");
            Directory.CreateDirectory(parent);

            string staging = destinationPath + ".importing";
            string backup = destinationPath + ".previous";
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            if (Directory.Exists(backup)) Directory.Delete(backup, true);
            Directory.CreateDirectory(staging);

            try
            {
                Extract(keysPath, nspPath, staging);
                if (Directory.Exists(destinationPath))
                    Directory.Move(destinationPath, backup);
                Directory.Move(staging, destinationPath);
                if (Directory.Exists(backup)) Directory.Delete(backup, true);
                return 0;
            }
            catch
            {
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
                if (!Directory.Exists(destinationPath) && Directory.Exists(backup))
                    Directory.Move(backup, destinationPath);
                throw;
            }
        }
        catch (Exception ex)
        {
            WriteError(errorPtr, errorCapacity, ex.Message);
            return 1;
        }
    }

    private static string RequiredPath(IntPtr pointer, string label)
    {
        if (pointer == IntPtr.Zero) throw new ArgumentException("Missing " + label + " path.");
        string value = Marshal.PtrToStringUTF8(pointer);
        if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Missing " + label + " path.");
        return value;
    }

    private static void WriteError(IntPtr pointer, int capacity, string message)
    {
        if (pointer == IntPtr.Zero || capacity <= 0) return;
        byte[] bytes = Encoding.UTF8.GetBytes(message ?? "Unknown extraction error.");
        int count = Math.Min(bytes.Length, capacity - 1);
        Marshal.Copy(bytes, 0, pointer, count);
        Marshal.WriteByte(pointer, count, 0);
    }

    private static void Extract(string keysPath, string nspPath, string output)
    {
        KeySet keys = ExternalKeyReader.ReadKeyFile(keysPath);
        var storage = new LocalStorage(nspPath, FileAccess.Read);
        byte[] magic = new byte[4];
        storage.Read(0x100, magic).ThrowIfFailure();
        if (Encoding.ASCII.GetString(magic) == "HEAD")
            throw new NotSupportedException("This first on-device importer supports NSP files, not XCI.");

        var package = new PartitionFileSystem();
        package.Initialize(storage).ThrowIfFailure();

        Nca program = null;
        foreach (DirectoryEntryEx entry in package.EnumerateEntries("*", SearchOptions.Default))
        {
            if (!entry.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase)) continue;
            using var file = new UniqueRef<IFile>();
            package.OpenFile(ref file.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            var nca = new Nca(keys, file.Release().AsStorage());
            if (nca.Header.ContentType == NcaContentType.Program)
            {
                program = nca;
                break;
            }
        }

        if (program == null) throw new InvalidDataException("No Program NCA was found in the selected NSP.");
        IStorage romfsStorage = program.OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        var romfs = new RomFsFileSystem(romfsStorage);
        CopyRomFs(romfs, output);
    }

    private static void CopyRomFs(IFileSystem fileSystem, string destination)
    {
        byte[] buffer = new byte[4 << 20];
        foreach (DirectoryEntryEx entry in fileSystem.EnumerateEntries("*", SearchOptions.RecurseSubdirectories))
        {
            string relative = entry.FullPath.TrimStart('/');
            string outputPath = Path.Combine(destination, relative);
            if (entry.Type == DirectoryEntryType.Directory)
            {
                Directory.CreateDirectory(outputPath);
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(outputPath));
            using var input = new UniqueRef<IFile>();
            fileSystem.OpenFile(ref input.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            using var output = File.Create(outputPath);
            for (long offset = 0; offset < entry.Size;)
            {
                int requested = (int)Math.Min(buffer.Length, entry.Size - offset);
                input.Get.Read(out long read, offset, buffer.AsSpan(0, requested), ReadOption.None).ThrowIfFailure();
                if (read <= 0) throw new IOException("Unexpected end of RomFS file: " + entry.FullPath);
                output.Write(buffer, 0, (int)read);
                offset += read;
            }
        }
    }
}
