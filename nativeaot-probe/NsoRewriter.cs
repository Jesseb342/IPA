using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

public static unsafe class NxNativeNsoRewriter
{
    // Patch manifest rows:
    // build-id (first 16 bytes, hex)|text-offset (hex)|expected bytes (hex)|replacement bytes (hex)|reason
    // Patches are exact, same-length, 4-byte-aligned replacements inside the NSO text segment only.
    // Empty manifest path performs a verified, lossless NSO container rewrite without changing code.
    [UnmanagedCallersOnly(EntryPoint = "nxn_rewrite_nso", CallConvs = new[] { typeof(CallConvCdecl) })]
    public static int Rewrite(byte* inputPointer, byte* outputPointer, byte* manifestPointer,
                              byte* resultPointer, int resultCapacity)
    {
        if (inputPointer == null || outputPointer == null || resultPointer == null || resultCapacity <= 1)
            return -1;

        string inputDir = Marshal.PtrToStringUTF8((IntPtr)inputPointer);
        string outputDir = Marshal.PtrToStringUTF8((IntPtr)outputPointer);
        string manifestPath = manifestPointer == null ? "" : Marshal.PtrToStringUTF8((IntPtr)manifestPointer);
        try
        {
            if (string.IsNullOrWhiteSpace(inputDir) || !Directory.Exists(inputDir))
                throw new InvalidDataException("Input ExeFS directory does not exist.");
            if (string.IsNullOrWhiteSpace(outputDir))
                throw new InvalidDataException("Output directory is missing.");

            string inputFull = Path.GetFullPath(inputDir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string outputFull = Path.GetFullPath(outputDir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (outputFull.StartsWith(inputFull, StringComparison.Ordinal))
                throw new InvalidDataException("Output must not be inside the source ExeFS directory.");

            var patches = LoadPatches(manifestPath);
            string parent = Path.GetDirectoryName(outputFull.TrimEnd(Path.DirectorySeparatorChar));
            Directory.CreateDirectory(parent);
            string staging = outputFull.TrimEnd(Path.DirectorySeparatorChar) + ".staging-" + Guid.NewGuid().ToString("N");
            string backup = outputFull.TrimEnd(Path.DirectorySeparatorChar) + ".backup-" + Guid.NewGuid().ToString("N");
            int modules = 0, changed = 0, copied = 0;
            var report = new StringBuilder();

            try
            {
                Directory.CreateDirectory(staging);
                foreach (string source in Directory.EnumerateFiles(inputFull, "*", SearchOption.AllDirectories)
                                                   .OrderBy(p => p, StringComparer.Ordinal))
                {
                    string relative = Path.GetRelativePath(inputFull, source);
                    string destination = Path.Combine(staging, relative);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    if (IsNso(source))
                    {
                        int applied;
                        string detail = RewriteOne(source, destination, patches, out applied);
                        modules++;
                        changed += applied;
                        report.AppendLine(detail);
                    }
                    else
                    {
                        File.Copy(source, destination, true);
                        copied++;
                    }
                }

                if (modules == 0) throw new InvalidDataException("No NSO modules were found in ExeFS.");
                if (Directory.Exists(outputFull.TrimEnd(Path.DirectorySeparatorChar)))
                {
                    Directory.Move(outputFull.TrimEnd(Path.DirectorySeparatorChar), backup);
                    try { Directory.Move(staging, outputFull.TrimEnd(Path.DirectorySeparatorChar)); }
                    catch
                    {
                        Directory.Move(backup, outputFull.TrimEnd(Path.DirectorySeparatorChar));
                        throw;
                    }
                    Directory.Delete(backup, true);
                }
                else
                {
                    Directory.Move(staging, outputFull.TrimEnd(Path.DirectorySeparatorChar));
                }
            }
            catch
            {
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
                if (Directory.Exists(backup) && !Directory.Exists(outputFull.TrimEnd(Path.DirectorySeparatorChar)))
                    Directory.Move(backup, outputFull.TrimEnd(Path.DirectorySeparatorChar));
                throw;
            }

            report.Insert(0, $"summary|{modules} NSO module(s) rewritten; {changed} verified text patch(es) applied; {copied} non-NSO file(s) copied. NSO segments are uncompressed and SHA-256 verified.\n");
            return WriteResult(resultPointer, resultCapacity, report.ToString());
        }
        catch (Exception e)
        {
            return WriteResult(resultPointer, resultCapacity,
                "error|" + (e.Message ?? e.GetType().Name).Replace("\r", " ").Replace("\n", " "));
        }
    }

    private sealed class Patch
    {
        public string BuildId;
        public int Offset;
        public byte[] Expected;
        public byte[] Replacement;
        public string Reason;
    }

    private static List<Patch> LoadPatches(string path)
    {
        var result = new List<Patch>();
        if (string.IsNullOrWhiteSpace(path)) return result;
        if (!File.Exists(path)) throw new FileNotFoundException("Patch manifest was not found.", path);
        int lineNumber = 0;
        foreach (string raw in File.ReadLines(path))
        {
            lineNumber++;
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
            string[] fields = line.Split('|');
            if (fields.Length != 5) throw new InvalidDataException($"Patch manifest line {lineNumber} must contain five pipe-separated fields.");
            string buildId = fields[0].Trim().ToLowerInvariant();
            if (buildId.Length != 32 || !buildId.All(Uri.IsHexDigit))
                throw new InvalidDataException($"Patch manifest line {lineNumber} has an invalid 16-byte build ID.");
            if (!int.TryParse(fields[1].Trim(), System.Globalization.NumberStyles.HexNumber,
                              System.Globalization.CultureInfo.InvariantCulture, out int offset) || offset < 0 || (offset & 3) != 0)
                throw new InvalidDataException($"Patch manifest line {lineNumber} has an invalid or unaligned text offset.");
            byte[] expected, replacement;
            try
            {
                expected = Convert.FromHexString(fields[2].Trim());
                replacement = Convert.FromHexString(fields[3].Trim());
            }
            catch { throw new InvalidDataException($"Patch manifest line {lineNumber} contains invalid hexadecimal bytes."); }
            if (expected.Length == 0 || expected.Length != replacement.Length || (expected.Length & 3) != 0)
                throw new InvalidDataException($"Patch manifest line {lineNumber} must replace a non-empty, equal-length whole number of AArch64 instructions.");
            result.Add(new Patch { BuildId = buildId, Offset = offset, Expected = expected,
                                   Replacement = replacement, Reason = fields[4].Trim() });
        }
        return result;
    }

    private static bool IsNso(string path)
    {
        using var f = File.OpenRead(path);
        if (f.Length < 4) return false;
        Span<byte> magic = stackalloc byte[4];
        f.ReadExactly(magic);
        return magic.SequenceEqual("NSO0"u8);
    }

    private static string RewriteOne(string source, string destination, List<Patch> allPatches, out int applied)
    {
        applied = 0;
        byte[] header;
        byte[][] segments = new byte[3][];
        string[] names = { "text", "ro", "data" };
        uint[] fileOffsets = new uint[3], memoryOffsets = new uint[3], sizes = new uint[3], storedSizes = new uint[3];
        uint flags;
        using (var input = File.OpenRead(source))
        {
            if (input.Length < 0x100) throw new InvalidDataException($"{Path.GetFileName(source)}: truncated NSO header.");
            header = new byte[0x100];
            input.ReadExactly(header);
            flags = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0x0c, 4));
            if ((flags & 0x80) != 0) throw new NotSupportedException($"{Path.GetFileName(source)}: ZBIC/zstd NSO compression is not supported.");
            for (int i = 0; i < 3; i++)
            {
                int at = 0x10 + i * 0x10;
                fileOffsets[i] = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(at, 4));
                memoryOffsets[i] = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(at + 4, 4));
                sizes[i] = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(at + 8, 4));
                storedSizes[i] = (flags & (1u << i)) != 0
                    ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0x60 + i * 4, 4))
                    : sizes[i];
                if (sizes[i] > 0x40000000 || (ulong)fileOffsets[i] + storedSizes[i] > (ulong)input.Length)
                    throw new InvalidDataException($"{Path.GetFileName(source)}: invalid {names[i]} segment bounds.");
                input.Position = fileOffsets[i];
                byte[] stored = new byte[checked((int)storedSizes[i])];
                input.ReadExactly(stored);
                segments[i] = (flags & (1u << i)) != 0
                    ? DecodeLz4Block(stored, checked((int)sizes[i]))
                    : stored;
                if (segments[i].Length != sizes[i])
                    throw new InvalidDataException($"{Path.GetFileName(source)}: {names[i]} segment size mismatch.");
                byte[] expectedHash = header.AsSpan(0xA0 + i * 0x20, 0x20).ToArray();
                byte[] actualHash = SHA256.HashData(segments[i]);
                if (!CryptographicOperations.FixedTimeEquals(actualHash, expectedHash))
                    throw new InvalidDataException($"{Path.GetFileName(source)}: {names[i]} SHA-256 failed before rewriting.");
            }
        }

        string buildId = Convert.ToHexString(header.AsSpan(0x40, 0x10)).ToLowerInvariant();
        foreach (Patch patch in allPatches.Where(p => p.BuildId == buildId))
        {
            if (patch.Offset > segments[0].Length - patch.Expected.Length)
                throw new InvalidDataException($"{Path.GetFileName(source)}: patch {patch.Offset:x} extends beyond the text segment.");
            if (!segments[0].AsSpan(patch.Offset, patch.Expected.Length).SequenceEqual(patch.Expected))
                throw new InvalidDataException($"{Path.GetFileName(source)}: original bytes do not match at text+0x{patch.Offset:x}; refusing to patch build {buildId}.");
            patch.Replacement.CopyTo(segments[0], patch.Offset);
            applied++;
        }

        // Rebuild as valid uncompressed NSO. Segment virtual offsets and module build ID stay unchanged.
        uint outputOffset = 0x100;
        for (int i = 0; i < 3; i++)
        {
            outputOffset = Align(outputOffset, 0x10);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0x10 + i * 0x10, 4), outputOffset);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0x60 + i * 4, 4), checked((uint)segments[i].Length));
            byte[] hash = SHA256.HashData(segments[i]);
            hash.CopyTo(header, 0xA0 + i * 0x20);
            outputOffset = checked(outputOffset + (uint)segments[i].Length);
        }
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0x0c, 4), flags & ~0x87u);

        using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            output.Write(header);
            for (int i = 0; i < 3; i++)
            {
                long wanted = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0x10 + i * 0x10, 4));
                while (output.Position < wanted) output.WriteByte(0);
                output.Write(segments[i]);
            }
            output.Flush(true);
        }

        // Verify the exact bytes now on disk, including hashes recorded in the rewritten header.
        using (var verify = File.OpenRead(destination))
        {
            byte[] checkHeader = new byte[0x100];
            verify.ReadExactly(checkHeader);
            if ((BinaryPrimitives.ReadUInt32LittleEndian(checkHeader.AsSpan(0x0c, 4)) & 0x87) != 0)
                throw new InvalidDataException($"{Path.GetFileName(source)}: rewritten compression flags were not cleared.");
            for (int i = 0; i < 3; i++)
            {
                uint off = BinaryPrimitives.ReadUInt32LittleEndian(checkHeader.AsSpan(0x10 + i * 0x10, 4));
                uint len = BinaryPrimitives.ReadUInt32LittleEndian(checkHeader.AsSpan(0x10 + i * 0x10 + 8, 4));
                verify.Position = off;
                byte[] data = new byte[checked((int)len)];
                verify.ReadExactly(data);
                byte[] hash = SHA256.HashData(data);
                if (!CryptographicOperations.FixedTimeEquals(hash, checkHeader.AsSpan(0xA0 + i * 0x20, 0x20)))
                    throw new InvalidDataException($"{Path.GetFileName(source)}: rewritten {names[i]} SHA-256 verification failed.");
            }
        }
        return $"module|{Path.GetFileName(source)}|NSO|{buildId}|rewritten=uncompressed|patches={applied}|sha256=OK";
    }

    private static uint Align(uint value, uint alignment) => checked((value + alignment - 1) & ~(alignment - 1));

    private static byte[] DecodeLz4Block(byte[] source, int expectedLength)
    {
        byte[] destination = new byte[expectedLength];
        int input = 0, output = 0;
        while (input < source.Length)
        {
            byte token = source[input++];
            int literals = token >> 4;
            if (literals == 15)
            {
                byte extension;
                do
                {
                    if (input >= source.Length) throw new InvalidDataException("Truncated LZ4 literal length.");
                    extension = source[input++];
                    literals = checked(literals + extension);
                } while (extension == 255);
            }
            if (literals > source.Length - input || literals > destination.Length - output)
                throw new InvalidDataException("LZ4 literal run exceeds bounds.");
            Buffer.BlockCopy(source, input, destination, output, literals);
            input += literals;
            output += literals;
            if (input == source.Length) break;
            if (input + 2 > source.Length) throw new InvalidDataException("Truncated LZ4 match offset.");
            int offset = source[input] | (source[input + 1] << 8);
            input += 2;
            if (offset <= 0 || offset > output) throw new InvalidDataException("Invalid LZ4 match offset.");
            int match = token & 0x0f;
            if (match == 15)
            {
                byte extension;
                do
                {
                    if (input >= source.Length) throw new InvalidDataException("Truncated LZ4 match length.");
                    extension = source[input++];
                    match = checked(match + extension);
                } while (extension == 255);
            }
            match = checked(match + 4);
            if (match > destination.Length - output) throw new InvalidDataException("LZ4 match exceeds output bounds.");
            for (int j = 0; j < match; j++) destination[output + j] = destination[output - offset + j];
            output += match;
        }
        if (output != expectedLength) throw new InvalidDataException($"LZ4 output size mismatch: expected {expectedLength:x}, got {output:x}.");
        return destination;
    }

    private static int WriteResult(byte* destination, int capacity, string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length + 1 > capacity) return -2;
        Marshal.Copy(bytes, 0, (IntPtr)destination, bytes.Length);
        destination[bytes.Length] = 0;
        return 0;
    }
}
