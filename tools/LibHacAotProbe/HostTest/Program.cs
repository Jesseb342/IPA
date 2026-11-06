using System;
using System.IO;
using System.Linq;

if (args.Length != 4)
{
    Console.Error.WriteLine("Usage: LibHacHostTest <prod.keys> <base.nsp> <output-romfs> <required-marker>");
    return 2;
}

string keys = Path.GetFullPath(args[0]);
string nsp = Path.GetFullPath(args[1]);
string output = Path.GetFullPath(args[2]);
string marker = args[3].Replace('/', Path.DirectorySeparatorChar);

Console.WriteLine("Starting LibHac base-NSP extraction.");
ParaboxExtractor.ExtractBaseRomFsManaged(keys, nsp, output);

string markerPath = Path.Combine(output, marker);
if (!File.Exists(markerPath))
{
    Console.Error.WriteLine($"Extraction completed, but the expected Parabox RomFS marker is missing: {marker}");
    return 3;
}

var files = Directory.EnumerateFiles(output, "*", SearchOption.AllDirectories).ToArray();
long bytes = files.Sum(path => new FileInfo(path).Length);
Console.WriteLine($"Validated marker: {marker}");
Console.WriteLine($"Extracted {files.Length:N0} files ({bytes:N0} bytes).");
Console.WriteLine("LibHac extraction test passed.");
return 0;
