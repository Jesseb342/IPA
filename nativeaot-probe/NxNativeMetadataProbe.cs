using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.Ncm;

public static unsafe class NxNativeMetadataProbe
{
    // C ABI:
    // int nxn_inspect_nsp(const char* prodKeysPath, const char* nspPath,
    //                     char* outputUtf8, int outputCapacity)
    // Output lines: content|<ContentMetaType>|<16-digit title ID>|<version>
    // Errors are returned as: error|<message>
    [UnmanagedCallersOnly(EntryPoint = "nxn_inspect_nsp", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int Inspect(byte* keysPathPointer, byte* nspPathPointer, byte* outputPointer, int outputCapacity)
    {
        try
        {
            if (keysPathPointer == null || nspPathPointer == null || outputPointer == null || outputCapacity <= 1)
                return -1;

            string keysPath = Marshal.PtrToStringUTF8((IntPtr)keysPathPointer);
            string nspPath = Marshal.PtrToStringUTF8((IntPtr)nspPathPointer);
            if (string.IsNullOrWhiteSpace(keysPath) || string.IsNullOrWhiteSpace(nspPath))
                return WriteOutput(outputPointer, outputCapacity, "error|Missing input path.");

            KeySet keys = ExternalKeyReader.ReadKeyFile(keysPath);
            List<Nca> ncas = OpenNsp(keys, nspPath);
            CheckMetaKeys(keys, ncas, nspPath);

            var records = ReadMetas(ncas)
                .Select(c => $"content|{c.Type}|{c.TitleId:x16}|{c.TitleVersion.Version}")
                .ToArray();

            if (records.Length == 0)
                return WriteOutput(outputPointer, outputCapacity, "error|No readable CNMT content metadata was found.");

            return WriteOutput(outputPointer, outputCapacity, string.Join("\n", records));
        }
        catch (Exception ex)
        {
            // Do not return key material or dump arbitrary internal state to the caller.
            string message = ex.Message ?? ex.GetType().Name;
            return WriteOutput(outputPointer, outputCapacity, "error|" + message.Replace("\r", " ").Replace("\n", " "));
        }
    }

    private static int WriteOutput(byte* destination, int capacity, string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length + 1 > capacity)
            return -2;
        Marshal.Copy(bytes, 0, (IntPtr)destination, bytes.Length);
        destination[bytes.Length] = 0;
        return bytes.Length;
    }

    private static IEnumerable<Cnmt> ReadMetas(List<Nca> ncas)
    {
        foreach (Nca nca in ncas)
        {
            if (nca.Header.ContentType != NcaContentType.Meta)
                continue;

            IFileSystem metaFs = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
            foreach (DirectoryEntryEx entry in metaFs.EnumerateEntries("*.cnmt", SearchOptions.Default))
            {
                using var file = new UniqueRef<IFile>();
                metaFs.OpenFile(ref file.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                yield return new Cnmt(file.Release().AsStream());
            }
        }
    }

    private static List<Nca> OpenNsp(KeySet keys, string path)
    {
        // Keep the source storage alive for as long as the returned NCAs are used.
        var storage = new LocalStorage(path, FileAccess.Read);
        var packageFs = new PartitionFileSystem();
        packageFs.Initialize(PackageStorage(storage)).ThrowIfFailure();

        var ncas = new List<Nca>();
        foreach (DirectoryEntryEx entry in packageFs.EnumerateEntries("*", SearchOptions.Default))
        {
            using var file = new UniqueRef<IFile>();
            packageFs.OpenFile(ref file.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            IStorage content = file.Release().AsStorage();

            if (entry.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase))
            {
                byte[] ticket = new byte[0x2c0];
                content.Read(0, ticket).ThrowIfFailure();
                if (ticket[0x281] == 0)
                    keys.ExternalKeySet.Add(
                        new RightsId(ticket.AsSpan(0x2a0, 0x10)),
                        new AccessKey(ticket.AsSpan(0x180, 0x10))).ThrowIfFailure();
            }
            else if (entry.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase))
            {
                ncas.Add(new Nca(keys, content));
            }
        }

        if (ncas.Count == 0)
            throw new InvalidDataException("The package contains no NCA files.");
        return ncas;
    }

    private static IStorage PackageStorage(IStorage source)
    {
        source.GetSize(out long size).ThrowIfFailure();
        if (size < 16)
            throw new InvalidDataException("Truncated PFS0 header.");

        byte[] first = new byte[16];
        source.Read(0, first).ThrowIfFailure();
        if (!first.AsSpan(0, 4).SequenceEqual("PFS0"u8))
            throw new InvalidDataException("Missing PFS0 package signature.");

        uint count = BinaryPrimitives.ReadUInt32LittleEndian(first.AsSpan(4));
        uint strings = BinaryPrimitives.ReadUInt32LittleEndian(first.AsSpan(8));
        long headerSize = 16 + 24L * count + strings;
        if (headerSize > size || headerSize >= int.MaxValue)
            throw new InvalidDataException("Invalid PFS0 filename table size.");

        byte[] header = new byte[(int)headerSize + 1];
        source.Read(0, header.AsSpan(0, (int)headerSize)).ThrowIfFailure();
        for (int i = 0; i < count; i++)
        {
            uint nameOffset = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(16 + 24 * i + 16));
            if (nameOffset >= strings)
                throw new InvalidDataException("PFS0 filename offset is outside the string table.");
        }

        if (strings == 0 || header[(int)headerSize - 1] == 0)
            return source;

        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8), strings + 1);
        return new ConcatenationStorage(new IStorage[]
        {
            new MemoryStorage(header),
            new SubStorage(source, headerSize, size - headerSize)
        }, false);
    }

    private static void CheckMetaKeys(KeySet keys, List<Nca> ncas, string path)
    {
        foreach (Nca nca in ncas)
        {
            if (nca.Header.ContentType != NcaContentType.Meta)
                continue;

            for (int section = 0; section < 4; section++)
            {
                if (nca.SectionExists(section) && !nca.CanOpenSection(section))
                    throw new InvalidDataException(
                        $"prod.keys cannot decrypt metadata in {Path.GetFileName(path)}; check the key dump and title tickets.");
            }
        }
    }
}
