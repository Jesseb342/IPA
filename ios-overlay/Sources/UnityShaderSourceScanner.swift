import Foundation
import Compression

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
        var unityFSHeaderReports = 0
        let sampleCABURL = preparedDirectory.appendingPathComponent("unityfs-sample-CAB.bin")
        var report: [String] = [
            "unityfs_inspection|lz4_block_info_and_node_inventory",
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
                            if unityFSHeaderReports < 100 {
                                report.append("unityfs_bundle|\(path)|bytes=\(child.length)")
                                let headerData = try read(handle, offset: child.offset, count: min(Int(child.length), 512))
                                if let details = inspectUnityFSHeader(headerData, fileLength: child.length,
                                                                            imageHandle: handle, imageOffset: child.offset,
                                                                            sampleCABURL: unityFSHeaderReports == 0 ? sampleCABURL : nil) {
                                    for detail in details {
                                        if let separator = detail.firstIndex(of: "|") {
                                            let kind = detail[..<separator]
                                            let values = detail[detail.index(after: separator)...]
                                            report.append("\(kind)|\(path)|\(values)")
                                        }
                                    }
                                } else {
                                    report.append("unityfs_header_error|\(path)|header_truncated_or_invalid")
                                }
                                unityFSHeaderReports += 1
                            }
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

    /// Decompresses only UnityFS's small block-info metadata; bundle payload blocks remain untouched.
    private static func inspectUnityFSHeader(_ data: Data, fileLength: UInt64,
                                             imageHandle: FileHandle, imageOffset: UInt64,
                                             sampleCABURL: URL?) -> [String]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == Array("UnityFS\0".utf8) else { return nil }
        var cursor = 8

        func readBE32(_ p: Int) -> UInt32? {
            guard p >= 0, p + 4 <= bytes.count else { return nil }
            return (UInt32(bytes[p]) << 24) | (UInt32(bytes[p + 1]) << 16) |
                   (UInt32(bytes[p + 2]) << 8) | UInt32(bytes[p + 3])
        }
        func readBE64(_ p: Int) -> UInt64? {
            guard p >= 0, p + 8 <= bytes.count else { return nil }
            return (UInt64(bytes[p]) << 56) | (UInt64(bytes[p + 1]) << 48) |
                   (UInt64(bytes[p + 2]) << 40) | (UInt64(bytes[p + 3]) << 32) |
                   (UInt64(bytes[p + 4]) << 24) | (UInt64(bytes[p + 5]) << 16) |
                   (UInt64(bytes[p + 6]) << 8) | UInt64(bytes[p + 7])
        }
        func readCString() -> String? {
            guard cursor < bytes.count else { return nil }
            let start = cursor
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count else { return nil }
            let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
            cursor += 1
            return value
        }
        func safe(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "_")
                 .replacingOccurrences(of: "\n", with: " ")
                 .replacingOccurrences(of: "\r", with: " ")
        }

        guard let format = readBE32(cursor) else { return nil }
        cursor += 4
        guard let playerVersion = readCString(), let engineVersion = readCString(),
              let totalSize = readBE64(cursor) else { return nil }
        cursor += 8
        guard let compressedInfo = readBE32(cursor) else { return nil }
        cursor += 4
        guard let uncompressedInfo = readBE32(cursor) else { return nil }
        cursor += 4
        guard let flags = readBE32(cursor) else { return nil }
        cursor += 4

        let infoAtEnd = (flags & 0x80) != 0
        let compression = flags & 0x3F
        let compressionName: String
        switch compression {
        case 0: compressionName = "none"
        case 1: compressionName = "lzma"
        case 2: compressionName = "lz4"
        case 3: compressionName = "lz4hc"
        default: compressionName = "unknown_\(compression)"
        }
        let headerSize = UInt64(cursor)
        let headerLine = "unityfs_header|format=\(format)|player=\(safe(playerVersion))|engine=\(safe(engineVersion))|total=\(totalSize)|header=\(headerSize)|info_compressed=\(compressedInfo)|info_uncompressed=\(uncompressedInfo)|info_compression=\(compressionName)|info_at_end=\(infoAtEnd)|flags=0x\(String(flags, radix: 16))"
        guard format == 6, totalSize > 0, totalSize <= fileLength,
              UInt64(compressedInfo) <= totalSize,
              uncompressedInfo >= 20, uncompressedInfo <= 16 * 1024 * 1024 else {
            return [headerLine, "unityfs_block_info_error|header_bounds_rejected"]
        }
        let infoOffset = infoAtEnd ? totalSize - UInt64(compressedInfo) : headerSize
        let dataOffset = infoAtEnd ? headerSize : headerSize + UInt64(compressedInfo)
        guard infoOffset <= totalSize, UInt64(compressedInfo) <= totalSize - infoOffset,
              dataOffset <= totalSize, imageOffset <= UInt64.max - infoOffset else {
            return [headerLine, "unityfs_block_info_error|metadata_offsets_out_of_bounds"]
        }

        let packed = try? read(imageHandle, offset: imageOffset + infoOffset, count: Int(compressedInfo))
        guard let packed, packed.count == Int(compressedInfo) else {
            return [headerLine, "unityfs_block_info_error|metadata_read_incomplete"]
        }
        let decoded: Data
        switch compression {
        case 0:
            guard packed.count == Int(uncompressedInfo) else {
                return [headerLine, "unityfs_block_info_error|uncompressed_size_mismatch"]
            }
            decoded = packed
        case 2, 3:
            // UnityFS stores a bare LZ4 block; Apple's framed COMPRESSION_LZ4 is incompatible.
            var output = Data(count: Int(uncompressedInfo))
            let decodedCount = output.withUnsafeMutableBytes { destination in
                packed.withUnsafeBytes { source in
                    guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                          let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dst, Int(uncompressedInfo), src,
                                                      Int(compressedInfo), nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard decodedCount == Int(uncompressedInfo) else {
                return [headerLine, "unityfs_block_info_error|lz4_decode_failed_returned_\(decodedCount)_expected_\(uncompressedInfo)"]
            }
            decoded = output
        default:
            return [
                "unityfs_header|format=\(format)|player=\(safe(playerVersion))|engine=\(safe(engineVersion))|total=\(totalSize)|header=\(headerSize)|info_compressed=\(compressedInfo)|info_uncompressed=\(uncompressedInfo)|info_compression=\(compressionName)|info_at_end=\(infoAtEnd)|info_offset=\(infoOffset)|data_offset=\(dataOffset)|flags=0x\(String(flags, radix: 16))",
                "unityfs_block_info_error|unsupported_compression_\(compressionName)"
            ]
        }

        let metadata = [UInt8](decoded)
        func metaBE32(_ p: Int) -> UInt32? {
            guard p >= 0, p + 4 <= metadata.count else { return nil }
            return (UInt32(metadata[p]) << 24) | (UInt32(metadata[p + 1]) << 16) |
                   (UInt32(metadata[p + 2]) << 8) | UInt32(metadata[p + 3])
        }
        func metaBE64(_ p: Int) -> UInt64? {
            guard p >= 0, p + 8 <= metadata.count else { return nil }
            return (UInt64(metadata[p]) << 56) | (UInt64(metadata[p + 1]) << 48) |
                   (UInt64(metadata[p + 2]) << 40) | (UInt64(metadata[p + 3]) << 32) |
                   (UInt64(metadata[p + 4]) << 24) | (UInt64(metadata[p + 5]) << 16) |
                   (UInt64(metadata[p + 6]) << 8) | UInt64(metadata[p + 7])
        }
        guard let blockCountRaw = metaBE32(16), blockCountRaw <= 100_000 else {
            return [headerLine, "unityfs_block_info_error|invalid_block_count_or_metadata_prefix"]
        }
        let blockCount = Int(blockCountRaw)
        var position = 20
        guard blockCount <= (metadata.count - position) / 10 else {
            return [headerLine, "unityfs_block_info_error|block_table_exceeds_metadata"]
        }
        var totalUncompressed: UInt64 = 0
        var blockRecords: [(unpacked: UInt32, packed: UInt32, flags: UInt16)] = []
        blockRecords.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            guard let unpacked = metaBE32(position), let packed = metaBE32(position + 4),
                  position + 10 <= metadata.count else {
                return [headerLine, "unityfs_block_info_error|truncated_block_table"]
            }
            let blockFlags = UInt16(metadata[position + 8]) << 8 | UInt16(metadata[position + 9])
            blockRecords.append((unpacked: unpacked, packed: packed, flags: blockFlags))
            totalUncompressed += UInt64(unpacked)
            guard totalUncompressed <= totalSize * 64 else {
                return [headerLine, "unityfs_block_info_error|uncompressed_total_implausible"]
            }
            position += 10
        }
        guard let nodeCountRaw = metaBE32(position), nodeCountRaw <= 200_000 else {
            return [headerLine, "unityfs_block_info_error|invalid_node_count"]
        }
        position += 4
        let nodeCount = Int(nodeCountRaw)
        var lines = [
            "unityfs_header|format=\(format)|player=\(safe(playerVersion))|engine=\(safe(engineVersion))|total=\(totalSize)|header=\(headerSize)|info_compressed=\(compressedInfo)|info_uncompressed=\(uncompressedInfo)|info_compression=\(compressionName)|info_at_end=\(infoAtEnd)|info_offset=\(infoOffset)|data_offset=\(dataOffset)|flags=0x\(String(flags, radix: 16))",
            "unityfs_block_info|blocks=\(blockCount)|nodes=\(nodeCount)|uncompressed_data=\(totalUncompressed)"
        ]
        var emitted = 0
        var primaryNode: (offset: UInt64, size: UInt64, path: String)?
        for _ in 0..<nodeCount {
            guard let nodeOffset = metaBE64(position), let nodeSize = metaBE64(position + 8),
                  let nodeFlags = metaBE32(position + 16) else {
                return [headerLine, "unityfs_block_info_error|truncated_node_record"]
            }
            position += 20
            guard nodeOffset <= totalUncompressed, nodeSize <= totalUncompressed - nodeOffset else {
                return [headerLine, "unityfs_block_info_error|node_range_out_of_bounds"]
            }
            guard position < metadata.count else {
                return [headerLine, "unityfs_block_info_error|missing_node_path"]
            }
            let nameStart = position
            while position < metadata.count && metadata[position] != 0 { position += 1 }
            guard position < metadata.count else {
                return [headerLine, "unityfs_block_info_error|unterminated_node_path"]
            }
            let nodePath = safe(String(decoding: metadata[nameStart..<position], as: UTF8.self))
            position += 1
            if primaryNode == nil && !nodePath.hasSuffix(".resS") {
                primaryNode = (nodeOffset, nodeSize, nodePath)
            }
            if emitted < 16 {
                lines.append("unityfs_node|path=\(nodePath)|offset=\(nodeOffset)|size=\(nodeSize)|flags=0x\(String(nodeFlags, radix: 16))")
                emitted += 1
            }
        }
        if nodeCount > emitted { lines.append("unityfs_nodes_omitted|\(nodeCount - emitted)") }
        if let sampleCABURL, let primaryNode,
           primaryNode.offset == 0, primaryNode.size > 0, primaryNode.size <= 32 * 1024 * 1024 {
            do {
                let sample = try extractUnityFSNode(primaryNode.offset, size: primaryNode.size,
                                                    blocks: blockRecords, dataOffset: dataOffset,
                                                    fileLength: fileLength, imageHandle: imageHandle,
                                                    imageOffset: imageOffset)
                try sample.write(to: sampleCABURL, options: .atomic)
                let signature = String(decoding: sample.prefix(8), as: UTF8.self)
                let hex = sample.prefix(32).map { String(format: "%02x", $0) }.joined()
                lines.append("unityfs_sample_cab|path=\(primaryNode.path)|bytes=\(sample.count)|signature=\(signature)|first32=\(hex)")
            } catch {
                lines.append("unityfs_sample_cab_error|\(String(describing: error).replacingOccurrences(of: "|", with: "_"))")
            }
        }
        return lines
    }

    private static func extractUnityFSNode(_ nodeOffset: UInt64, size: UInt64,
                                           blocks: [(unpacked: UInt32, packed: UInt32, flags: UInt16)],
                                           dataOffset: UInt64, fileLength: UInt64,
                                           imageHandle: FileHandle, imageOffset: UInt64) throws -> Data {
        guard size <= 32 * 1024 * 1024, dataOffset <= fileLength,
              imageOffset <= UInt64.max - dataOffset else {
            throw ScanError.invalidImage("Sample CAB extraction bounds are invalid.")
        }
        let nodeEnd = nodeOffset + size
        guard nodeEnd >= nodeOffset else { throw ScanError.invalidImage("Sample CAB range overflowed.") }
        var logicalOffset: UInt64 = 0
        var compressedOffset = dataOffset
        var result = Data()
        result.reserveCapacity(Int(size))
        for block in blocks {
            let unpackedSize = UInt64(block.unpacked)
            let packedSize = UInt64(block.packed)
            guard logicalOffset <= UInt64.max - unpackedSize,
                  compressedOffset <= fileLength, packedSize <= fileLength - compressedOffset,
                  imageOffset <= UInt64.max - compressedOffset else {
                throw ScanError.invalidImage("UnityFS sample block exceeds bundle bounds.")
            }
            let blockEnd = logicalOffset + unpackedSize
            if blockEnd > nodeOffset && logicalOffset < nodeEnd {
                guard unpackedSize > 0, unpackedSize <= 32 * 1024 * 1024,
                      packedSize > 0, packedSize <= 32 * 1024 * 1024 else {
                    throw ScanError.invalidImage("UnityFS sample block size is unsafe.")
                }
                let packed = try read(imageHandle, offset: imageOffset + compressedOffset, count: Int(packedSize))
                guard packed.count == Int(packedSize) else {
                    throw ScanError.invalidImage("UnityFS sample block could not be read completely.")
                }
                let compression = block.flags & 0x3F
                let decoded: Data
                if compression == 0 {
                    guard packed.count == Int(unpackedSize) else {
                        throw ScanError.invalidImage("Uncompressed UnityFS block size mismatch.")
                    }
                    decoded = packed
                } else if compression == 2 || compression == 3 {
                    var output = Data(count: Int(unpackedSize))
                    let decodedCount = output.withUnsafeMutableBytes { destination in
                        packed.withUnsafeBytes { source in
                            guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                                  let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                            return compression_decode_buffer(dst, Int(unpackedSize), src,
                                                              Int(packedSize), nil, COMPRESSION_LZ4_RAW)
                        }
                    }
                    guard decodedCount == Int(unpackedSize) else {
                        throw ScanError.invalidImage("UnityFS raw LZ4 block decode failed.")
                    }
                    decoded = output
                } else {
                    throw ScanError.invalidImage("Unsupported UnityFS sample block compression \(compression).")
                }
                let overlapStart = max(nodeOffset, logicalOffset)
                let overlapEnd = min(nodeEnd, blockEnd)
                let start = Int(overlapStart - logicalOffset)
                let end = Int(overlapEnd - logicalOffset)
                result.append(decoded.subdata(in: start..<end))
                if UInt64(result.count) == size { break }
            }
            logicalOffset = blockEnd
            compressedOffset += packedSize
        }
        guard UInt64(result.count) == size else {
            throw ScanError.invalidImage("Sample CAB extraction was incomplete (\(result.count)/\(size) bytes).")
        }
        return result
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
