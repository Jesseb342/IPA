import SwiftUI
import UIKit
import UniformTypeIdentifiers

import Darwin


private enum ShaderTranslatorBridge {
    typealias TranslateFunction = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias ProbeFunction = @convention(c) () -> Int32
    private static let lock = NSLock()
    private static var frameworkHandle: UnsafeMutableRawPointer?
    private static var translateFunction: TranslateFunction?
    private static var probeFunction: ProbeFunction?

    private static func loadFunctions() throws {
        lock.lock()
        defer { lock.unlock() }
        if translateFunction != nil && probeFunction != nil { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Frameworks/NxNativeShaderTranslator.framework/NxNativeShaderTranslator")
        guard FileManager.default.fileExists(atPath: binary.path) else { throw ShaderTranslatorError.frameworkMissing }
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
            throw ShaderTranslatorError.loadFailed(detail)
        }
        guard let translateSymbol = dlsym(handle, "nxn_translate_shader_jobs"),
              let probeSymbol = dlsym(handle, "nxn_shader_translator_probe") else {
            let detail = dlerror().map { String(cString: $0) } ?? "required symbol not found"
            dlclose(handle)
            throw ShaderTranslatorError.symbolMissing(detail)
        }
        frameworkHandle = handle
        translateFunction = unsafeBitCast(translateSymbol, to: TranslateFunction.self)
        probeFunction = unsafeBitCast(probeSymbol, to: ProbeFunction.self)
    }

    static func probe() throws {
        try loadFunctions()
        guard let probe = probeFunction, probe() == 1 else { throw ShaderTranslatorError.probeFailed }
    }

    // The job and output paths must stay inside this app's Documents folder.
    static func translate(jobFileURL: URL, outputDirectoryURL: URL) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path + "/"
        let jobPath = jobFileURL.standardizedFileURL.path
        let outputPath = outputDirectoryURL.standardizedFileURL.path
        guard jobPath.hasPrefix(documents), outputPath.hasPrefix(documents) else { throw ShaderTranslatorError.pathOutsideSandbox }
        guard FileManager.default.fileExists(atPath: jobPath) else { throw ShaderTranslatorError.jobFileMissing }
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        try loadFunctions()
        guard let translate = translateFunction else { throw ShaderTranslatorError.probeFailed }
        let result = jobPath.withCString { jp in outputPath.withCString { op in translate(jp, op) } }
        guard result == 0 else { throw ShaderTranslatorError.translationFailed(result) }
    }
}

private enum ShaderTranslatorError: LocalizedError {
    case frameworkMissing
    case loadFailed(String)
    case symbolMissing(String)
    case probeFailed
    case pathOutsideSandbox
    case jobFileMissing
    case translationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .frameworkMissing: return "The embedded shader-translator framework is missing."
        case .loadFailed(let detail): return "Could not load the shader translator: \\(detail)"
        case .symbolMissing(let detail): return "The translator is missing a required function: \\(detail)"
        case .probeFailed: return "The shader translator did not pass its initialization check."
        case .pathOutsideSandbox: return "Shader jobs and output must stay inside the app's Documents folder."
        case .jobFileMissing: return "The local shader-job file could not be found."
        case .translationFailed(let code): return "Shader translation failed (code \\(code))."
        }
    }
}

private enum ShaderSPIRVReflection {
    private struct Variable { let type: UInt32; let id: UInt32; let storage: UInt32 }

    static func report(_ data: Data, key: String) -> [String] {
        guard data.count >= 20, data.count % 4 == 0 else { return ["spirv_reflection|key=\(key)|status=invalid_size"] }
        let b = [UInt8](data)
        var w: [UInt32] = []
        for i in stride(from: 0, to: b.count, by: 4) {
            w.append(UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24))
        }
        guard w[0] == 0x07230203 else { return ["spirv_reflection|key=\(key)|status=bad_magic"] }
        var names: [UInt32:String] = [:], memberNames: [UInt64:String] = [:]
        var dec: [UInt32:[UInt32:UInt32]] = [:], offsets: [UInt64:UInt32] = [:]
        var memberDec: [UInt64:[UInt32:UInt32]] = [:], arrayStrides: [UInt32:UInt32] = [:]
        var kind: [UInt32:String] = [:], a: [UInt32:UInt32] = [:], z: [UInt32:UInt32] = [:]
        var members: [UInt32:[UInt32]] = [:], constants: [UInt32:UInt32] = [:], vars: [Variable] = []
        func mk(_ t: UInt32, _ m: UInt32) -> UInt64 { (UInt64(t) << 32) | UInt64(m) }
        func str(_ xs: ArraySlice<UInt32>) -> String {
            var bytes: [UInt8] = []
            for x in xs { for shift in stride(from: 0, to: 32, by: 8) {
                let v = UInt8((x >> UInt32(shift)) & 255)
                if v == 0 { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(v)
            }}
            return String(decoding: bytes, as: UTF8.self)
        }
        var i = 5, malformed = false
        while i < w.count {
            let n = Int(w[i] >> 16), op = w[i] & 65535
            guard n > 0, i <= w.count - n else { malformed = true; break }
            let x = w[(i+1)..<(i+n)]
            switch op {
            case 5: if x.count >= 2 { names[x[x.startIndex]] = str(x.dropFirst()) }
            case 6: if x.count >= 3 { memberNames[mk(x[x.startIndex], x[x.startIndex+1])] = str(x.dropFirst(2)) }
            case 20: if !x.isEmpty { kind[x[x.startIndex]]="bool" }
            case 21: if x.count >= 3 { kind[x[x.startIndex]]="int"; a[x[x.startIndex]]=x[x.startIndex+1]; z[x[x.startIndex]]=x[x.startIndex+2] }
            case 22: if x.count >= 2 { kind[x[x.startIndex]]="float"; a[x[x.startIndex]]=x[x.startIndex+1] }
            case 23,24: if x.count >= 3 { kind[x[x.startIndex]] = op == 23 ? "vector" : "matrix"; a[x[x.startIndex]]=x[x.startIndex+1]; z[x[x.startIndex]]=x[x.startIndex+2] }
            case 25: if x.count >= 2 { kind[x[x.startIndex]]="image"; a[x[x.startIndex]]=x[x.startIndex+1] }
            case 26: if !x.isEmpty { kind[x[x.startIndex]]="sampler" }
            case 27: if x.count >= 2 { kind[x[x.startIndex]]="sampled_image"; a[x[x.startIndex]]=x[x.startIndex+1] }
            case 28: if x.count >= 3 { kind[x[x.startIndex]]="array"; a[x[x.startIndex]]=x[x.startIndex+1]; z[x[x.startIndex]]=x[x.startIndex+2] }
            case 29: if x.count >= 2 { kind[x[x.startIndex]]="runtime_array"; a[x[x.startIndex]]=x[x.startIndex+1] }
            case 30: if !x.isEmpty { kind[x[x.startIndex]]="struct"; members[x[x.startIndex]]=Array(x.dropFirst()) }
            case 32: if x.count >= 3 { kind[x[x.startIndex]]="pointer"; a[x[x.startIndex]]=x[x.startIndex+1]; z[x[x.startIndex]]=x[x.startIndex+2] }
            case 43: if x.count >= 3 { constants[x[x.startIndex+1]]=x[x.startIndex+2] }
            case 59: if x.count >= 3 { vars.append(Variable(type:x[x.startIndex], id:x[x.startIndex+1], storage:x[x.startIndex+2])) }
            case 71: if x.count >= 2 {
                let target = x[x.startIndex], decoration = x[x.startIndex+1]
                let value = x.count >= 3 ? x[x.startIndex+2] : 1
                dec[target, default:[:]][decoration] = value
                if decoration == 6 { arrayStrides[target] = value }
            }
            case 72: if x.count >= 3 {
                let target = x[x.startIndex], member = x[x.startIndex+1], decoration = x[x.startIndex+2]
                let value = x.count >= 4 ? x[x.startIndex+3] : 1
                memberDec[mk(target,member), default:[:]][decoration] = value
                if decoration == 35 && x.count >= 4 { offsets[mk(target,member)] = value }
            }
            default: break
            }
            i += n
        }
        func safe(_ s: String) -> String { s.replacingOccurrences(of:"|",with:"_").replacingOccurrences(of:"\n",with:" ") }
        func type(_ id: UInt32, _ depth: Int = 0) -> String {
            if depth > 5 { return "type#\(id)" }
            switch kind[id] {
            case "bool": return "bool"
            case "int": return "\((z[id] ?? 0) == 0 ? "u" : "i")\(a[id] ?? 32)"
            case "float": return "f\(a[id] ?? 32)"
            case "vector": return "vec\(z[id] ?? 0)<\(type(a[id] ?? 0,depth+1))>"
            case "matrix": return "mat\(z[id] ?? 0)<\(type(a[id] ?? 0,depth+1))>"
            case "array": return "array[\(constants[z[id] ?? 0].map { String($0) } ?? "?")]<\(type(a[id] ?? 0,depth+1))>"
            case "runtime_array": return "runtime_array<\(type(a[id] ?? 0,depth+1))>"
            case "struct": return "struct#\(id)"
            case "pointer": return type(z[id] ?? 0,depth+1)
            case "image": return "image"
            case "sampler": return "sampler"
            case "sampled_image": return "sampled_image"
            default: return "type#\(id)"
            }
        }
        var out: [String] = [], ins = 0, outs = 0, descs = 0, buffers = 0
        for v in vars {
            let d = dec[v.id] ?? [:]
            let pointee = kind[v.type] == "pointer" ? (z[v.type] ?? 0) : v.type
            let name = safe(names[v.id] ?? "id\(v.id)")
            if v.storage == 1 || v.storage == 3 {
                let dir = v.storage == 1 ? "input" : "output"
                if v.storage == 1 { ins += 1 } else { outs += 1 }
                out.append("interface_\(dir)|key=\(key)|name=\(name)|location=\(d[30].map{String($0)} ?? "na")|builtin=\(d[11].map{"builtin#\($0)"} ?? "none")|type=\(type(pointee))")
                if kind[pointee] == "struct" {
                    for (j, mt) in (members[pointee] ?? []).enumerated().prefix(32) {
                        let memberKey = mk(pointee, UInt32(j)), md = memberDec[memberKey] ?? [:]
                        out.append("interface_\(dir)_member|key=\(key)|variable=\(name)|member=\(safe(memberNames[memberKey] ?? "member\(j)"))|location=\(md[30].map{String($0)} ?? "na")|builtin=\(md[11].map{"builtin#\($0)"} ?? "none")|type=\(type(mt))")
                    }
                }
            }
            if let binding = d[33] {
                descs += 1
                out.append("spirv_descriptor|key=\(key)|name=\(name)|set=\(d[34].map{String($0)} ?? "0")|binding=\(binding)|storage_class=\(v.storage)|type=\(type(pointee))")
            }
            if (v.storage == 2 || v.storage == 12), kind[pointee] == "struct" {
                buffers += 1
                out.append("spirv_buffer_layout|key=\(key)|name=\(name)|binding=\(d[33].map{String($0)} ?? "na")|members=\(members[pointee]?.count ?? 0)")
                for (j, mt) in (members[pointee] ?? []).enumerated().prefix(32) {
                    let ix = UInt32(j), k = mk(pointee,ix), md = memberDec[k] ?? [:]
                    out.append("spirv_buffer_member|key=\(key)|buffer=\(name)|member=\(safe(memberNames[k] ?? "member\(j)"))|index=\(j)|offset=\(offsets[k].map{String($0)} ?? "na")|matrix_stride=\(md[7].map{String($0)} ?? "na")|array_stride=\(arrayStrides[mt].map{String($0)} ?? "na")|type=\(type(mt))")
                }
            }
        }
        out.insert("spirv_reflection|key=\(key)|status=\(malformed ? "partial" : "parsed")|inputs=\(ins)|outputs=\(outs)|descriptors=\(descs)|buffer_layouts=\(buffers)",at:0)
        return out
    }
}

private struct NSPContentRecord: Sendable {
    let type: String
    let titleID: String
    let version: String
}

private enum MetadataProbe {
    typealias InspectFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static let lock = NSLock()
    private static var frameworkHandle: UnsafeMutableRawPointer?
    private static var inspectFunction: InspectFunction?

    static func inspect(keysURL: URL, nspURL: URL) throws -> [NSPContentRecord] {
        lock.lock()
        defer { lock.unlock() }

        if inspectFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
            guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load the LibHac metadata engine: \(detail)")
            }
            guard let symbol = dlsym(handle, "nxn_inspect_nsp") else {
                let detail = dlerror().map { String(cString: $0) } ?? "symbol not found"
                dlclose(handle)
                throw ImportValidationError.metadata("The metadata engine is missing its inspection function: \(detail)")
            }
            frameworkHandle = handle
            inspectFunction = unsafeBitCast(symbol, to: InspectFunction.self)
        }

        guard let inspect = inspectFunction else {
            throw ImportValidationError.metadata("The metadata engine could not be initialized.")
        }

        var output = [CChar](repeating: 0, count: 64 * 1024)
        let result = keysURL.path.withCString { keyPath in
            nspURL.path.withCString { packagePath in
                output.withUnsafeMutableBufferPointer { buffer in
                    inspect(keyPath, packagePath, buffer.baseAddress!, Int32(buffer.count))
                }
            }
        }
        guard result >= 0 else {
            throw ImportValidationError.metadata(result == -2
                ? "The package metadata output exceeded the safety limit."
                : "The metadata engine rejected the input paths (code \(result)).")
        }

        let response = output.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }

        let records = response.split(separator: "\n").compactMap { line -> NSPContentRecord? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == "content" else { return nil }
            return NSPContentRecord(type: String(fields[1]), titleID: String(fields[2]).uppercased(), version: String(fields[3]))
        }
        guard !records.isEmpty else {
            throw ImportValidationError.metadata("No recognized game content metadata was returned.")
        }
        return records
    }
}


private enum ExtractionManifest {
    static func write(
        keysURL: URL,
        baseURL: URL,
        updateURL: URL?,
        dlcURLs: [URL],
        baseTitleID: String,
        outputDirectory: URL
    ) throws -> URL {
        var lines = [
            "format|1",
            "result|extraction_succeeded",
            "base_package|\(baseURL.lastPathComponent)",
            "base_title_id|\(baseTitleID)",
            "update_selected|\(updateURL == nil ? "false" : "true")",
            "update_package|\(updateURL?.lastPathComponent ?? "none")",
            "dlc_package_count|\(dlcURLs.count)"
        ]

        let baseRecords = try MetadataProbe.inspect(keysURL: keysURL, nspURL: baseURL)
        for record in baseRecords {
            lines.append("base_content|\(record.type)|\(record.titleID)|version=\(record.version)")
        }

        if let updateURL {
            let updateRecords = try MetadataProbe.inspect(keysURL: keysURL, nspURL: updateURL)
            for record in updateRecords {
                lines.append("update_content|\(record.type)|\(record.titleID)|version=\(record.version)")
            }
        }

        for (packageIndex, packageURL) in dlcURLs.enumerated() {
            lines.append("dlc_package|\(packageIndex + 1)|\(packageURL.lastPathComponent)")
            let records = try MetadataProbe.inspect(keysURL: keysURL, nspURL: packageURL)
            for record in records {
                lines.append("dlc_content|\(record.type)|\(record.titleID)|version=\(record.version)")
            }
        }

        let manager = FileManager.default
        let artifactRoots = ["ExeFS", "aoc"]
        var aocImages = 0
        var aocBytes: UInt64 = 0
        for rootName in artifactRoots {
            let root = outputDirectory.appendingPathComponent(rootName, isDirectory: true)
            guard manager.fileExists(atPath: root.path),
                  let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let attributes = try manager.attributesOfItem(atPath: fileURL.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let relative = String(fileURL.path.dropFirst(outputDirectory.path.count + 1))
                lines.append("artifact|\(relative)|bytes=\(size)")
                if rootName == "aoc" && fileURL.pathExtension.lowercased() == "img" {
                    aocImages += 1
                    aocBytes += size
                }
            }
        }

        let romfsURL = outputDirectory.appendingPathComponent("RomFS.img")
        if manager.fileExists(atPath: romfsURL.path) {
            let attributes = try manager.attributesOfItem(atPath: romfsURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            lines.append("artifact|RomFS.img|bytes=\(size)")
        }
        lines.append("aoc_summary|images=\(aocImages)|total_bytes=\(aocBytes)")
        lines.append("scan_target|PreparedGame/RewrittenExeFS/main (after NSO rewrite)")
        lines.append("scan_status|pending")

        let manifestURL = outputDirectory.appendingPathComponent("extraction-manifest.txt")
        try (lines.joined(separator: "\n") + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
        return manifestURL
    }

    static func combinedReport(
        preparedDirectory: URL,
        extractionLog: String,
        scanReport: String
    ) -> String {
        let manifestURL = preparedDirectory.appendingPathComponent("extraction-manifest.txt")
        var manifest = (try? String(contentsOf: manifestURL, encoding: .utf8))
            ?? "manifest_status|missing\nmanifest_path|\(manifestURL.lastPathComponent)\n"
        if !manifest.hasSuffix("\n") { manifest += "\n" }
        manifest += "scan_status|completed\n"
        manifest += "scan_module|RewrittenExeFS/main\n"
        if let summary = scanReport.split(separator: "\n").first(where: { $0.hasPrefix("summary|") }) {
            manifest += "scan_summary|\(summary)\n"
        }
        try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let extractionSection = extractionLog.isEmpty
            ? "No separate extraction log was captured.\n"
            : extractionLog + "\n"
        return manifest
            + "\n--- EXTRACTION DETAILS ---\n"
            + extractionSection
            + "\n--- MAIN NSO ANALYSIS ---\n"
            + scanReport
    }
}

private enum GameExtractor {
    typealias ExtractFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>,
        UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static let lock = NSLock()
    private static var frameworkHandle: UnsafeMutableRawPointer?
    private static var extractFunction: ExtractFunction?

    typealias ExtractDLCFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>,
        UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static var extractDLCFunction: ExtractDLCFunction?


    typealias InspectNsoFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static var inspectNsoFunction: InspectNsoFunction?

    typealias RewriteNsoFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>,
        UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static var rewriteNsoFunction: RewriteNsoFunction?

    typealias EncoderSelfTestFunction = @convention(c) (
        UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static var encoderSelfTestFunction: EncoderSelfTestFunction?

    typealias Arm64DisassembleFunction = @convention(c) (
        UnsafeRawPointer, Int, UInt32, UnsafeMutablePointer<CChar>, Int
    ) -> Int32

    typealias Arm64AnalyzeFunction = @convention(c) (
        UnsafeRawPointer, Int, UnsafeMutablePointer<CChar>, Int
    ) -> Int32

    private static var arm64AnalyzeFunction: Arm64AnalyzeFunction?

    typealias Arm64DiscoverStubsFunction = @convention(c) (
        UnsafeRawPointer, Int, UnsafeMutablePointer<CChar>, Int
    ) -> Int32

    private static var arm64DiscoverStubsFunction: Arm64DiscoverStubsFunction?

    typealias Arm64InspectFunction = @convention(c) (
        UnsafeRawPointer, Int, UInt64, UnsafeMutablePointer<CChar>, Int
    ) -> Int32

    private static var arm64InspectFunction: Arm64InspectFunction?

    private static var arm64FrameworkHandle: UnsafeMutableRawPointer?
    private static var arm64DisassembleFunction: Arm64DisassembleFunction?

    static func testArm64Encoder() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if encoderSelfTestFunction == nil {
            let handle: UnsafeMutableRawPointer
            if let existing = frameworkHandle {
                handle = existing
            } else {
                let binary = Bundle.main.bundleURL
                    .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
                guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                    let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                    throw ImportValidationError.metadata("Could not load the AArch64 encoder: \(detail)")
                }
                frameworkHandle = loaded
                handle = loaded
            }
            guard let symbol = dlsym(handle, "nxn_arm64_encoder_selftest") else {
                throw ImportValidationError.metadata("The AArch64 encoder self-test is missing.")
            }
            encoderSelfTestFunction = unsafeBitCast(symbol, to: EncoderSelfTestFunction.self)
        }

        guard let test = encoderSelfTestFunction else {
            throw ImportValidationError.metadata("The AArch64 encoder self-test could not be initialized.")
        }
        var output = [CChar](repeating: 0, count: 16 * 1024)
        let result = output.withUnsafeMutableBufferPointer { buffer in
            test(buffer.baseAddress!, Int32(buffer.count))
        }
        let response = output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard result == 0 else {
            throw ImportValidationError.metadata(response.isEmpty ? "AArch64 encoder vectors failed (code \(result))." : response)
        }
        return response
    }

    static func inspectFunction(url: URL, textOffset: UInt64) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if arm64InspectFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeArm64.framework/NxNativeArm64")
            guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load Capstone function inspector: \(detail)")
            }
            arm64FrameworkHandle = loaded
            guard let symbol = dlsym(loaded, "nxn_arm64_inspect_function") else {
                throw ImportValidationError.metadata("Capstone's function inspector is missing.")
            }
            arm64InspectFunction = unsafeBitCast(symbol, to: Arm64InspectFunction.self)
        }

        guard let inspect = arm64InspectFunction else {
            throw ImportValidationError.metadata("Capstone function inspection could not be initialized.")
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw ImportValidationError.metadata("Could not read rewritten NSO: \(error.localizedDescription)") }
        var output = [CChar](repeating: 0, count: 256 * 1024)
        let result = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return Int32(-1) }
            return output.withUnsafeMutableBufferPointer { buffer in
                inspect(base, raw.count, textOffset, buffer.baseAddress!, buffer.count)
            }
        }
        let response = output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard result == 0 else {
            throw ImportValidationError.metadata(response.isEmpty ? "Function inspection returned code \(result)." : response)
        }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }
        return response
    }

    static func analyzeNSO(url: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if arm64AnalyzeFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeArm64.framework/NxNativeArm64")
            guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load Capstone analyzer: \(detail)")
            }
            arm64FrameworkHandle = loaded
            guard let symbol = dlsym(loaded, "nxn_arm64_analyze_nso") else {
                throw ImportValidationError.metadata("Capstone's full NSO analyzer is missing.")
            }
            arm64AnalyzeFunction = unsafeBitCast(symbol, to: Arm64AnalyzeFunction.self)
        }

        guard let analyze = arm64AnalyzeFunction else {
            throw ImportValidationError.metadata("Capstone full-text analysis could not be initialized.")
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw ImportValidationError.metadata("Could not read rewritten NSO: \(error.localizedDescription)") }
        var output = [CChar](repeating: 0, count: 64 * 1024)
        let result = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return Int32(-1) }
            return output.withUnsafeMutableBufferPointer { buffer in
                analyze(base, raw.count, buffer.baseAddress!, buffer.count)
            }
        }
        let response = output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard result == 0 else {
            throw ImportValidationError.metadata(response.isEmpty ? "Full-text analysis returned code \(result)." : response)
        }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }
        return response
    }

    static func discoverLinkerStubs(url: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if arm64DiscoverStubsFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeArm64.framework/NxNativeArm64")
            guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load Capstone linker-stub scanner: \(detail)")
            }
            arm64FrameworkHandle = loaded
            guard let symbol = dlsym(loaded, "nxn_arm64_discover_linker_stubs") else {
                throw ImportValidationError.metadata("Capstone's linker-stub discovery function is missing.")
            }
            arm64DiscoverStubsFunction = unsafeBitCast(symbol, to: Arm64DiscoverStubsFunction.self)
        }

        guard let discover = arm64DiscoverStubsFunction else {
            throw ImportValidationError.metadata("Linker-stub discovery could not be initialized.")
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw ImportValidationError.metadata("Could not read rewritten NSO: \(error.localizedDescription)") }
        var output = [CChar](repeating: 0, count: 1024 * 1024)
        let result = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return Int32(-1) }
            return output.withUnsafeMutableBufferPointer { buffer in
                discover(base, raw.count, buffer.baseAddress!, buffer.count)
            }
        }
        let response = output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard result == 0 else {
            throw ImportValidationError.metadata(response.isEmpty ? "Linker-stub discovery returned code \(result)." : response)
        }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }
        return response
    }

    static func disassembleNSO(url: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if arm64DisassembleFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeArm64.framework/NxNativeArm64")
            guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load Capstone ARM64: \(detail)")
            }
            arm64FrameworkHandle = loaded
            guard let symbol = dlsym(loaded, "nxn_arm64_disassemble_nso") else {
                throw ImportValidationError.metadata("Capstone's NSO disassembly entry point is missing.")
            }
            arm64DisassembleFunction = unsafeBitCast(symbol, to: Arm64DisassembleFunction.self)
        }

        guard let disassemble = arm64DisassembleFunction else {
            throw ImportValidationError.metadata("Capstone ARM64 could not be initialized.")
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw ImportValidationError.metadata("Could not read rewritten NSO: \(error.localizedDescription)") }
        var output = [CChar](repeating: 0, count: 256 * 1024)
        let result = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return Int32(-1) }
            return output.withUnsafeMutableBufferPointer { buffer in
                disassemble(base, raw.count, 96, buffer.baseAddress!, buffer.count)
            }
        }
        let response = output.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard result == 0 else {
            throw ImportValidationError.metadata(response.isEmpty ? "Capstone returned code \(result)." : response)
        }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }
        return response
    }

    static func rewriteNSOModules(exefsURL: URL, outputURL: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if rewriteNsoFunction == nil {
            let handle: UnsafeMutableRawPointer
            if let existing = frameworkHandle {
                handle = existing
            } else {
                let binary = Bundle.main.bundleURL
                    .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
                guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                    let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                    throw ImportValidationError.metadata("Could not load the NSO rewrite engine: \(detail)")
                }
                frameworkHandle = loaded
                handle = loaded
            }
            guard let symbol = dlsym(handle, "nxn_rewrite_nso") else {
                throw ImportValidationError.metadata("The NSO rewrite function is missing.")
            }
            rewriteNsoFunction = unsafeBitCast(symbol, to: RewriteNsoFunction.self)
        }

        guard let rewrite = rewriteNsoFunction else {
            throw ImportValidationError.metadata("The NSO rewrite function could not be initialized.")
        }
        var output = [CChar](repeating: 0, count: 256 * 1024)
        let emptyManifest = ""
        let result = exefsURL.path.withCString { inputPath in
            outputURL.path.withCString { outputPath in
                emptyManifest.withCString { manifestPath in
                    output.withUnsafeMutableBufferPointer { buffer in
                        rewrite(inputPath, outputPath, manifestPath, buffer.baseAddress!, Int32(buffer.count))
                    }
                }
            }
        }
        let response = output.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
        guard result >= 0 else {
            throw ImportValidationError.metadata("NSO rewrite output exceeded its safety limit.")
        }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }
        return response
    }

    static func inspectNSOModules(exefsURL: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if inspectNsoFunction == nil {
            let handle: UnsafeMutableRawPointer
            if let existing = frameworkHandle {
                handle = existing
            } else {
                let binary = Bundle.main.bundleURL
                    .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
                guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                    let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                    throw ImportValidationError.metadata("Could not load the NSO inspection engine: \(detail)")
                }
                frameworkHandle = loaded
                handle = loaded
            }
            guard let symbol = dlsym(handle, "nxn_inspect_nso") else {
                throw ImportValidationError.metadata("The NSO inspection function is missing.")
            }
            inspectNsoFunction = unsafeBitCast(symbol, to: InspectNsoFunction.self)
        }

        guard let inspect = inspectNsoFunction else {
            throw ImportValidationError.metadata("The NSO inspection function could not be initialized.")
        }
        var output = [CChar](repeating: 0, count: 256 * 1024)
        let result = exefsURL.path.withCString { path in
            output.withUnsafeMutableBufferPointer { buffer in
                inspect(path, buffer.baseAddress!, Int32(buffer.count))
            }
        }
        let response = output.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
        guard result >= 0 else {
            throw ImportValidationError.metadata("NSO inspection output exceeded its safety limit.")
        }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }
        return response
    }

    static func extract(keysURL: URL, baseURL: URL, updateURL: URL?, outputDirectory: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if extractFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
            guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load the extraction engine: \(detail)")
            }
            guard let symbol = dlsym(handle, "nxn_extract_game") else {
                let detail = dlerror().map { String(cString: $0) } ?? "symbol not found"
                dlclose(handle)
                throw ImportValidationError.metadata("The extraction engine is missing its extraction function: \(detail)")
            }
            frameworkHandle = handle
            extractFunction = unsafeBitCast(symbol, to: ExtractFunction.self)
        }

        guard let extract = extractFunction else {
            throw ImportValidationError.metadata("The extraction engine could not be initialized.")
        }

        var output = [CChar](repeating: 0, count: 1024 * 1024)
        let result = keysURL.path.withCString { keyPath in
            baseURL.path.withCString { basePath in
                (updateURL?.path ?? "").withCString { updatePath in
                    outputDirectory.path.withCString { destinationPath in
                        output.withUnsafeMutableBufferPointer { buffer in
                            extract(keyPath, basePath, updatePath, destinationPath, buffer.baseAddress!, Int32(buffer.count))
                        }
                    }
                }
            }
        }

        let response = output.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
        guard result == 0 else {
            let detail = response.isEmpty ? "The native extractor returned code \(result)." : response
            throw ImportValidationError.metadata("Extraction stopped (code \(result)).\n\(detail)")
        }
        return response
    }

    static func extractDLC(keysURL: URL, dlcURL: URL, imageURL: URL, titleID: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if extractDLCFunction == nil {
            let handle: UnsafeMutableRawPointer
            if let existing = frameworkHandle {
                handle = existing
            } else {
                let binary = Bundle.main.bundleURL
                    .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
                guard let loaded = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                    let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                    throw ImportValidationError.metadata("Could not load the DLC extraction engine: \(detail)")
                }
                frameworkHandle = loaded
                handle = loaded
            }
            guard let symbol = dlsym(handle, "nxn_extract_dlc") else {
                let detail = dlerror().map { String(cString: $0) } ?? "symbol not found"
                throw ImportValidationError.metadata("The DLC extraction function is missing: \(detail)")
            }
            extractDLCFunction = unsafeBitCast(symbol, to: ExtractDLCFunction.self)
        }

        guard let extract = extractDLCFunction else {
            throw ImportValidationError.metadata("The DLC extraction function could not be initialized.")
        }

        var output = [CChar](repeating: 0, count: 1024 * 1024)
        let result = keysURL.path.withCString { keyPath in
            dlcURL.path.withCString { packagePath in
                imageURL.path.withCString { destinationPath in
                    titleID.withCString { titleIDPointer in
                        output.withUnsafeMutableBufferPointer { buffer in
                            extract(keyPath, packagePath, destinationPath, titleIDPointer, buffer.baseAddress!, Int32(buffer.count))
                        }
                    }
                }
            }
        }
        let response = output.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
        guard result == 0 else {
            let detail = response.isEmpty ? "The native DLC extractor returned code \(result)." : response
            throw ImportValidationError.metadata("DLC extraction stopped (code \(result)).\n\(detail)")
        }
        return response
    }

    static func extractDLCs(keysURL: URL, dlcURLs: [URL], baseTitleID: String, outputDirectory: URL) throws -> String {
        let aocDirectory = outputDirectory.appendingPathComponent("aoc", isDirectory: true)
        try FileManager.default.createDirectory(at: aocDirectory, withIntermediateDirectories: true)

        var extractedIndices = Set<UInt64>()
        var logs: [String] = []
        for packageURL in dlcURLs {
            let records = try MetadataProbe.inspect(keysURL: keysURL, nspURL: packageURL)
            let dlcRecords = records.filter { $0.type == "AddOnContent" }
            guard !dlcRecords.isEmpty else {
                throw ImportValidationError.metadata("\(packageURL.lastPathComponent) contains no AddOnContent metadata.")
            }
            var seenTitleIDs = Set<String>()
            for record in dlcRecords where seenTitleIDs.insert(record.titleID).inserted {
                let index = try ImportFileStorage.dlcIndex(titleID: record.titleID, baseTitleID: baseTitleID)
                guard extractedIndices.insert(index).inserted else {
                    throw ImportValidationError.metadata("DLC index \(index) appears in more than one selected package. Remove duplicate DLC packages.")
                }
                let imageURL = aocDirectory.appendingPathComponent("\(index).img")
                let log = try extractDLC(keysURL: keysURL, dlcURL: packageURL, imageURL: imageURL, titleID: record.titleID)
                let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
                guard let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0 else {
                    throw ImportValidationError.metadata("DLC \(record.titleID) produced an empty RomFS image.")
                }
                logs.append("DLC \(record.titleID) → aoc/\(index).img\n\(log)")
            }
        }
        guard !extractedIndices.isEmpty else {
            throw ImportValidationError.metadata("No DLC content records were available to extract.")
        }
        return logs.joined(separator: "\n")
    }
}

private enum ImportKind: String, Identifiable, Sendable {
    case base, keys, update, dlc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .base: return "Base game NSP"
        case .keys: return "prod.keys"
        case .update: return "Game update NSP"
        case .dlc: return "DLC NSP files"
        }
    }
    var prefix: String {
        switch self {
        case .base: return "base"
        case .keys: return "prod-keys"
        case .update: return "update"
        case .dlc: return "dlc"
        }
    }
    var extensions: [String] { self == .keys ? ["keys"] : ["nsp"] }
    var allowsMultiple: Bool { false }
}

private struct ImportedGameFile: Codable, Identifiable, Equatable, Sendable {
    let displayName: String
    let storedName: String
    var validationStatus: String?
    var id: String { storedName }
    var contentTitleID: String? {
        let parts = (validationStatus ?? "").components(separatedBy: " · ")
        guard parts.count >= 2, parts[1].count == 16 else { return nil }
        return parts[1].uppercased()
    }
}

private enum ImportValidationError: LocalizedError {
    case unreadable
    case invalidKeys(String)
    case missingKey(String)
    case invalidContainer(String)
    case noNCA
    case wrongContentType(expected: String, found: String)
    case metadata(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The selected file could not be read."
        case .invalidKeys(let reason):
            return "Invalid prod.keys file: \(reason)"
        case .missingKey(let key):
            return "The keys file is missing a required key: \(key)."
        case .invalidContainer(let reason):
            return "Invalid NSP container: \(reason)"
        case .noNCA:
            return "The NSP contains no NCA content files."
        case .wrongContentType(let expected, let found):
            return "Wrong NSP content type. Expected \(expected), but found \(found)."
        case .metadata(let reason):
            return "Metadata check failed: \(reason)"
        }
    }
}

private enum ImportFileStorage {
    static func validate(_ source: URL, kind: ImportKind) throws {
        let expectedExtension = kind == .keys ? "keys" : "nsp"
        guard source.pathExtension.lowercased() == expectedExtension else {
            throw ImportValidationError.invalidContainer("expected a .\(expectedExtension) file.")
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        switch kind {
        case .keys:
            try validateKeys(source)
        case .base, .update, .dlc:
            try validateNSP(source)
        }
    }

    private static func validateKeys(_ source: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw ImportValidationError.unreadable }
        guard data.count > 0, data.count <= 16 * 1024 * 1024,
              let decoded = String(data: data, encoding: .utf8) else {
            throw ImportValidationError.invalidKeys("file is empty, too large, or not UTF-8 text.")
        }
        // Some editors prepend a UTF-8 byte-order mark; it is not part of the
        // first key name and must be removed before parsing.
        let text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded

        var parsed: [String: String] = [:]
        for (lineNumber, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw ImportValidationError.invalidKeys("line \(lineNumber + 1) is not a key=value entry.")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) }) else {
                throw ImportValidationError.invalidKeys("line \(lineNumber + 1) has an invalid key name.")
            }
            guard !value.isEmpty, value.count.isMultiple(of: 2),
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
                throw ImportValidationError.invalidKeys("line \(lineNumber + 1) has a non-hexadecimal or incomplete value.")
            }
            parsed[name.lowercased()] = value
        }

        // header_key is used later to decrypt NCA headers, but some otherwise
        // usable prod.keys dumps omit it. Do not reject the whole key file at
        // import time solely because this optional entry is absent.
        if let headerKey = parsed["header_key"], headerKey.count != 64 {
            throw ImportValidationError.invalidKeys("header_key must be a 32-byte (64 hex character) value when present.")
        }

        // Switch master_key values are 128-bit AES keys (16 bytes = 32 hex
        // characters), not 32-byte values. Match the standard prod.keys names
        // case-insensitively; values are normalized above.
        let hasMasterKey = parsed.contains { entry in
            entry.key.range(of: #"^master_key_[0-9a-f]{2}$"#, options: .regularExpression) != nil
                && entry.value.count == 32
        }
        guard hasMasterKey else {
            throw ImportValidationError.missingKey("at least one 16-byte master_key_XX entry (32 hexadecimal characters)")
        }
    }

    private static func validateNSP(_ source: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: source.path) }
        catch { throw ImportValidationError.unreadable }
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value, fileSize >= 16 else {
            throw ImportValidationError.invalidContainer("file is too small to contain a PFS0 header.")
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: source) }
        catch { throw ImportValidationError.unreadable }
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 16) ?? Data()
        guard header.count == 16, String(data: header.prefix(4), encoding: .ascii) == "PFS0" else {
            throw ImportValidationError.invalidContainer("missing PFS0 package signature.")
        }

        let count = UInt64(readLE32(header, 4))
        let stringSize = UInt64(readLE32(header, 8))
        guard count > 0, count <= 100_000 else {
            throw ImportValidationError.invalidContainer("file-entry count is invalid.")
        }
        let entriesSize = count * 0x18
        let metadataSize = 16 + entriesSize + stringSize
        guard metadataSize <= fileSize, metadataSize <= 64 * 1024 * 1024 else {
            throw ImportValidationError.invalidContainer("file table exceeds the package bounds.")
        }

        let remainder = try handle.read(upToCount: Int(metadataSize - 16)) ?? Data()
        guard remainder.count == Int(metadataSize - 16) else {
            throw ImportValidationError.invalidContainer("file table is truncated.")
        }
        var table = header
        table.append(remainder)

        let stringsStart = 16 + Int(entriesSize)
        let stringsEnd = stringsStart + Int(stringSize)
        var ncaCount = 0
        for index in 0..<Int(count) {
            let entry = 16 + index * 0x18
            let offset = readLE64(table, entry)
            let size = readLE64(table, entry + 8)
            let nameOffset = UInt64(readLE32(table, entry + 16))
            guard size > 0, offset <= fileSize, size <= fileSize,
                  metadataSize <= fileSize, offset <= fileSize - metadataSize,
                  size <= fileSize - metadataSize - offset,
                  nameOffset < stringSize else {
                throw ImportValidationError.invalidContainer("an entry has an invalid size, offset, or name.")
            }
            let nameStart = stringsStart + Int(nameOffset)
            guard nameStart < stringsEnd,
                  let terminator = table[nameStart..<stringsEnd].firstIndex(of: 0),
                  terminator > nameStart,
                  let name = String(data: table[nameStart..<terminator], encoding: .utf8) else {
                throw ImportValidationError.invalidContainer("an entry has an invalid filename.")
            }
            if name.lowercased().hasSuffix(".nca") {
                // NCA headers are encrypted with the console's header key.
                // Their plaintext magic is therefore not visible by simply
                // reading offset 0x200 from the NSP. Full NCA validation must
                // wait for the LibHac metadata/key inspection stage.
                ncaCount += 1
            }
        }
        guard ncaCount > 0 else { throw ImportValidationError.noNCA }
    }

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (UInt32($1) * 8)) }
    }

    private static func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << (UInt64($1) * 8)) }
    }

    static func dlcIndex(titleID: String, baseTitleID: String) throws -> UInt64 {
        guard let base = UInt64(baseTitleID, radix: 16),
              let dlc = UInt64(titleID, radix: 16),
              base <= UInt64.max - 0x1000,
              (base >> 16) == (dlc >> 16),
              dlc >= base + 0x1000 else {
            throw ImportValidationError.metadata("DLC title ID \(titleID) does not belong to base game \(baseTitleID).")
        }
        return dlc - base - 0x1000
    }

    static func inspectContent(_ source: URL, keysURL: URL, kind: ImportKind, baseTitleID: String? = nil) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let records = try MetadataProbe.inspect(keysURL: keysURL, nspURL: source)
        let expected: String
        switch kind {
        case .base: expected = "Application"
        case .update: expected = "Patch"
        case .dlc: expected = "AddOnContent"
        case .keys: return "Keys syntax checked"
        }
        let matching = records.filter { $0.type == expected }
        guard let record = matching.first else {
            let found = Array(Set(records.map(\.type))).sorted().joined(separator: ", ")
            throw ImportValidationError.wrongContentType(expected: expected, found: found.isEmpty ? "unknown" : found)
        }
        if kind == .dlc {
            guard let baseTitleID else {
                throw ImportValidationError.metadata("Verify the base game before importing DLC.")
            }
            for item in matching {
                _ = try dlcIndex(titleID: item.titleID, baseTitleID: baseTitleID)
            }
        }
        let label: String
        switch kind {
        case .base: label = "Verified base game"
        case .update: label = "Verified update"
        case .dlc: label = "Verified DLC"
        case .keys: label = "Keys syntax checked"
        }
        let extra = records.count > 1 ? " · package has \(records.count) metadata records" : ""
        let dlcCount = kind == .dlc ? " · \(Set(matching.map(\.titleID)).count) DLC title(s)" : ""
        return "\(label) · \(record.titleID) · v\(record.version)\(extra)\(dlcCount)"
    }

    static func copyIntoAppStorage(_ source: URL, prefix: String, validationStatus: String) throws -> ImportedGameFile {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let storedName = "\(prefix)-\(UUID().uuidString).\(ext)"
        let destination = folder.appendingPathComponent(storedName)
        try FileManager.default.copyItem(at: source, to: destination)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)

        return ImportedGameFile(displayName: source.lastPathComponent, storedName: storedName, validationStatus: validationStatus)
    }
}

private struct ImportPickerRequest: Identifiable {
    let kind: ImportKind
    var id: String { kind.id }
}

private struct ImportDocumentPicker: UIViewControllerRepresentable {
    let extensions: [String]
    let allowsMultiple: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types.isEmpty ? [.data] : types,
            asCopy: false
        )
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.isEmpty ? onCancel() : onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct ShaderSampleActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ImportScreenView: View {
    @State private var base: ImportedGameFile?
    @State private var keys: ImportedGameFile?
    @State private var update: ImportedGameFile?
    @State private var dlc: [ImportedGameFile] = []
    @State private var picker: ImportPickerRequest?
    @State private var importing = false
    @State private var extracting = false
    @State private var inspectingModules = false
    @State private var gameExtracted = false
    @State private var inspectionLog = ""
    @State private var rewritingModules = false
    @State private var rewriteLog = ""
    @State private var testingEncoder = false
    @State private var encoderTestLog = ""
    @State private var testingMetalCompiler = false
    @State private var metalCompilerLog = ""
    @State private var testingShaderTranslator = false
    @State private var shaderTranslatorLog = ""
    @State private var testingCupheadMetalShader = false
    @State private var cupheadMetalShaderLog = ""
    @State private var scanningShaderSources = false
    @State private var shaderSourceScanLog = ""
    @State private var exportingShaderSamples = false
    @State private var exportingNVNSplitSamples = false
    @State private var shaderSampleExportURL: URL?
    @State private var showingShaderSampleShare = false
    @State private var disassemblingModules = false
    @State private var disassemblyLog = ""
    @State private var functionOffset = "00000038"
    @State private var extractionLog = ""
    @State private var status = ""
    @State private var noUpdateSelected = false
    @State private var dlcSelectionFinished = false

    private let defaults = UserDefaults.standard

    private var baseVerified: Bool {
        base?.validationStatus?.hasPrefix("Verified base game") == true
    }
    private var updateVerified: Bool {
        update?.validationStatus?.hasPrefix("Verified update") == true
    }
    private var canChooseUpdate: Bool { baseVerified }
    private var canChooseDLC: Bool { updateVerified || noUpdateSelected }
    private var canExtract: Bool {
        baseVerified && keys != nil && (updateVerified || noUpdateSelected) && dlcSelectionFinished
    }

    private var cupheadObject138SPIRVAvailable: Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("ShaderTranslatorVertexSurvey/data-resources-assets-shader-object-138-p19-c0-s12-t26-len3936.spv")
        return FileManager.default.fileExists(atPath: file.path)
    }

    private var cupheadObject141SPIRVKey: String? {
        cupheadShaderSPIRVKey(objectIndex: 141, subprogramIndex: 8)
    }

    /// Resolve the fixture from its Unity sidecar instead of hard-coding a code-length suffix.
    /// Refuse ambiguous matches so a different chunk/variant is never tested by accident.
    private func cupheadShaderSPIRVKey(objectIndex: Int, subprogramIndex: Int) -> String? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("ShaderTranslatorVertexSurvey", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        let matches = files.compactMap { sidecar -> String? in
            let name = sidecar.lastPathComponent
            guard name.hasSuffix(".meta.json"),
                  let data = try? Data(contentsOf: sidecar),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (metadata["object_index"] as? Int) == objectIndex,
                  (metadata["subprogram_index"] as? Int) == subprogramIndex,
                  (metadata["platform"] as? Int) == 19,
                  (metadata["gpu_program_type"] as? Int) == 26 else { return nil }
            let key = String(name.dropLast(".meta.json".count))
            let spirv = directory.appendingPathComponent(key + ".spv")
            return FileManager.default.fileExists(atPath: spirv.path) ? key : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prepare a game")
                            .font(.largeTitle.bold())
                        Text("Choose your own game files. Everything you import is copied into this app's private storage.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await scanUnityShaderSources() }
                        } label: {
                            Label("Inspect Unity Shader Objects", systemImage: "doc.text.magnifyingglass")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!gameExtracted || scanningShaderSources || extracting)

                        if !gameExtracted {
                            Text("After extraction, this inspects Unity shader candidates and saves a raw copy of resources.assets object 142 for local analysis.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if scanningShaderSources {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Inspecting Unity shader objects and object 142…").foregroundStyle(.secondary)
                            }
                        }
                        if !shaderSourceScanLog.isEmpty {
                            Button {
                                Task { await exportShaderSamples() }
                            } label: {
                                Label(exportingShaderSamples ? "Preparing sample bundle…" : "Export raw shader samples",
                                      systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .disabled(exportingShaderSamples || exportingNVNSplitSamples || scanningShaderSources)
                            Button {
                                Task { await exportNVNSplitSamples() }
                            } label: {
                                Label(exportingNVNSplitSamples ? "Validating and splitting…" : "Validate & split NVN graphics",
                                      systemImage: "scissors")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(exportingNVNSplitSamples || exportingShaderSamples || scanningShaderSources)
                            HStack {
                                Text("Shader scan report")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = shaderSourceScanLog
                                } label: {
                                    Label("Copy all", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }
                            Text(shaderSourceScanLog)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    fileSection(
                        title: "Step 1 · prod.keys",
                        subtitle: "Start here. No game files can be selected until this file is imported."
                    ) {
                        fileRow(
                            title: "Select prod.keys",
                            detail: keys.map { "\($0.displayName) · \($0.validationStatus ?? "Imported")" } ?? "Required · not selected",
                            selected: keys != nil
                        ) { picker = ImportPickerRequest(kind: .keys) }
                    }

                    if keys != nil {
                        fileSection(
                            title: "Step 2 · Base game",
                            subtitle: "Unlocked after prod.keys is imported. The app must identify this as an actual base game."
                        ) {
                            fileRow(
                                title: baseVerified ? "Replace base game NSP" : "Select base game NSP",
                                detail: base.map { "\($0.displayName) · \($0.validationStatus ?? "Imported")" } ?? "Required · not selected",
                                selected: baseVerified
                            ) { picker = ImportPickerRequest(kind: .base) }
                        }
                    }

                    if canChooseUpdate && !noUpdateSelected {
                        fileSection(
                            title: "Step 3 · Game update",
                            subtitle: "Select one update NSP, or explicitly continue without an update."
                        ) {
                            fileRow(
                                title: updateVerified ? "Replace update NSP" : "Select update NSP",
                                detail: update.map { "\($0.displayName) · \($0.validationStatus ?? "Imported")" } ?? "Optional · not selected",
                                selected: updateVerified
                            ) { picker = ImportPickerRequest(kind: .update) }
                            Button {
                                skipUpdate()
                            } label: {
                                Label("No update", systemImage: "forward.end")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                            }
                            .disabled(importing)
                        }
                    } else if updateVerified || noUpdateSelected {
                        completedStep(
                            title: "Step 3 · Game update",
                            detail: updateVerified ? (update?.displayName ?? "Update verified") : "Skipped · no update"
                        )
                    }

                    if canChooseDLC && !dlcSelectionFinished {
                        fileSection(
                            title: "Step 4 · DLC",
                            subtitle: "Add DLC packages one at a time. You can finish without adding any."
                        ) {
                            fileRow(
                                title: "Add one DLC NSP",
                                detail: dlc.isEmpty ? "Optional · no DLC selected" : "\(dlc.count) DLC file(s) verified · add another",
                                selected: !dlc.isEmpty
                            ) { picker = ImportPickerRequest(kind: .dlc) }

                            if !dlc.isEmpty {
                                ForEach(dlc) { item in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.displayName).lineLimit(1)
                                            Text(item.validationStatus ?? "Imported").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        Button(role: .destructive) { removeDLC(item) } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .font(.footnote)
                                }
                            }

                            Button {
                                finishDLCSelection()
                            } label: {
                                Label(dlc.isEmpty ? "No DLC" : "Done adding DLC", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                            }
                            .disabled(importing)
                        }
                    } else if dlcSelectionFinished {
                        completedStep(
                            title: "Step 4 · DLC",
                            detail: dlc.isEmpty ? "Skipped · no DLC" : "\(dlc.count) DLC file(s) selected"
                        )
                    }

                    if canExtract {
                        Button {
                            Task { await extractGame() }
                        } label: {
                            Label("Extract game files", systemImage: "archivebox")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(importing || extracting)
                    } else if dlcSelectionFinished && !dlc.isEmpty {
                        Text("The selected DLC packages will be extracted into Documents/PreparedGame/aoc as indexed RomFS images.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await testShaderTranslator() }
                    } label: {
                        Label("Survey all Cuphead vertex shaders", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!gameExtracted || testingShaderTranslator || testingMetalCompiler || testingEncoder || disassemblingModules || rewritingModules)
                    if !gameExtracted {
                        Text("Extract a game first to enable this test.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if gameExtracted {
                        Button {
                            Task { await inspectGameModules() }
                        } label: {
                            Label("Inspect NSO modules", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(extracting || inspectingModules)
                    }
                    if inspectingModules {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Inspecting ExeFS module headers…").foregroundStyle(.secondary)
                        }
                    }
                    if !inspectionLog.isEmpty {
                        Text(inspectionLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if gameExtracted {
                        Button {
                            Task { await rewriteGameModules() }
                        } label: {
                            Label("Rewrite NSO modules", systemImage: "wrench.and.screwdriver")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(extracting || inspectingModules || rewritingModules)
                    }
                    if rewritingModules {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Rebuilding NSO modules. Keep the app open…").foregroundStyle(.secondary)
                        }
                    }
                    if !rewriteLog.isEmpty {
                        Text(rewriteLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if gameExtracted {
                        Button {
                            Task { await testOnDeviceMetalCompiler() }
                        } label: {
                            Label("Test on-device Metal compiler", systemImage: "cpu")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(testingMetalCompiler || testingEncoder || disassemblingModules || rewritingModules)
                    }
                    if testingShaderTranslator {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Translating Cuphead vertex shaders on this iPhone…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !shaderTranslatorLog.isEmpty {
                        Text(shaderTranslatorLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if gameExtracted {
                        Button {
                            Task {
                                await convertCupheadShaderToMetal(
                                    key: "data-resources-assets-shader-object-138-p19-c0-s12-t26-len3936",
                                    fixture: "object=138|subprogram=12"
                                )
                            }
                        } label: {
                            Label(testingCupheadMetalShader ? "Converting and compiling object 138…" : "Convert object 138 to MSL + Metal",
                                  systemImage: "cpu")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!cupheadObject138SPIRVAvailable || testingCupheadMetalShader || testingShaderTranslator || extracting || rewritingModules)
                        if !cupheadObject138SPIRVAvailable {
                            Text("Run Inspect Unity Shader Objects and Survey all Cuphead vertex shaders first.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let object141Key = cupheadObject141SPIRVKey {
                            Button {
                                Task {
                                    await convertCupheadShaderToMetal(
                                        key: object141Key,
                                        fixture: "object=141|subprogram=8|expected=storage-buffer"
                                    )
                                }
                            } label: {
                                Label(testingCupheadMetalShader ? "Converting and compiling object 141…" : "Convert object 141 / subprogram 8 to MSL + Metal",
                                      systemImage: "externaldrive.badge.cpu")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(testingCupheadMetalShader || testingShaderTranslator || extracting || rewritingModules)
                        } else {
                            Text("Object 141 / subprogram 8 becomes available after Inspect Unity Shader Objects and Survey all Cuphead vertex shaders. The app resolves it from its Unity metadata sidecar.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if testingCupheadMetalShader {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Generating MSL and compiling it with Metal…").foregroundStyle(.secondary)
                        }
                    }
                    if !cupheadMetalShaderLog.isEmpty {
                        Text(cupheadMetalShaderLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if testingMetalCompiler {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Compiling a test Metal compute shader on this iPhone…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !metalCompilerLog.isEmpty {
                        Text(metalCompilerLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if gameExtracted {
                        Button {
                            Task { await runArm64EncoderTests() }
                        } label: {
                            Label("Test AArch64 encoders", systemImage: "function")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(testingEncoder || disassemblingModules || rewritingModules)

                        Button {
                            Task { await disassembleMainModule() }
                        } label: {
                            Label("Disassemble rewritten main NSO", systemImage: "text.alignleft")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(testingEncoder || disassemblingModules || rewritingModules)

                        Button {
                            Task { await analyzeMainModule() }
                        } label: {
                            Label("Analyze full main NSO", systemImage: "function")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(testingEncoder || disassemblingModules || rewritingModules)

                        Button {
                            Task { await discoverMainLinkerStubs() }
                        } label: {
                            Label("Discover linker stubs", systemImage: "point.3.connected.trianglepath.dotted")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(testingEncoder || disassemblingModules || rewritingModules)

                        HStack(spacing: 8) {
                            Text("Text offset")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Hex offset", text: $functionOffset)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 150)
                            Button {
                                Task { await inspectSelectedFunction() }
                            } label: {
                                Label("Inspect function", systemImage: "scope")
                            }
                            .buttonStyle(.bordered)
                            .disabled(testingEncoder || disassemblingModules || rewritingModules)
                        }
                    }
                    if testingEncoder || disassemblingModules {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(testingEncoder ? "Checking AArch64 instruction encoders…" : "Disassembling main NSO with Capstone…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !encoderTestLog.isEmpty {
                        Text(encoderTestLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !disassemblyLog.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Diagnostic report")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = disassemblyLog
                                } label: {
                                    Label("Copy Full Report", systemImage: "doc.on.doc")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                            ScrollView([.horizontal, .vertical]) {
                                Text(disassemblyLog)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(maxHeight: 320)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if importing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Copying selected file(s)…").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    if extracting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Extracting game files. Keep the app open…").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundColor(status.hasPrefix("Import failed") || status.hasPrefix("Extraction failed") ? .red : .secondary)
                    }
                    if !extractionLog.isEmpty {
                        Text(extractionLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            base?.validationStatus?.hasPrefix("Verified base game") == true && keys != nil ? "Required files verified" : "Waiting for verified required files",
                            systemImage: base?.validationStatus?.hasPrefix("Verified base game") == true && keys != nil ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.headline)
                        .foregroundStyle(base?.validationStatus?.hasPrefix("Verified base game") == true && keys != nil ? .green : .primary)

                        Text("The app verifies encrypted CNMT metadata and extracts the base game, optional update, and selected DLC. Game-specific IPA packaging is still under development.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear all", role: .destructive, action: clearAll)
                        .disabled(extracting || (base == nil && keys == nil && update == nil && dlc.isEmpty))
                }
            }
            .sheet(item: $picker) { request in
                ImportDocumentPicker(
                    extensions: request.kind.extensions,
                    allowsMultiple: request.kind.allowsMultiple,
                    onPick: { urls in
                        picker = nil
                        Task { await importFiles(urls, kind: request.kind) }
                    },
                    onCancel: { picker = nil }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingShaderSampleShare) {
                if let shaderSampleExportURL {
                    ShaderSampleActivityView(activityItems: [shaderSampleExportURL])
                }
            }
            .onAppear(perform: loadSavedFiles)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func fileSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 12)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func fileRow(
        title: String,
        detail: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "doc.badge.plus")
                    .font(.title2)
                    .foregroundColor(selected ? .green : .accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importing || extracting)
    }

    private func completedStep(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("Complete").font(.caption.bold()).foregroundStyle(.green)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func skipUpdate() {
        if let update { deleteStoredFile(update) }
        update = nil
        defaults.removeObject(forKey: "nxn.import.update")
        noUpdateSelected = true
        defaults.set(true, forKey: "nxn.import.noUpdate")
        status = "Continuing without a game update."
    }

    private func finishDLCSelection() {
        dlcSelectionFinished = true
        defaults.set(true, forKey: "nxn.import.dlcFinished")
        status = dlc.isEmpty ? "Continuing without DLC." : "DLC selection complete."
    }

    @MainActor
    private func importFiles(_ urls: [URL], kind: ImportKind) async {
        guard !urls.isEmpty else { return }
        guard urls.count == 1 else {
            status = "Import failed: Select exactly one file at a time."
            return
        }
        if kind != .keys && keys == nil {
            status = "Import failed: Import and verify prod.keys before selecting any NSP. No NSP was copied."
            return
        }
        importing = true
        status = "Importing \(urls.count) file(s)…"
        do {
            let existingKeysURL = keys.map { storedURL(for: $0) }
            let selectedBaseTitleID = base?.contentTitleID
            let imported = try await Task.detached(priority: .userInitiated) {
                // Validate every selection before copying any of them. A bad item
                // must not partially replace a previously valid selection.
                try urls.forEach { try ImportFileStorage.validate($0, kind: kind) }
                return try urls.map { source in
                    let level: String
                    if kind == .keys {
                        level = "Keys syntax checked"
                    } else if let existingKeysURL {
                        level = try ImportFileStorage.inspectContent(source, keysURL: existingKeysURL, kind: kind, baseTitleID: selectedBaseTitleID)
                    } else {
                        throw ImportValidationError.metadata("Import prod.keys before selecting NSP content.")
                    }
                    return try ImportFileStorage.copyIntoAppStorage(source, prefix: kind.prefix, validationStatus: level)
                }
            }.value

            switch kind {
            case .base:
                if let previous = base { deleteStoredFile(previous) }
                if let previous = update { deleteStoredFile(previous) }
                dlc.forEach(deleteStoredFile)
                base = imported.first
                update = nil
                dlc = []
                noUpdateSelected = false
                dlcSelectionFinished = false
                defaults.set(false, forKey: "nxn.import.noUpdate")
                defaults.set(false, forKey: "nxn.import.dlcFinished")
                defaults.removeObject(forKey: "nxn.import.update")
                defaults.removeObject(forKey: "nxn.import.dlc")
                defaults.set(base.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.base")
            case .keys:
                if let previous = keys { deleteStoredFile(previous) }
                keys = imported.first
                defaults.set(keys.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.keys")
            case .update:
                if let previous = update { deleteStoredFile(previous) }
                update = imported.first
                noUpdateSelected = false
                defaults.set(false, forKey: "nxn.import.noUpdate")
                defaults.set(update.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.update")
            case .dlc:
                dlc.append(contentsOf: imported)
                dlcSelectionFinished = false
                defaults.set(false, forKey: "nxn.import.dlcFinished")
                saveDLC()
            }
            let count = imported.count
            status = "Imported \(count) file(s)."
            if kind == .keys { await verifySavedContent() }
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
        importing = false
    }


    @MainActor
    private func extractGame() async {
        guard let keys, let base, canExtract else { return }

        extracting = true
        extractionLog = ""
        status = "Preparing a clean extraction folder…"

        let keyURL = storedURL(for: keys)
        let baseURL = storedURL(for: base)
        let updateURL = updateVerified ? update.map { storedURL(for: $0) } : nil
        let dlcURLs = dlc.map { storedURL(for: $0) }
        guard let baseTitleID = base.contentTitleID else {
            extracting = false
            status = "Extraction failed: the verified base game title ID is unavailable. Re-import the base NSP."
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let temporary = documents.appendingPathComponent("PreparedGame-\(UUID().uuidString)", isDirectory: true)
        let destination = documents.appendingPathComponent("PreparedGame", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            status = "Extracting the base game\(updateURL == nil ? "" : " and update")\(dlcURLs.isEmpty ? "" : ", plus DLC")…"
            let log = try await Task.detached(priority: .userInitiated) {
                let baseLog = try GameExtractor.extract(
                    keysURL: keyURL,
                    baseURL: baseURL,
                    updateURL: updateURL,
                    outputDirectory: temporary
                )
                let dlcLog = dlcURLs.isEmpty ? "" : try GameExtractor.extractDLCs(
                    keysURL: keyURL,
                    dlcURLs: dlcURLs,
                    baseTitleID: baseTitleID,
                    outputDirectory: temporary
                )
                _ = try ExtractionManifest.write(
                    keysURL: keyURL,
                    baseURL: baseURL,
                    updateURL: updateURL,
                    dlcURLs: dlcURLs,
                    baseTitleID: baseTitleID,
                    outputDirectory: temporary
                )
                return [baseLog, dlcLog].filter { !$0.isEmpty }.joined(separator: "\n")
            }.value

            let exefs = temporary.appendingPathComponent("ExeFS", isDirectory: true)
            let romfs = temporary.appendingPathComponent("RomFS.img")
            guard FileManager.default.fileExists(atPath: exefs.path),
                  FileManager.default.fileExists(atPath: romfs.path) else {
                throw ImportValidationError.metadata("The extractor returned success but did not create both ExeFS and RomFS.img.\n\(log)")
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDestination = destination
            try? mutableDestination.setResourceValues(values)

            extractionLog = log.isEmpty ? "Extraction completed." : log
            gameExtracted = true
            inspectionLog = ""
            status = "Extraction complete. Files are saved in Documents/PreparedGame."
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            extractionLog = error.localizedDescription
            status = "Extraction failed: \(error.localizedDescription)"
        }
        extracting = false
    }


    private func rewriteGameModules() async {
        guard gameExtracted else { return }
        rewritingModules = true
        rewriteLog = ""
        defer { rewritingModules = false }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let prepared = documents.appendingPathComponent("PreparedGame", isDirectory: true)
        let exefs = prepared.appendingPathComponent("ExeFS", isDirectory: true)
        let rewritten = prepared.appendingPathComponent("RewrittenExeFS", isDirectory: true)
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.rewriteNSOModules(exefsURL: exefs, outputURL: rewritten)
            }.value
            rewriteLog = report + "\nOutput: Documents/PreparedGame/RewrittenExeFS\nOriginal ExeFS was left unchanged. No game-specific patches were applied in this test."
        } catch {
            rewriteLog = "Rewrite failed: \(error.localizedDescription)"
        }
    }

    private func scanUnityShaderSources() async {
        guard gameExtracted else { return }
        scanningShaderSources = true
        shaderSourceScanLog = ""
        defer { scanningShaderSources = false }

        let prepared = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreparedGame", isDirectory: true)
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try UnityShaderSourceScanner.scan(preparedDirectory: prepared)
            }.value
            shaderSourceScanLog = report
        } catch {
            shaderSourceScanLog = "scan_failed|\(error.localizedDescription)"
        }
    }

    private func exportShaderSamples() async {
        guard gameExtracted, !exportingShaderSamples else { return }
        exportingShaderSamples = true
        defer { exportingShaderSamples = false }
        let prepared = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreparedGame", isDirectory: true)
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try UnityShaderSourceScanner.makeSampleExport(preparedDirectory: prepared)
            }.value
            shaderSampleExportURL = url
            showingShaderSampleShare = true
        } catch {
            shaderSourceScanLog += "\nexport_failed|\(error.localizedDescription)\n"
        }
    }

    private func exportNVNSplitSamples() async {
        guard gameExtracted, !exportingNVNSplitSamples else { return }
        exportingNVNSplitSamples = true
        defer { exportingNVNSplitSamples = false }
        let prepared = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreparedGame", isDirectory: true)
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try UnityShaderSourceScanner.makeNVNSplitExport(preparedDirectory: prepared)
            }.value
            shaderSampleExportURL = url
            showingShaderSampleShare = true
        } catch {
            shaderSourceScanLog += "\nnvn_split_failed|\(error.localizedDescription)\n"
        }
    }

    private func testShaderTranslator() async {
        testingShaderTranslator = true
        shaderTranslatorLog = ""
        defer { testingShaderTranslator = false }

        let prepared = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreparedGame", isDirectory: true)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ShaderTranslatorBridge.probe()
                let survey = try UnityShaderSourceScanner.makeNVNVertexSurveyJobs(preparedDirectory: prepared)
                var translatorExit = "zero"
                do {
                    try ShaderTranslatorBridge.translate(
                        jobFileURL: survey.jobFileURL,
                        outputDirectoryURL: survey.outputDirectoryURL
                    )
                } catch {
                    translatorExit = error.localizedDescription
                }

                func clean(_ value: String) -> String {
                    value.replacingOccurrences(of: "|", with: "_")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                }
                func resourceLines(_ rows: [[String: Any]], label: String, key: String) -> [String] {
                    rows.prefix(24).enumerated().map { index, row in
                        let fields = row.keys.sorted().compactMap { field -> String? in
                            guard let value = row[field] else { return nil }
                            return "\(field)=\(clean(String(describing: value)))"
                        }.joined(separator: ",")
                        return "resource_\(label)|key=\(key)|index=\(index)|\(fields)"
                    }
                }

                var passed: [(key: String, instructionBytes: Int, c1Bytes: Int, spvBytes: Int,
                              textures: Int, images: Int, cbufs: Int, sbufs: Int,
                              notes: String, details: [String])] = []
                var failures: [String] = []
                var metadataCount = 0
                for sample in survey.samples {
                    let spvURL = survey.outputDirectoryURL.appendingPathComponent(sample.key + ".spv")
                    let reflectionURL = survey.outputDirectoryURL.appendingPathComponent(sample.key + ".res.json")
                    let errorURL = survey.outputDirectoryURL.appendingPathComponent(sample.key + ".error.txt")
                    guard let spv = try? Data(contentsOf: spvURL),
                          spv.count >= 20,
                          Array(spv.prefix(4)) == [0x03, 0x02, 0x23, 0x07] else {
                        let detail = (try? String(contentsOf: errorURL, encoding: .utf8))?
                            .components(separatedBy: .newlines).first ?? "No valid SPIR-V output"
                        failures.append("\(sample.key): \(detail)")
                        continue
                    }
                    guard let reflectionData = try? Data(contentsOf: reflectionURL),
                          let reflection = try? JSONSerialization.jsonObject(with: reflectionData) as? [String: Any] else {
                        failures.append("\(sample.key): SPIR-V valid, but reflection JSON is missing or invalid")
                        continue
                    }
                    let textures = (reflection["textures"] as? [[String: Any]]) ?? []
                    let images = (reflection["images"] as? [[String: Any]]) ?? []
                    let cbufs = (reflection["cbufs"] as? [[String: Any]]) ?? []
                    let sbufs = (reflection["sbufs"] as? [[String: Any]]) ?? []
                    let notes = (reflection["notes"] as? [String]) ?? []
                    var details: [String] = []

                    let metadataURL = survey.outputDirectoryURL.appendingPathComponent(sample.key + ".meta.json")
                    if let metadataData = try? Data(contentsOf: metadataURL),
                       let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] {
                        metadataCount += 1
                        let objectIndex = metadata["object_index"].map { String(describing: $0) } ?? "na"
                        let subprogram = metadata["subprogram_index"].map { String(describing: $0) } ?? "na"
                        let recordVersion = metadata["record_version"].map { String(describing: $0) } ?? "na"
                        let programType = metadata["gpu_program_type"].map { String(describing: $0) } ?? "na"
                        let keywordCount = metadata["keyword_count"].map { String(describing: $0) } ?? "na"
                        let keywords = ((metadata["keywords"] as? [String]) ?? []).map(clean).joined(separator: ",")
                        details.append("unity_record|key=\(sample.key)|object_index=\(objectIndex)|subprogram_index=\(subprogram)|record_version=\(recordVersion)|gpu_program_type=\(programType)|keyword_count=\(keywordCount)|keywords=\(keywords.isEmpty ? "none" : keywords)")
                    } else {
                        details.append("unity_record|key=\(sample.key)|metadata=missing")
                    }

                    details += ShaderSPIRVReflection.report(spv, key: sample.key)
                    details += resourceLines(textures, label: "texture", key: sample.key)
                    details += resourceLines(images, label: "image", key: sample.key)
                    details += resourceLines(cbufs, label: "constant_buffer", key: sample.key)
                    details += resourceLines(sbufs, label: "storage_buffer", key: sample.key)
                    if !notes.isEmpty {
                        details.append("translator_notes|key=\(sample.key)|notes=\(clean(notes.joined(separator: "; ")))")
                    }
                    passed.append((sample.key, sample.instructionBytes, sample.c1Bytes, spv.count,
                                   textures.count, images.count, cbufs.count, sbufs.count,
                                   notes.joined(separator: "; "), details))
                }

                let ranked = passed.sorted {
                    let left = $0.textures + $0.images + $0.cbufs + $0.sbufs
                    let right = $1.textures + $1.images + $1.cbufs + $1.sbufs
                    if left != right { return left > right }
                    return $0.instructionBytes > $1.instructionBytes
                }
                let totalTextures = passed.reduce(0) { $0 + $1.textures }
                let totalImages = passed.reduce(0) { $0 + $1.images }
                let totalCBufs = passed.reduce(0) { $0 + $1.cbufs }
                let totalSBufs = passed.reduce(0) { $0 + $1.sbufs }
                var topLines: [String] = []
                for item in ranked.prefix(8) {
                    topLines.append("candidate|\(item.key)|sass_bytes=\(item.instructionBytes)|c1_bytes=\(item.c1Bytes)|spv_bytes=\(item.spvBytes)|textures=\(item.textures)|images=\(item.images)|cbufs=\(item.cbufs)|sbufs=\(item.sbufs)|notes=\(item.notes.isEmpty ? "none" : item.notes)")
                    topLines.append(contentsOf: item.details.prefix(72))
                }
                let failureLines = failures.prefix(12).map { "failure|\($0)" }
                return ([
                    "survey|\(failures.isEmpty && passed.count == survey.samples.count ? "complete" : "partial")",
                    "stage|vertex",
                    "jobs|\(survey.samples.count)",
                    "translated_valid_spirv|\(passed.count)",
                    "failed_or_invalid|\(failures.count)",
                    "resource_totals|textures=\(totalTextures), images=\(totalImages), constant_buffers=\(totalCBufs), storage_buffers=\(totalSBufs)",
                    "unity_metadata_sidecars|\(metadataCount)/\(survey.samples.count)",
                    "translator_exit|\(translatorExit)",
                    "ranking|up to 8 shaders sorted by reflected resource count, then instruction size",
                    "reflection_scope|SPIR-V input/output locations, built-ins, descriptors, and uniform/storage-buffer member offsets; translator resource records"
                ] + topLines + failureLines).joined(separator: "\n")
            }.value
            shaderTranslatorLog = result
        } catch {
            shaderTranslatorLog = "survey_failed|\(error.localizedDescription)"
        }
    }
    private func convertCupheadShaderToMetal(key: String, fixture: String) async {
        testingCupheadMetalShader = true
        cupheadMetalShaderLog = ""
        defer { testingCupheadMetalShader = false }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let survey = documents.appendingPathComponent("ShaderTranslatorVertexSurvey", isDirectory: true)
        let spirv = survey.appendingPathComponent(key + ".spv")
        let msl = survey.appendingPathComponent(key + ".metal")
        let diagnostics = survey.appendingPathComponent(key + ".spirv-cross.txt")
        let reflectionURL = survey.appendingPathComponent(key + ".res.json")
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let spirvData = try Data(contentsOf: spirv)
                try SPIRVCrossBridge.convert(input: spirv, output: msl, diagnostics: diagnostics)
                let source = try String(contentsOf: msl, encoding: .utf8)
                let library = try OnDeviceMetalCompiler.compile(source: source)
                let names = library.functionNames.sorted()
                let pipelineResult: (String, String) = {
                    do {
                        _ = try OnDeviceMetalCompiler.createFixtureRenderPipeline(
                            vertexLibrary: library,
                            vertexFunctionName: "main0"
                        )
                        return (
                            "render_pipeline|created",
                            "pipeline_vertex_layout|attribute0=float4@0,attribute1=float4@16|stride=32|step=perVertex|provisional=true"
                        )
                    } catch {
                        let detail = error.localizedDescription
                            .replacingOccurrences(of: "|", with: "_")
                            .replacingOccurrences(of: "\n", with: " ")
                        return ("render_pipeline|failed", "render_pipeline_error|\(detail)")
                    }
                }()
                let drawResult: String = {
                    do {
                        return try OnDeviceMetalCompiler.runFixtureOffscreenDraw(
                            vertexLibrary: library,
                            vertexFunctionName: "main0"
                        )
                    } catch {
                        let detail = error.localizedDescription
                            .replacingOccurrences(of: "|", with: "_")
                            .replacingOccurrences(of: "\n", with: " ")
                        return "gpu_draw|failed\ngpu_draw_error|\(detail)"
                    }
                }()
                let positionOverrideResult: String = {
                    do {
                        return try OnDeviceMetalCompiler.runFixtureOffscreenDraw(
                            vertexLibrary: library,
                            vertexFunctionName: "main0",
                            positionOverrideSource: source
                        )
                    } catch {
                        let detail = error.localizedDescription
                            .replacingOccurrences(of: "|", with: "_")
                            .replacingOccurrences(of: "\n", with: " ")
                        return "position_override_draw|failed\nposition_override_error|\(detail)"
                    }
                }()
                let diagnosticText = (try String(contentsOf: diagnostics, encoding: .utf8))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "; ")
                func clean(_ value: String) -> String {
                    value.replacingOccurrences(of: "|", with: "_")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                }
                var report = [
                    "fixture|\(fixture)",
                    "sample|\(key)",
                    "spirv_bytes|\(spirvData.count)",
                    "msl_bytes|\((try Data(contentsOf: msl)).count)",
                    "spirv_cross|\(diagnosticText)",
                    "metal_compile|success",
                    "metal_functions|\(names.isEmpty ? "none reported" : names.joined(separator: ","))",
                    "metal_library|created",
                    pipelineResult.0,
                    pipelineResult.1,
                    drawResult,
                    positionOverrideResult,
                    "pipeline_scope|render pipeline validated; offscreen GPU draw and readback reported separately"
                ]
                if let reflectionData = try? Data(contentsOf: reflectionURL),
                   let reflection = try? JSONSerialization.jsonObject(with: reflectionData) as? [String: Any] {
                    for (label, field) in [
                        ("texture", "textures"), ("image", "images"),
                        ("constant_buffer", "cbufs"), ("storage_buffer", "sbufs")
                    ] {
                        let rows = reflection[field] as? [[String: Any]] ?? []
                        report.append("translator_\(label)_count|\(rows.count)")
                        for (index, row) in rows.prefix(12).enumerated() {
                            let details = row.keys.sorted().compactMap { name -> String? in
                                guard let value = row[name] else { return nil }
                                return "\(name)=\(clean(String(describing: value)))"
                            }.joined(separator: ",")
                            report.append("translator_\(label)|index=\(index)|\(details)")
                        }
                    }
                    let notes = (reflection["notes"] as? [String] ?? []).map(clean)
                    report.append("translator_notes|\(notes.isEmpty ? "none" : notes.joined(separator: "; "))")
                } else {
                    report.append("translator_reflection|missing_or_invalid")
                }
                let structural = ShaderSPIRVReflection.report(spirvData, key: key).filter {
                    $0.hasPrefix("spirv_reflection|") ||
                    $0.hasPrefix("interface_input|") ||
                    $0.hasPrefix("interface_input_member|") ||
                    $0.hasPrefix("interface_output|") ||
                    $0.hasPrefix("interface_output_member|") ||
                    $0.hasPrefix("spirv_descriptor|") ||
                    $0.hasPrefix("spirv_buffer_layout|") ||
                    $0.hasPrefix("spirv_buffer_member|")
                }
                report.append(contentsOf: structural.prefix(48))
                // Include generated MSL in the diagnostic so a zero-pixel
                // translated draw can be traced to position/clip assignments,
                // input attribute use, and resource-dependent expressions.
                report.append("msl_source_begin")
                report.append(contentsOf: source.components(separatedBy: "\n"))
                report.append("msl_source_end")
                let drawCompleted = drawResult.contains("gpu_draw|completed")
                let nonClearPixels = drawResult.components(separatedBy: "\n")
                    .first(where: { $0.hasPrefix("draw_nonclear_pixels|") })
                    .map { String($0.dropFirst("draw_nonclear_pixels|".count)) }
                report.append("draw_output_status|\(drawCompleted ? (nonClearPixels == "0" ? "draw_completed_but_no_visible_pixels" : "draw_completed_with_visible_pixels") : "draw_not_completed")")
                report.append("scope|Metal translation, compilation, pipeline creation, offscreen draw and readback tested; synthetic inputs only; no Cuphead game rendering tested")
                return report.joined(separator: "\n")
            }.value
            cupheadMetalShaderLog = result
        } catch {
            let diagnostic = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
            cupheadMetalShaderLog = "failed|\(error.localizedDescription)" +
                (diagnostic.isEmpty ? "" : "\nspirv_cross_diagnostics|\(diagnostic)")
        }
    }

    private func testOnDeviceMetalCompiler() async {
        testingMetalCompiler = true
        metalCompilerLog = ""
        defer { testingMetalCompiler = false }

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void nxn_on_device_smoke_test(
            device uint *output [[buffer(0)]],
            uint index [[thread_position_in_grid]]
        ) {
            output[index] = index + 1;
        }
        """

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let pipeline = try OnDeviceMetalCompiler.compileComputeKernel(
                    source: source,
                    functionName: "nxn_on_device_smoke_test"
                )
                return "success|Metal compiled the test shader and created a compute pipeline.\nthread_execution_width|\(pipeline.threadExecutionWidth)\nmax_total_threads_per_threadgroup|\(pipeline.maxTotalThreadsPerThreadgroup)"
            }.value
            metalCompilerLog = result
        } catch {
            metalCompilerLog = "failed|On-device Metal compilation failed: \(error.localizedDescription)"
        }
    }

    private func runArm64EncoderTests() async {
        testingEncoder = true
        encoderTestLog = ""
        defer { testingEncoder = false }
        do {
            encoderTestLog = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.testArm64Encoder()
            }.value
        } catch {
            encoderTestLog = "Encoder self-test failed: \(error.localizedDescription)"
        }
    }

    private func analyzeMainModule() async {
        disassemblingModules = true
        disassemblyLog = ""
        defer { disassemblingModules = false }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mainModule = documents.appendingPathComponent("PreparedGame/RewrittenExeFS/main")
        guard FileManager.default.fileExists(atPath: mainModule.path) else {
            disassemblyLog = "Rewritten main NSO not found. Tap Rewrite NSO modules first."
            return
        }
        do {
            let scanReport = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.analyzeNSO(url: mainModule)
            }.value
            let prepared = documents.appendingPathComponent("PreparedGame", isDirectory: true)
            disassemblyLog = ExtractionManifest.combinedReport(
                preparedDirectory: prepared,
                extractionLog: extractionLog,
                scanReport: scanReport
            )
        } catch {
            disassemblyLog = "Full NSO analysis failed: \(error.localizedDescription)"
        }
    }

    private func discoverMainLinkerStubs() async {
        disassemblingModules = true
        disassemblyLog = ""
        defer { disassemblingModules = false }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mainModule = documents.appendingPathComponent("PreparedGame/RewrittenExeFS/main")
        guard FileManager.default.fileExists(atPath: mainModule.path) else {
            disassemblyLog = "Rewritten main NSO not found. Tap Rewrite NSO modules first."
            return
        }
        do {
            disassemblyLog = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.discoverLinkerStubs(url: mainModule)
            }.value
        } catch {
            disassemblyLog = "Linker-stub discovery failed: \(error.localizedDescription)"
        }
    }

    private func inspectSelectedFunction() async {
        let cleaned = functionOffset.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        guard let offset = UInt64(cleaned, radix: 16) else {
            disassemblyLog = "Enter a valid hexadecimal text offset, for example 00000038."
            return
        }
        disassemblingModules = true
        disassemblyLog = ""
        defer { disassemblingModules = false }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mainModule = documents.appendingPathComponent("PreparedGame/RewrittenExeFS/main")
        guard FileManager.default.fileExists(atPath: mainModule.path) else {
            disassemblyLog = "Rewritten main NSO not found. Tap Rewrite NSO modules first."
            return
        }
        do {
            disassemblyLog = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.inspectFunction(url: mainModule, textOffset: offset)
            }.value
        } catch {
            disassemblyLog = "Function inspection failed: \(error.localizedDescription)"
        }
    }

    private func disassembleMainModule() async {
        disassemblingModules = true
        disassemblyLog = ""
        defer { disassemblingModules = false }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mainModule = documents.appendingPathComponent("PreparedGame/RewrittenExeFS/main")
        guard FileManager.default.fileExists(atPath: mainModule.path) else {
            disassemblyLog = "Rewritten main NSO not found. Tap Rewrite NSO modules first."
            return
        }
        do {
            disassemblyLog = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.disassembleNSO(url: mainModule)
            }.value
        } catch {
            disassemblyLog = "Disassembly failed: \(error.localizedDescription)"
        }
    }

    private func inspectGameModules() async {
        guard gameExtracted else { return }
        inspectingModules = true
        inspectionLog = ""
        status = "Checking extracted executable modules…"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exefs = documents.appendingPathComponent("PreparedGame/ExeFS", isDirectory: true)
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try GameExtractor.inspectNSOModules(exefsURL: exefs)
            }.value
            inspectionLog = report
            status = "NSO inspection complete. No module bytes were modified."
        } catch {
            inspectionLog = error.localizedDescription
            status = "NSO inspection failed: \(error.localizedDescription)"
        }
        inspectingModules = false
    }

    private func loadSavedFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Imports", isDirectory: true)
        func existing(_ key: String, kind: ImportKind) -> ImportedGameFile? {
            guard let data = defaults.data(forKey: key),
                  let item = try? JSONDecoder().decode(ImportedGameFile.self, from: data) else { return nil }
            let url = folder.appendingPathComponent(item.storedName)
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? ImportFileStorage.validate(url, kind: kind)) != nil else {
                try? FileManager.default.removeItem(at: url)
                defaults.removeObject(forKey: key)
                return nil
            }
            return item
        }
        base = existing("nxn.import.base", kind: .base)
        keys = existing("nxn.import.keys", kind: .keys)
        update = existing("nxn.import.update", kind: .update)
        if let data = defaults.data(forKey: "nxn.import.dlc"),
           let saved = try? JSONDecoder().decode([ImportedGameFile].self, from: data) {
            dlc = saved.filter { item in
                let url = folder.appendingPathComponent(item.storedName)
                guard FileManager.default.fileExists(atPath: url.path),
                      (try? ImportFileStorage.validate(url, kind: .dlc)) != nil else {
                    try? FileManager.default.removeItem(at: url)
                    return false
                }
                return true
            }
            saveDLC()
        }
        noUpdateSelected = defaults.bool(forKey: "nxn.import.noUpdate")
        dlcSelectionFinished = defaults.bool(forKey: "nxn.import.dlcFinished")

        // Restore the extracted-game state after an app restart or update.
        // The prepared files live in Documents, while @State is reset on launch.
        let prepared = documents.appendingPathComponent("PreparedGame", isDirectory: true)
        let manifest = prepared.appendingPathComponent("extraction-manifest.txt")
        let exefs = prepared.appendingPathComponent("ExeFS", isDirectory: true)
        gameExtracted = FileManager.default.fileExists(atPath: manifest.path)
            && FileManager.default.fileExists(atPath: exefs.path)
        if gameExtracted {
            status = "Previously extracted game found in Documents/PreparedGame."
        }
        if keys != nil { Task { await verifySavedContent() } }
    }

    private func storedURL(for item: ImportedGameFile) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(item.storedName)
    }

    @MainActor
    private func verifySavedContent() async {
        guard let keys else { return }
        importing = true
        status = "Reading encrypted content metadata…"
        let keyURL = storedURL(for: keys)
        let baseSnapshot = base
        let updateSnapshot = update
        let dlcSnapshot = dlc
        let baseURL = baseSnapshot.map { storedURL(for: $0) }
        let updateURL = updateSnapshot.map { storedURL(for: $0) }
        let dlcURLs = dlcSnapshot.map { storedURL(for: $0) }
        let checked = await Task.detached(priority: .userInitiated) {
            func checkedFile(_ item: ImportedGameFile?, url: URL?, kind: ImportKind, baseTitleID: String? = nil) -> ImportedGameFile? {
                guard var item, let url else { return nil }
                do {
                    item.validationStatus = try ImportFileStorage.inspectContent(url, keysURL: keyURL, kind: kind, baseTitleID: baseTitleID)
                } catch {
                    item.validationStatus = error.localizedDescription
                }
                return item
            }
            let checkedBase = checkedFile(baseSnapshot, url: baseURL, kind: .base)
            let checkedUpdate = checkedFile(updateSnapshot, url: updateURL, kind: .update)
            let checkedDLC = dlcSnapshot.enumerated().map { index, item -> ImportedGameFile in
                checkedFile(item, url: dlcURLs[index], kind: .dlc, baseTitleID: checkedBase?.contentTitleID) ?? item
            }
            return (checkedBase, checkedUpdate, checkedDLC)
        }.value
        base = checked.0
        update = checked.1
        dlc = checked.2
        defaults.set(base.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.base")
        defaults.set(update.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.update")
        saveDLC()
        importing = false
        status = "Metadata checks finished. Review each file's status above."
    }

    private func saveDLC() {
        if let data = try? JSONEncoder().encode(dlc) {
            defaults.set(data, forKey: "nxn.import.dlc")
        }
    }

    private func removeDLC(_ item: ImportedGameFile) {
        deleteStoredFile(item)
        dlc.removeAll { $0.id == item.id }
        saveDLC()
    }

    private func clearAll() {
        [base, keys, update].compactMap { $0 }.forEach(deleteStoredFile)
        dlc.forEach(deleteStoredFile)
        base = nil; keys = nil; update = nil; dlc = []
        ["nxn.import.base", "nxn.import.keys", "nxn.import.update", "nxn.import.dlc", "nxn.import.noUpdate", "nxn.import.dlcFinished"].forEach(defaults.removeObject(forKey:))
        noUpdateSelected = false
        dlcSelectionFinished = false
        status = "Imported file selections cleared."
    }

    private func deleteStoredFile(_ item: ImportedGameFile) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Imports", isDirectory: true).appendingPathComponent(item.storedName)
        try? FileManager.default.removeItem(at: url)
    }
}

@_cdecl("dm_show_import_screen")
public func dmShowImportScreen(_ viewController: UnsafeMutableRawPointer) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let host = DmHostingController(rootView: ImportScreenView())
    host.modalPresentationStyle = .fullScreen
    parent.present(host, animated: false)
}
