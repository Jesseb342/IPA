import Foundation
import Metal

/// Compiles translated Metal Shading Language on the iPhone itself.
///
/// The upstream shader translator still needs to be ported. This component is
/// the device-side final stage: once the translator produces MSL text, iOS
/// compiles that text into a Metal library without a Mac or network service.
enum OnDeviceMetalCompiler {
    enum CompilerError: LocalizedError {
        case noMetalDevice
        case emptySource
        case missingFunction(String)

        var errorDescription: String? {
            switch self {
            case .noMetalDevice:
                return "This device does not provide a Metal GPU."
            case .emptySource:
                return "The translated Metal shader source is empty."
            case .missingFunction(let name):
                return "Metal compiled the source, but the requested function '\(name)' was not found."
            }
        }
    }

    /// Compile MSL source using the current device's Metal compiler.
    /// The returned library remains local to this process and can be used to
    /// create render or compute pipeline states.
    static func compile(source: String, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> MTLLibrary {
        guard let device else { throw CompilerError.noMetalDevice }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompilerError.emptySource
        }

        let options = MTLCompileOptions()
        return try device.makeLibrary(source: source, options: options)
    }

    /// Compile a translated compute shader and create a pipeline state.
    /// This exercises both MSL compilation and the A15 GPU's compute pipeline
    /// validation without requiring a game or an upstream translator.
    static func compileComputeKernel(
        source: String,
        functionName: String,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws -> MTLComputePipelineState {
        guard let device else { throw CompilerError.noMetalDevice }
        let library = try compile(source: source, device: device)
        guard let function = library.makeFunction(name: functionName) else {
            throw CompilerError.missingFunction(functionName)
        }
        return try device.makeComputePipelineState(function: function)
    }

    /// Create a render-pipeline state around a translated vertex function.
    ///
    /// The two float4 attributes mirror current SPIR-V reflection only. Their
    /// actual Cuphead vertex-buffer formats and stride remain unverified.
    /// This validates pipeline compatibility; it does not submit a draw.
    static func createFixtureRenderPipeline(
        vertexLibrary: MTLLibrary,
        vertexFunctionName: String,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws -> MTLRenderPipelineState {
        guard let device else { throw CompilerError.noMetalDevice }
        guard let vertexFunction = vertexLibrary.makeFunction(name: vertexFunctionName) else {
            throw CompilerError.missingFunction(vertexFunctionName)
        }

        let fragmentSource = """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 nxn_fixture_fragment() {
            return float4(1.0, 1.0, 1.0, 1.0);
        }
        """
        let fragmentLibrary = try compile(source: fragmentSource, device: device)
        guard let fragmentFunction = fragmentLibrary.makeFunction(name: "nxn_fixture_fragment") else {
            throw CompilerError.missingFunction("nxn_fixture_fragment")
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = 16
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 32
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stepRate = 1

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Cuphead translated vertex fixture"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.sampleCount = 1
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Save translated MSL as a local cache input. The source is retained so
    /// the app can rebuild its Metal library after an app restart or OS update.
    @discardableResult
    static func cacheSource(_ source: String, named fileName: String, in directory: URL) throws -> URL {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompilerError.emptySource
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let destination = directory.appendingPathComponent(safeName).appendingPathExtension("metal")
        try source.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    static func compile(fileAt url: URL, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> MTLLibrary {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try compile(source: source, device: device)
    }
}
