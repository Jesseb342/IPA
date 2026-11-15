import Foundation
import Darwin

/// Thin loader for the statically linked SPIRV-Cross C API framework.
enum SPIRVCrossBridge {
    typealias ConvertFunction = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32

    private final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: UnsafeMutableRawPointer?
        private var convertFunction: ConvertFunction?

        func function() throws -> ConvertFunction {
            lock.lock()
            defer { lock.unlock() }
            if let convertFunction { return convertFunction }

            let binary = Bundle.main.bundleURL.appendingPathComponent("Frameworks/NxNativeSPIRVCross.framework/NxNativeSPIRVCross")
            guard FileManager.default.fileExists(atPath: binary.path) else {
                throw NSError(domain: "SPIRVCrossBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "The embedded SPIRV-Cross framework is missing."])
            }
            guard let library = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw NSError(domain: "SPIRVCrossBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not load SPIRV-Cross: \(detail)"])
            }
            guard let symbol = dlsym(library, "nxn_spirv_to_msl_file") else {
                let detail = dlerror().map { String(cString: $0) } ?? "conversion symbol missing"
                dlclose(library)
                throw NSError(domain: "SPIRVCrossBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            handle = library
            let function = unsafeBitCast(symbol, to: ConvertFunction.self)
            convertFunction = function
            return function
        }
    }

    private static let loader = Loader()

    static func convert(input: URL, output: URL, diagnostics: URL) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path + "/"
        for url in [input, output, diagnostics] {
            guard url.standardizedFileURL.path.hasPrefix(documents) else {
                throw NSError(domain: "SPIRVCrossBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "SPIR-V input and MSL outputs must remain in this app's Documents folder."])
            }
        }
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw NSError(domain: "SPIRVCrossBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "SPIR-V input is missing. Run the vertex survey first."])
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let convert = try loader.function()
        let code = input.path.withCString { src in
            output.path.withCString { dst in
                diagnostics.path.withCString { log in convert(src, dst, log) }
            }
        }
        guard code == 0 else {
            let detail = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "SPIRV-Cross conversion failed (\(code))."
            throw NSError(domain: "SPIRVCrossBridge", code: Int(code), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}
