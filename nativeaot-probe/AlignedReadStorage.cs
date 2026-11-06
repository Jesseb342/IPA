using System;
using LibHac;
using LibHac.Fs;

/// <summary>
/// Reads an update's patched data section through 16-byte aligned windows.
/// LibHac's AES-CTR storage requires aligned offsets; RomFS can request an
/// unaligned header when an update's patch region starts off a sector boundary.
/// </summary>
public class AlignedReadStorage : IStorage
{
    private const int Align = 16;
    private readonly IStorage _base;

    public AlignedReadStorage(IStorage storage) => _base = storage;

    public override Result GetSize(out long size) => _base.GetSize(out size);
    public override Result SetSize(long size) => _base.SetSize(size);
    public override Result Flush() => _base.Flush();
    public override Result Write(long offset, ReadOnlySpan<byte> source) => _base.Write(offset, source);
    public override Result OperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
        => _base.OperateRange(outBuffer, operationId, offset, size, inBuffer);

    public override Result Read(long offset, Span<byte> destination)
    {
        if (destination.Length == 0) return Result.Success;

        Result rc = _base.GetSize(out long size);
        if (rc.IsFailure()) return rc;

        long start = offset & ~(long)(Align - 1);
        long end = (offset + destination.Length + Align - 1) & ~(long)(Align - 1);
        if (end > size) end = size;
        if (end <= start) return LibHac.Fs.ResultFs.OutOfRange.Value;

        byte[] window = new byte[checked((int)(end - start))];
        rc = _base.Read(start, window);
        if (rc.IsFailure()) return rc;

        int skip = checked((int)(offset - start));
        int n = Math.Min(destination.Length, window.Length - skip);
        if (n <= 0) return LibHac.Fs.ResultFs.OutOfRange.Value;
        window.AsSpan(skip, n).CopyTo(destination);
        return Result.Success;
    }
}
