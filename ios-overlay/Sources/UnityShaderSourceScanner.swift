import Foundation

/// Reads the app's indexed DMROMFS1 image without expanding multi-gigabyte game data.
/// This first pass inventories Unity asset containers; it does not decrypt or upload anything.
enum UnityShaderSourceScanner {
    private struct Entry {
        let offset: UInt64
        let length: UInt64
        let nameOffset: UInt32
        let nameLength: UInt16
        let isFile: Bool
    }

    static func scan(preparedDirectory: URL) throws -> String {
        let imageURL = preparedDirectory.appendingPathComponent("RomFS.img")
        let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        let imageSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: imageURL)
        defer { try? handle.close() }

        let header = try read(handle, offset: 0, count: 32)
        guard header.count == 32,
              Array(header.prefix(8)) == Array("DMROMFS1".utf8) else {
            throw ScanError.invalidImage("The extracted RomFS image has an unknown header.")
        }

        let indexOffset = u64(header, 8)
        let indexSize = u64(header, 16)
        let entryCount64 = u64(header, 24)
        guard entryCount64 > 0, entryCount64 <= 2_000_000,
              indexOffset >= 32, indexOffset <= imageSize,
              indexSize == imageSize - indexOffset,
              indexSize <= 256 * 1024 * 1024,
              entryCount64 <= indexSize / 24 else {
            throw ScanError.invalidImage("The RomFS index is outside safe bounds.")
        }

        let index = try read(handle, offset: indexOffset, count: Int(indexSize))
        guard UInt64(index.count) == indexSize else {
            throw ScanError.invalidImage("The RomFS index could not be read completely.")
        }

        let count = Int(entryCount64)
        let poolStart = count * 24
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var names: [String] = []
        names.reserveCapacity(count)

        for i in 0..<count {
            let p = i * 24
            let offset = u64(index, p)
            let length = u64(index, p + 8)
            let nameOffset = u32(index, p + 16)
            let nameLength = u16(index, p + 20)
            let type = index[p + 22]
            guard type <= 1 else { throw ScanError.invalidImage("Invalid entry type at index \(i).") }
            let nameStart = poolStart + Int(nameOffset)
            let nameEnd = nameStart + Int(nameLength)
            guard nameStart >= poolStart, nameEnd >= nameStart, nameEnd <= index.count else {
                throw ScanError.invalidImage("Invalid filename range at index \(i).")
            }
            let nameData = index[nameStart..<nameEnd]
            let name = String(decoding: nameData, as: UTF8.self)
            if i > 0 && (name.isEmpty || name.contains("/") || name == "." || name == "..") {
                throw ScanError.invalidImage("Invalid path component at index \(i).")
            }
            if type == 1 {
                guard offset >= 32, offset <= indexOffset, length <= indexOffset - offset else {
                    throw ScanError.invalidImage("File entry \(i) points outside the image data.")
                }
            } else {
                guard offset <= UInt64(count), length <= UInt64(count) - offset else {
                    throw ScanError.invalidImage("Directory entry \(i) points outside the index.")
                }
            }
            entries.append(Entry(offset: offset, length: length, nameOffset: nameOffset,
                                 nameLength: nameLength, isFile: type == 1))
            names.append(name)
        }

        var fileCount = 0
        var unityFSCount = 0
        var serializedCandidates = 0
        var bundleCandidates = 0
        var report: [String] = [
            "scan|unity_shader_source_inventory",
            "image_bytes|\(imageSize)",
            "index_entries|\(count)",
            "note|Metadata-only scan. Game files remain in Documents/PreparedGame."
        ]
        var visited = Set<Int>()

        func walk(_ directoryIndex: Int, _ prefix: String, _ depth: Int) throws {
            guard depth <= 128, visited.insert(directoryIndex).inserted else {
                throw ScanError.invalidImage("The RomFS directory tree contains a cycle or is too deep.")
            }
            let directory = entries[directoryIndex]
            guard !directory.isFile else { throw ScanError.invalidImage("A file was used as a directory.") }
            let first = Int(directory.offset)
            let end = first + Int(directory.length)
            guard first >= 0, end <= count else { throw ScanError.invalidImage("Directory child range is invalid.") }

            for childIndex in first..<end {
                let child = entries[childIndex]
                let component = names[childIndex]
                let path = prefix.isEmpty ? component : prefix + "/" + component
                if child.isFile {
                    fileCount += 1
                    let lower = path.lowercased()
                    let ext = URL(fileURLWithPath: lower).pathExtension
                    let inData = lower.hasPrefix("data/")
                    let inStreaming = lower.contains("/streamingassets/") || lower.hasPrefix("streamingassets/")
                    let serialized = inData && !inStreaming && ext != "meta"
                    let likelyBundle = inStreaming || ["bundle", "unity3d", "assetbundle"].contains(ext)
                    if serialized {
                        serializedCandidates += 1
                        if serializedCandidates <= 120 {
                            report.append("serialized_candidate|\(path)|bytes=\(child.length)")
                        }
                    }
                    if likelyBundle {
                        bundleCandidates += 1
                        if bundleCandidates <= 120 {
                            report.append("bundle_candidate|\(path)|bytes=\(child.length)")
                        }
                    }

                    // UnityFS magic is checked by reading only eight bytes from each plausible bundle.
                    if (likelyBundle || inData) && child.length >= 8 {
                        let signature = try read(handle, offset: child.offset, count: 8)
                        if signature == Data("UnityFS\0".utf8) {
                            unityFSCount += 1
                            report.append("unityfs_bundle|\(path)|bytes=\(child.length)")
                        }
                    }
                } else {
                    try walk(childIndex, path, depth + 1)
                }
            }
        }

        try walk(0, "", 0)
        report.insert("summary|files=\(fileCount)|serialized_candidates=\(serializedCandidates)|bundle_candidates=\(bundleCandidates)|unityfs_bundles=\(unityFSCount)", at: 3)
        if serializedCandidates > 120 { report.append("serialized_candidates_omitted|\(serializedCandidates - 120)") }
        if bundleCandidates > 120 { report.append("bundle_candidates_omitted|\(bundleCandidates - 120)") }
        if unityFSCount == 0 {
            report.append("unityfs_note|No UnityFS signature was found in the likely bundle paths; serialized Unity files may still contain shaders.")
        }
        let output = report.joined(separator: "\n") + "\n"
        try output.write(to: preparedDirectory.appendingPathComponent("shader-source-scan.txt"),
                         atomically: true, encoding: .utf8)
        return output
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func u16(_ data: Data, _ p: Int) -> UInt16 {
        UInt16(data[p]) | (UInt16(data[p + 1]) << 8)
    }

    private static func u32(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p]) | (UInt32(data[p + 1]) << 8) |
        (UInt32(data[p + 2]) << 16) | (UInt32(data[p + 3]) << 24)
    }

    private static func u64(_ data: Data, _ p: Int) -> UInt64 {
        UInt64(u32(data, p)) | (UInt64(u32(data, p + 4)) << 32)
    }

    private enum ScanError: LocalizedError {
        case invalidImage(String)
        var errorDescription: String? {
            if case .invalidImage(let message) = self { return message }
            return "The Unity asset scan failed."
        }
    }
}
