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
        var directSerializedScans = 0
        var directSerializedBytes: UInt64 = 0
        var bundleCandidates = 0
        var unityFSHeaderReports = 0
        let sampleCABURLs = [
            "atlas_player": preparedDirectory.appendingPathComponent("unityfs-sample-atlas-player-CAB.bin"),
            "atlas_baronesslevel": preparedDirectory.appendingPathComponent("unityfs-sample-atlas-baronesslevel-CAB.bin"),
            "atlas_beelevel": preparedDirectory.appendingPathComponent("unityfs-sample-atlas-beelevel-CAB.bin")
        ]
        var shaderForensicBudgetRemaining = 32 * 1024 * 1024
        var report: [String] = [
            "unityfs_scanner_revision|unity2017-shader-blob-table-probe-v8",
            "unityfs_inspection|lz4_block_info_and_node_inventory",
            "scan|unity_shader_source_inventory",
            "image_bytes|\(imageSize)",
            "index_entries|\(count)",
            "note|Bounded local shader-object inspection. No game files or keys leave Documents/PreparedGame."
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

                        // Inspect main Unity SerializedFiles in addition to AssetBundle CABs.
                        // Only read bounded files after confirming the format-17 header.
                        // Prioritize the shared shader libraries before individual level files.
                        // The 64-file cap was previously consumed by level0...level64, so
                        // resources.assets and sharedassets*.assets were never reached.
                        let highValue = lower == "data/resources.assets" ||
                            lower == "data/globalgamemanagers.assets" ||
                            lower == "data/globalgamemanagers" ||
                            lower.range(of: #"data/sharedassets[0-9]+\.assets$"#, options: .regularExpression) != nil
                        if highValue && directSerializedScans < 160 &&
                            child.length >= 24 && child.length <= 32 * 1024 * 1024 &&
                            directSerializedBytes <= 512 * 1024 * 1024 - child.length {
                            let prefix = try read(handle, offset: child.offset, count: 16)
                            if prefix.count == 16 && readBE32(Array(prefix), 8) == 17 {
                                let serializedData = try read(handle, offset: child.offset, count: Int(child.length))
                                if UInt64(serializedData.count) == child.length {
                                    directSerializedScans += 1
                                    directSerializedBytes += child.length
                                    report.append("unity_serialized_direct|\(path)|bytes=\(child.length)")
                                    report.append(contentsOf: inspectSerializedFileHeader(serializedData).map { "unity_serialized_source|\(path)|\($0)" })
                                    // Extract every discovered Shader object across serialized assets.
                                    // A single 32 MiB budget is shared across the entire scan.
                                    let objectDirectoryURL = preparedDirectory
                                        .appendingPathComponent("ShaderSources", isDirectory: true)
                                    let objectFilePrefix = lower
                                        .replacingOccurrences(of: "/", with: "-")
                                        .replacingOccurrences(of: ".", with: "-")
                                    report.append(contentsOf: try inspectSerializedFileMetadata(
                                        serializedData,
                                        inspectAllShaderObjects: true,
                                        outputDirectoryURL: objectDirectoryURL,
                                        outputFilePrefix: objectFilePrefix,
                                        forensicBudgetRemaining: &shaderForensicBudgetRemaining
                                    ).map { "unity_serialized_source|\(path)|\($0)" })
                                } else {
                                    report.append("unity_serialized_direct_error|\(path)|read_incomplete")
                                }
                            }
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
                            if unityFSHeaderReports < 400 {
                                report.append("unityfs_bundle|\(path)|bytes=\(child.length)")
                                let headerData = try read(handle, offset: child.offset, count: min(Int(child.length), 512))
                                if let details = inspectUnityFSHeader(headerData, fileLength: child.length,
                                                                            imageHandle: handle, imageOffset: child.offset,
                                                                            sampleCABURL: sampleCABURLs.first(where: { lower.contains("/\($0.key)/") || lower.hasSuffix("/\($0.key)") })?.value) {
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
        report.insert("summary|files=\(fileCount)|serialized_candidates=\(serializedCandidates)|bundle_candidates=\(bundleCandidates)|unityfs_bundles=\(unityFSCount)|direct_serialized_scans=\(directSerializedScans)|direct_serialized_bytes=\(directSerializedBytes)", at: 3)
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
        let headerLine = "unityfs_header|format=\(format)|player=\(safe(playerVersion))|engine=\(safe(engineVersion))|total=\(totalSize)|header=\(headerSize)|info_compressed=\(compressedInfo)|info_uncompressed=\(uncompressedInfo)|info_compression=\(compressionName)|info_at_end=\(infoAtEnd)|info_offset=\(infoAtEnd ? totalSize - UInt64(compressedInfo) : headerSize)|data_offset=\(infoAtEnd ? headerSize : headerSize + UInt64(compressedInfo))|flags=0x\(String(flags, radix: 16))"
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
                let prefix = packed.prefix(24).map { String(format: "%02x", $0) }.joined()
                return [headerLine, "unityfs_block_info_error|lz4_decode_failed_returned_\(decodedCount)_expected_\(uncompressedInfo)|packed_prefix=\(prefix)|packed_bytes=\(packed.count)"]
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
                lines.append(contentsOf: inspectSerializedFileHeader(sample))
                var sampleForensicBudget = 0
                lines.append(contentsOf: try inspectSerializedFileMetadata(sample, forensicBudgetRemaining: &sampleForensicBudget))
            } catch {
                lines.append("unityfs_sample_cab_error|\(String(describing: error).replacingOccurrences(of: "|", with: "_"))")
            }
        }
        return lines
    }

    /// Validates the Unity SerializedFile header from the extracted CAB sample.
    /// This deliberately stops before type-tree/object parsing until the exact 2017 layout is confirmed.
    private static func inspectSerializedFileHeader(_ data: Data) -> [String] {
        func be32(_ p: Int) -> UInt32? {
            guard p >= 0, p + 4 <= data.count else { return nil }
            return (UInt32(data[p]) << 24) | (UInt32(data[p + 1]) << 16) |
                   (UInt32(data[p + 2]) << 8) | UInt32(data[p + 3])
        }
        guard data.count >= 24,
              let metadataSize = be32(0),
              let fileSize = be32(4),
              let formatVersion = be32(8),
              let dataOffset = be32(12) else {
            return ["unity_serialized_header_error|header_too_short"]
        }
        let endian = data[16]
        guard formatVersion >= 9, formatVersion <= 22,
              fileSize == data.count,
              metadataSize > 0, metadataSize <= fileSize,
              dataOffset >= 20, dataOffset <= fileSize,
              metadataSize <= dataOffset else {
            return ["unity_serialized_header_error|bounds_or_version_invalid|metadata=\(metadataSize)|file=\(fileSize)|format=\(formatVersion)|data_offset=\(dataOffset)|actual=\(data.count)"]
        }
        let versionStart = 20
        guard let terminator = data[versionStart...].firstIndex(of: 0), terminator > versionStart,
              terminator - versionStart <= 64 else {
            return ["unity_serialized_header_error|unity_version_string_missing"]
        }
        let unityVersion = String(decoding: data[versionStart..<terminator], as: UTF8.self)
        let prefix = data.prefix(min(48, data.count)).map { String(format: "%02x", $0) }.joined()
        let candidateMetadataStart = dataOffset - metadataSize
        return [
            "unity_serialized_header|format=\(formatVersion)|file_bytes=\(fileSize)|metadata_bytes=\(metadataSize)|data_offset=\(dataOffset)|endian=\(endian)|unity_version=\(unityVersion)|metadata_start_candidate=\(candidateMetadataStart)|header_prefix=\(prefix)",
            "unity_serialized_header_check|file_size_matches=true|supported_format_range=true|unity_version_string=true"
        ]
    }

    /// Reads version-17 metadata and can extract a bounded set of Shader objects for local comparison.
    private static func inspectSerializedFileMetadata(
        _ data: Data,
        inspectObjectIndices: Set<Int>? = nil,
        inspectAllShaderObjects: Bool = false,
        outputDirectoryURL: URL? = nil,
        outputFilePrefix: String = "serialized",
        forensicBudgetRemaining: inout Int
    ) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 24,
              readBE32(bytes, 8) == 17,
              bytes[16] == 0 else {
            return ["unity_serialized_metadata_error|requires_format_17_little_endian"]
        }

        guard let serializedDataOffset = readBE32(bytes, 12), Int(serializedDataOffset) <= bytes.count else {
            return ["unity_serialized_metadata_error|invalid_serialized_data_offset"]
        }
        var cursor = 20
        func readLE32(_ position: Int) -> UInt32? {
            guard position >= 0, position + 4 <= bytes.count else { return nil }
            return UInt32(bytes[position]) | (UInt32(bytes[position + 1]) << 8) |
                   (UInt32(bytes[position + 2]) << 16) | (UInt32(bytes[position + 3]) << 24)
        }
        func readLE16(_ position: Int) -> UInt16? {
            guard position >= 0, position + 2 <= bytes.count else { return nil }
            return UInt16(bytes[position]) | (UInt16(bytes[position + 1]) << 8)
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
        guard let unityVersion = readCString(),
              let targetRaw = readLE32(cursor) else {
            return ["unity_serialized_metadata_error|truncated_version_or_platform"]
        }
        cursor += 4
        guard cursor < bytes.count else {
            return ["unity_serialized_metadata_error|missing_type_tree_flag"]
        }
        let hasTypeTree = bytes[cursor] != 0
        cursor += 1
        guard let typeCountRaw = readLE32(cursor) else {
            return ["unity_serialized_metadata_error|missing_type_count"]
        }
        cursor += 4
        let typeCount = Int(Int32(bitPattern: typeCountRaw))
        guard typeCount >= 0, typeCount <= 100_000 else {
            return ["unity_serialized_metadata_error|invalid_type_count_\(typeCount)"]
        }

        var classIDs: [Int32] = []
        classIDs.reserveCapacity(typeCount)
        var shaderTypes = 0
        for _ in 0..<typeCount {
            guard let classRaw = readLE32(cursor), cursor + 7 <= bytes.count else {
                return ["unity_serialized_metadata_error|truncated_type_entry"]
            }
            let classID = Int32(bitPattern: classRaw)
            classIDs.append(classID)
            if classID == 48 { shaderTypes += 1 }
            cursor += 4
            cursor += 1 // stripped flag
            guard readLE16(cursor) != nil else {
                return ["unity_serialized_metadata_error|truncated_script_type_index"]
            }
            cursor += 2
            if classID == 114 {
                guard cursor + 16 <= bytes.count else {
                    return ["unity_serialized_metadata_error|truncated_mono_script_hash"]
                }
                cursor += 16
            }
            guard cursor + 16 <= bytes.count else {
                return ["unity_serialized_metadata_error|truncated_type_hash"]
            }
            cursor += 16

            if hasTypeTree {
                guard let nodeCountRaw = readLE32(cursor),
                      let stringSizeRaw = readLE32(cursor + 4) else {
                    return ["unity_serialized_metadata_error|truncated_type_tree_header"]
                }
                cursor += 8
                let nodeCount = Int(Int32(bitPattern: nodeCountRaw))
                let stringSize = Int(Int32(bitPattern: stringSizeRaw))
                guard nodeCount >= 0, nodeCount <= 500_000,
                      stringSize >= 0, stringSize <= 16 * 1024 * 1024 else {
                    return ["unity_serialized_metadata_error|unsafe_type_tree_size"]
                }
                let nodeBytes = nodeCount.multipliedReportingOverflow(by: 24)
                guard !nodeBytes.overflow,
                      cursor <= bytes.count,
                      nodeBytes.partialValue <= bytes.count - cursor,
                      stringSize <= bytes.count - cursor - nodeBytes.partialValue else {
                    return ["unity_serialized_metadata_error|type_tree_exceeds_file_bounds"]
                }
                cursor += nodeBytes.partialValue + stringSize
            }
        }

        // Format 17 is newer than Unknown_14. The legacy big-ID field
        // exists only in formats 7 through 13. Format 17 starts its object
        // table immediately after the type table and uses aligned Int64 pathIDs.
        let format17Uses64BitPathID = true
        let objectCountOffset = cursor
        guard let objectCountRaw = readLE32(objectCountOffset) else {
            return ["unity_serialized_metadata_error|missing_object_count|offset=\(objectCountOffset)"]
        }
        cursor += 4
        let objectCount = Int(Int32(bitPattern: objectCountRaw))
        guard objectCount >= 0, objectCount <= 2_000_000 else {
            return ["unity_serialized_metadata_error|invalid_object_count_\(objectCount)"]
        }

        var shaderObjects = 0
        var shaderSamples: [String] = []
        var forensicReports: [String] = []
        var extractedObjectIndices = Set<Int>()
        var extractedObjectBytes = 0
        let maximumForensicBytes = 32 * 1024 * 1024
        for objectIndex in 0..<objectCount {
            if format17Uses64BitPathID { cursor = (cursor + 3) & ~3 }
            let pathIDWidth = format17Uses64BitPathID ? 8 : 4
            let recordBytes = pathIDWidth + 12
            guard cursor >= 0, cursor <= bytes.count, recordBytes <= bytes.count - cursor,
                  let startRaw = readLE32(cursor + pathIDWidth),
                  let sizeRaw = readLE32(cursor + pathIDWidth + 4),
                  let typeRaw = readLE32(cursor + pathIDWidth + 8) else {
                return ["unity_serialized_metadata_error|truncated_object_table"]
            }
            let typeIndex = Int(Int32(bitPattern: typeRaw))
            guard typeIndex >= 0, typeIndex < classIDs.count else {
                return ["unity_serialized_metadata_error|object_type_index_out_of_range"]
            }
            let classID = classIDs[typeIndex]
            if classID == 48 {
                shaderObjects += 1
                let absoluteStart = UInt64(serializedDataOffset) + UInt64(startRaw)
                let absoluteEnd = absoluteStart + UInt64(sizeRaw)
                guard absoluteEnd >= absoluteStart, absoluteEnd <= UInt64(bytes.count) else {
                    return ["unity_serialized_metadata_error|shader_object_range_out_of_bounds|object_index=\(objectIndex)"]
                }
                shaderSamples.append("shader_object_candidate|object_index=\(objectIndex)|object_byte_start=\(startRaw)|file_offset=\(absoluteStart)|bytes=\(sizeRaw)|type_index=\(typeIndex)")
                if inspectAllShaderObjects || inspectObjectIndices?.contains(objectIndex) == true {
                    guard let outputDirectoryURL, sizeRaw > 0, sizeRaw <= 16 * 1024 * 1024,
                          Int(sizeRaw) <= forensicBudgetRemaining,
                          extractedObjectBytes <= maximumForensicBytes - Int(sizeRaw) else {
                        return ["shader_object_forensic_error|object_\(objectIndex)_exceeds_safe_extraction_budget"]
                    }
                    let objectData = data.subdata(in: Int(absoluteStart)..<Int(absoluteEnd))
                    try FileManager.default.createDirectory(
                        at: outputDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    let outputURL = outputDirectoryURL.appendingPathComponent(
                        "\(outputFilePrefix)-shader-object-\(objectIndex).bin"
                    )
                    try objectData.write(to: outputURL, options: .atomic)
                    forensicReports.append(contentsOf: inspectShaderObjectBytes(
                        objectData, objectIndex: objectIndex, outputURL: outputURL
                    ))
                    extractedObjectIndices.insert(objectIndex)
                    extractedObjectBytes += objectData.count
                    forensicBudgetRemaining -= objectData.count
                }
            }
            cursor += recordBytes
        }

        var result = [
            "unity_serialized_metadata|unity_version=\(unityVersion)|target_platform=\(Int32(bitPattern: targetRaw))|type_tree=\(hasTypeTree)|types=\(typeCount)|objects=\(objectCount)|object_count_offset=\(objectCountOffset)|format17_path_id_bytes=\(format17Uses64BitPathID ? 8 : 4)|shader_types=\(shaderTypes)|shader_objects=\(shaderObjects)",
            "unity_serialized_metadata_check|type_table_bounds=true|object_table_bounds=true|object_count_unaligned=true|format=17|path_id_layout_checked=true"
        ]
        result.append(contentsOf: shaderSamples)
        if inspectAllShaderObjects || inspectObjectIndices != nil {
            let requestedCount = inspectAllShaderObjects ? shaderObjects : (inspectObjectIndices?.count ?? 0)
            result.append("shader_object_batch_summary|requested=\(requestedCount)|extracted=\(extractedObjectIndices.count)|bytes=\(extractedObjectBytes)|global_budget_remaining=\(forensicBudgetRemaining)|local_only=true")
            result.append(contentsOf: forensicReports)
            if let inspectObjectIndices {
                for missingIndex in inspectObjectIndices.subtracting(extractedObjectIndices).sorted() {
                    result.append("shader_object_forensic_error|object_index_\(missingIndex)_not_found_as_shader")
                }
            }
        }
        if shaderObjects == 0 {
            result.append("unity_shader_note|No Shader class objects were present in this SerializedFile.")
        }
        return result
    }

    /// Produces a bounded structural inventory of one raw Unity Shader object.
    /// String hits are clues only; they are not claimed to be executable programs.
    private static func inspectShaderObjectBytes(_ data: Data, objectIndex: Int, outputURL: URL) -> [String] {
        let bytes = [UInt8](data)
        let preview = bytes.prefix(64).map { String(format: "%02x", $0) }.joined()
        let markers = ["SubProgram", "m_Program", "m_Programs", "GpuProgram", "ShaderBlob",
                       "SerializedShader", "m_ParsedForm", "keywords", "Keywords", "Pass",
                       "Vertex", "Fragment", "Compute", "Metal", "GLSL", "SPIR-V"]
        var markerOffsets: [String: [Int]] = [:]
        var markerCounts: [String: Int] = [:]
        var strings: [(offset: Int, value: String)] = []
        var distributedSamples: [(offset: Int, value: String)] = []
        var tailStrings: [(offset: Int, value: String)] = []
        let sampleInterval = max(bytes.count / 16, 1)
        var nextSampleOffset = 0
        var totalStrings = 0
        var cursor = 0

        // Scan the entire object, not just its first 160 strings. The first part
        // of a Unity Shader object is often property metadata; executable program
        // records can occur much later in a multi-megabyte object.
        while cursor < bytes.count {
            if bytes[cursor] >= 0x20 && bytes[cursor] <= 0x7e {
                let start = cursor
                while cursor < bytes.count && bytes[cursor] >= 0x20 && bytes[cursor] <= 0x7e {
                    cursor += 1
                }
                if cursor - start >= 4 {
                    let value = String(bytes: bytes[start..<cursor], encoding: .ascii) ?? ""
                    totalStrings += 1
                    if strings.count < 64 {
                        strings.append((start, value))
                    }
                    if distributedSamples.count < 16 && start >= nextSampleOffset {
                        distributedSamples.append((start, value))
                        nextSampleOffset = start + sampleInterval
                    }
                    tailStrings.append((start, value))
                    if tailStrings.count > 16 {
                        tailStrings.removeFirst()
                    }
                    for marker in markers where value.localizedCaseInsensitiveContains(marker) {
                        markerCounts[marker, default: 0] += 1
                        if markerOffsets[marker, default: []].count < 16 {
                            markerOffsets[marker, default: []].append(start)
                        }
                    }
                }
            } else {
                cursor += 1
            }
        }

        let markerLines = markers.compactMap { marker -> String? in
            guard let hits = markerCounts[marker], hits > 0 else { return nil }
            let offsets = markerOffsets[marker, default: []]
            return "shader_object_marker|\(marker)|hits=\(hits)|sample_offsets=\(offsets.map { String($0) }.joined(separator: ","))"
        }

        // Unity shader objects can store compiled programs as opaque binary blobs.
        // Search for common container signatures independently of printable strings.
        let signatures: [(name: String, bytes: [UInt8])] = [
            ("SPIRV", [0x03, 0x02, 0x23, 0x07]),
            ("DXBC", [0x44, 0x58, 0x42, 0x43]),
            ("MTLB", [0x4d, 0x54, 0x4c, 0x42]),
            ("DXIL", [0x44, 0x58, 0x49, 0x4c]),
            ("SHDR", [0x53, 0x48, 0x44, 0x52])
        ]
        var signatureLines: [String] = []
        for signature in signatures {
            var offsets: [Int] = []
            if bytes.count >= signature.bytes.count {
                for position in 0...(bytes.count - signature.bytes.count) {
                    if Array(bytes[position..<(position + signature.bytes.count)]) == signature.bytes {
                        if offsets.count < 16 { offsets.append(position) }
                    }
                }
            }
            signatureLines.append("shader_object_binary_signature|\(signature.name)|hits=\(offsets.count)|offsets=\(offsets.map { String($0) }.joined(separator: ","))")
        }

        let zeroBytes = bytes.reduce(into: 0) { if $1 == 0 { $0 += 1 } }
        let printableBytes = bytes.reduce(into: 0) { if $1 >= 0x20 && $1 <= 0x7e { $0 += 1 } }
        let binarySummary = "shader_object_byte_profile|zero=\(zeroBytes)|printable_ascii=\(printableBytes)|non_ascii_or_control=\(bytes.count - zeroBytes - printableBytes)"
        func safeString(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "_")
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\r", with: " ")
        }
        let stringLines = strings.prefix(16).map { item in
            "shader_object_ascii|offset=\(item.offset)|text=\(safeString(item.value).prefix(120))"
        }
        let distributedLines = distributedSamples.map { item in
            "shader_object_ascii_sample|offset=\(item.offset)|text=\(safeString(item.value).prefix(120))"
        }
        let tailLines = tailStrings.suffix(16).map { item in
            "shader_object_ascii_tail|offset=\(item.offset)|text=\(safeString(item.value).prefix(120))"
        }
        let programLines = inspectSerializedShaderProgramBlob(data, objectIndex: objectIndex, outputURL: outputURL)
        return [
            "shader_object_forensic|object_index=\(objectIndex)|bytes=\(bytes.count)|raw_file=\(outputURL.lastPathComponent)",
            "shader_object_prefix_hex|\(preview)",
            "shader_object_ascii_summary|total_strings_scanned=\(totalStrings)|stored_first=\(strings.count)|reported=\(min(strings.count, 16))|distributed_samples=\(distributedSamples.count)|tail_samples=\(tailStrings.count)"
        ] + [binarySummary] + signatureLines + markerLines + stringLines + distributedLines + tailLines + programLines
    }

    /// Finds the Unity 5.5–2019 Shader tail arrays used by Unity 2017.4:
    /// platforms[], offsets[], compressedLengths[], decompressedLengths[], compressedBlob[].
    /// A candidate is accepted only when all counts agree, every range is in-bounds,
    /// and at least one raw-LZ4 chunk decodes to a plausible SerializedProgram header.
    private static func inspectSerializedShaderProgramBlob(_ data: Data, objectIndex: Int, outputURL: URL) -> [String] {
        let bytes = [UInt8](data)
        func le32(_ p: Int) -> UInt32? {
            guard p >= 0, p <= bytes.count - 4 else { return nil }
            return UInt32(bytes[p]) | (UInt32(bytes[p + 1]) << 8) |
                (UInt32(bytes[p + 2]) << 16) | (UInt32(bytes[p + 3]) << 24)
        }
        func boundedCount(_ value: UInt32?, maximum: Int) -> Int? {
            guard let value, value > 0, value <= UInt32(maximum) else { return nil }
            return Int(value)
        }

        var accepted: [String] = []
        let outputDirectory = outputURL.deletingLastPathComponent()
            .appendingPathComponent("ShaderPrograms", isDirectory: true)
        let maximumCandidateCount = 32
        let maximumDecodedBytes = 32 * 1024 * 1024
        var candidatesChecked = 0
        let maximumCandidatesToDecode = 32

        guard bytes.count >= 24 else {
            return ["shader_program_blob_layout|object_index=\(objectIndex)|status=object_too_small"]
        }

        for start in 0...(bytes.count - 4) {
            guard let platformCount = boundedCount(le32(start), maximum: maximumCandidateCount) else { continue }
            let platformsStart = start + 4
            let platformsEnd = platformsStart + platformCount * 4
            guard platformsEnd <= bytes.count else { continue }

            var platforms: [Int32] = []
            var validPlatforms = true
            for i in 0..<platformCount {
                guard let raw = le32(platformsStart + i * 4) else { validPlatforms = false; break }
                let value = Int32(bitPattern: raw)
                if value < -1 || value > 24 { validPlatforms = false; break }
                platforms.append(value)
            }
            guard validPlatforms else { continue }

            var cursor = platformsEnd
            guard let offsetsCount = boundedCount(le32(cursor), maximum: maximumCandidateCount),
                  offsetsCount == platformCount else { continue }
            cursor += 4
            var offsets: [UInt32] = []
            for i in 0..<offsetsCount {
                guard let value = le32(cursor + i * 4) else { offsets = []; break }
                offsets.append(value)
            }
            guard offsets.count == platformCount else { continue }
            cursor += offsetsCount * 4

            guard let compressedCount = boundedCount(le32(cursor), maximum: maximumCandidateCount),
                  compressedCount == platformCount else { continue }
            cursor += 4
            var compressedLengths: [UInt32] = []
            for i in 0..<compressedCount {
                guard let value = le32(cursor + i * 4) else { compressedLengths = []; break }
                compressedLengths.append(value)
            }
            guard compressedLengths.count == platformCount else { continue }
            cursor += compressedCount * 4

            guard let decompressedCount = boundedCount(le32(cursor), maximum: maximumCandidateCount),
                  decompressedCount == platformCount else { continue }
            cursor += 4
            var decompressedLengths: [UInt32] = []
            for i in 0..<decompressedCount {
                guard let value = le32(cursor + i * 4) else { decompressedLengths = []; break }
                decompressedLengths.append(value)
            }
            guard decompressedLengths.count == platformCount else { continue }
            cursor += decompressedCount * 4

            guard let blobLengthRaw = le32(cursor) else { continue }
            let blobLength = Int(blobLengthRaw)
            cursor += 4
            guard blobLength > 0, blobLength <= bytes.count - cursor else { continue }

            var rangeValid = true
            for i in 0..<platformCount {
                let offset = UInt64(offsets[i])
                let compressed = UInt64(compressedLengths[i])
                let decompressed = UInt64(decompressedLengths[i])
                guard compressed > 0, compressed <= 16 * 1024 * 1024,
                      decompressed >= 4, decompressed <= UInt64(maximumDecodedBytes),
                      offset <= UInt64(blobLength), compressed <= UInt64(blobLength) - offset else {
                    rangeValid = false
                    break
                }
            }
            guard rangeValid else { continue }
            candidatesChecked += 1
            guard candidatesChecked <= maximumCandidatesToDecode else { break }

            var decodedReports: [String] = []
            var successfulChunks = 0
            var decodedTotal = 0
            for i in 0..<platformCount {
                let compressedSize = Int(compressedLengths[i])
                let decompressedSize = Int(decompressedLengths[i])
                guard decodedTotal <= maximumDecodedBytes - decompressedSize else {
                    decodedReports.append("shader_program_chunk|platform=\(platforms[i])|index=\(i)|status=decode_budget_exceeded")
                    continue
                }
                let sourceStart = cursor + Int(offsets[i])
                let sourceEnd = sourceStart + compressedSize
                guard sourceStart >= cursor, sourceEnd >= sourceStart, sourceEnd <= cursor + blobLength else {
                    decodedReports.append("shader_program_chunk|platform=\(platforms[i])|index=\(i)|status=range_rejected")
                    continue
                }
                let packed = Data(bytes[sourceStart..<sourceEnd])
                var decoded = Data(count: decompressedSize)
                let decodedSize = decoded.withUnsafeMutableBytes { destination in
                    packed.withUnsafeBytes { source in
                        guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                              let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(dst, decompressedSize, src, compressedSize,
                                                          nil, COMPRESSION_LZ4_RAW)
                    }
                }
                guard decodedSize == decompressedSize,
                      let subProgramCountRaw = le32FromData(decoded, 0) else {
                    decodedReports.append("shader_program_chunk|platform=\(platforms[i])|index=\(i)|compressed=\(compressedSize)|decompressed_expected=\(decompressedSize)|status=lz4_or_header_failed|decoded=\(decodedSize)")
                    continue
                }
                let subProgramCount = Int(Int32(bitPattern: subProgramCountRaw))
                guard subProgramCount > 0, subProgramCount <= 100_000 else {
                    decodedReports.append("shader_program_chunk|platform=\(platforms[i])|index=\(i)|status=implausible_subprogram_count_\(subProgramCount)")
                    continue
                }

                do {
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                    let safeBase = outputURL.deletingPathExtension().lastPathComponent
                    let destination = outputDirectory.appendingPathComponent(
                        "\(safeBase)-platform-\(platforms[i])-chunk-\(i).bin"
                    )
                    try decoded.write(to: destination, options: .atomic)
                    successfulChunks += 1
                    decodedTotal += decompressedSize
                    decodedReports.append("shader_program_chunk|platform=\(platforms[i])|index=\(i)|offset=\(offsets[i])|compressed=\(compressedSize)|decompressed=\(decompressedSize)|subprograms=\(subProgramCount)|status=decoded|file=\(destination.lastPathComponent)")
                } catch {
                    decodedReports.append("shader_program_chunk|platform=\(platforms[i])|index=\(i)|status=write_failed")
                }
            }

            if successfulChunks > 0 {
                accepted.append("shader_program_blob_layout|object_index=\(objectIndex)|status=validated_candidate|candidate_offset=\(start)|platforms=\(platforms.map { String($0) }.joined(separator: ","))|platform_count=\(platformCount)|blob_bytes=\(blobLength)|decoded_chunks=\(successfulChunks)|candidate_checks=\(candidatesChecked)|local_only=true")
                accepted.append(contentsOf: decodedReports)
                return accepted
            }
        }

        if candidatesChecked == 0 {
            return ["shader_program_blob_layout|object_index=\(objectIndex)|status=no_bounded_layout_candidate|bytes_scanned=\(bytes.count)"]
        }
        return ["shader_program_blob_layout|object_index=\(objectIndex)|status=candidates_found_but_no_valid_lz4_program|candidates_checked=\(candidatesChecked)"] + accepted
    }

    private static func le32FromData(_ data: Data, _ position: Int) -> UInt32? {
        guard position >= 0, position <= data.count - 4 else { return nil }
        return UInt32(data[position]) | (UInt32(data[position + 1]) << 8) |
            (UInt32(data[position + 2]) << 16) | (UInt32(data[position + 3]) << 24)
    }

    private static func readBE32(_ bytes: [UInt8], _ position: Int) -> UInt32? {
        guard position >= 0, position + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[position]) << 24) | (UInt32(bytes[position + 1]) << 16) |
               (UInt32(bytes[position + 2]) << 8) | UInt32(bytes[position + 3])
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
