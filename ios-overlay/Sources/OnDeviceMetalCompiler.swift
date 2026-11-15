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

    /// Execute a translated vertex shader in a small offscreen render pass.
    ///
    /// All reflected vertex-stage resources receive zero-filled buffers or
    /// minimal placeholder textures/samplers. This is an execution smoke test,
    /// not a reconstruction of Cuphead's real resource contents or ABI.
    static func runFixtureOffscreenDraw(
        vertexLibrary: MTLLibrary,
        vertexFunctionName: String,
        width: Int = 64,
        height: Int = 64,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws -> String {
        guard let device else { throw CompilerError.noMetalDevice }
        guard width > 0, height > 0, width <= 512, height <= 512 else {
            throw CompilerError.emptySource
        }
        guard device.maxVertexBufferBindCount > 30 else {
            throw CompilerError.missingFunction("Metal device has no free vertex-buffer slot 30")
        }
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
        vertexDescriptor.attributes[0].bufferIndex = 30
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = 16
        vertexDescriptor.attributes[1].bufferIndex = 30
        vertexDescriptor.layouts[30].stride = 32
        vertexDescriptor.layouts[30].stepFunction = .perVertex
        vertexDescriptor.layouts[30].stepRate = 1

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Cuphead offscreen execution fixture"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.sampleCount = 1
        var reflection: MTLRenderPipelineReflection?
        let pipeline = try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor,
            options: [.argumentInfo, .bufferTypeInfo],
            reflection: &reflection
        )
        guard let reflection else {
            throw CompilerError.missingFunction("Metal pipeline reflection")
        }

        var resourceSummary: [String] = []
        var boundBuffers = 0
        var boundTextures = 0
        var boundSamplers = 0
        var resources = FixtureResources()
        for argument in reflection.vertexArguments {
            guard argument.arrayLength == 1 else {
                throw CompilerError.missingFunction("Unsupported resource array at vertex argument index \\(argument.index)")
            }
            switch argument.type {
            case .buffer:
                guard argument.index != 30 else {
                    throw CompilerError.missingFunction("Vertex resource uses reserved attribute buffer slot 30")
                }
                let length = max(4096, argument.bufferDataSize)
                guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                    throw CompilerError.noMetalDevice
                }
                memset(buffer.contents(), 0, buffer.length)
                pipelineDescriptor.label = "Cuphead offscreen execution fixture"
                resourceSummary.append("buffer@\\(argument.index):\\(length)")
                boundBuffers += 1
                // The encoder is created below; retain the resource until binding.
                resources.buffers[argument.index] = buffer
            case .texture:
                let textureDescriptor = MTLTextureDescriptor()
                textureDescriptor.textureType = argument.textureType
                textureDescriptor.pixelFormat = .rgba8Unorm
                textureDescriptor.width = 1
                textureDescriptor.height = 1
                textureDescriptor.depth = 1
                textureDescriptor.mipmapLevelCount = 1
                textureDescriptor.sampleCount = 1
                textureDescriptor.arrayLength = argument.textureType == .typeCube ? 6 : max(1, argument.arrayLength)
                textureDescriptor.usage = [.shaderRead]
                guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                    throw CompilerError.missingFunction("Could not allocate placeholder texture at index \\(argument.index), type \\(argument.textureType.rawValue)")
                }
                var white: [UInt8] = [255, 255, 255, 255]
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0,
                    withBytes: &white,
                    bytesPerRow: 4
                )
                resources.textures[argument.index] = texture
                resourceSummary.append("texture@\\(argument.index):\\(argument.textureType)")
                boundTextures += 1
            case .sampler:
                let samplerDescriptor = MTLSamplerDescriptor()
                samplerDescriptor.minFilter = .linear
                samplerDescriptor.magFilter = .linear
                guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
                    throw CompilerError.noMetalDevice
                }
                resources.samplers[argument.index] = sampler
                resourceSummary.append("sampler@\\(argument.index)")
                boundSamplers += 1
            default:
                throw CompilerError.missingFunction("Unsupported reflected vertex resource type \\(argument.type.rawValue) at index \\(argument.index)")
            }
        }

        let vertexValues: [Float] = [
            -0.8, -0.8, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
             0.8, -0.8, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
             0.0,  0.8, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0
        ]
        let vertexBuffer: MTLBuffer? = vertexValues.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
        guard let vertexBuffer else { throw CompilerError.noMetalDevice }

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDescriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw CompilerError.noMetalDevice
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw CompilerError.noMetalDevice
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 30)
        for (index, buffer) in resources.buffers { encoder.setVertexBuffer(buffer, offset: 0, index: index) }
        for (index, texture) in resources.textures { encoder.setVertexTexture(texture, index: index) }
        for (index, sampler) in resources.samplers { encoder.setVertexSamplerState(sampler, index: index) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            throw CompilerError.missingFunction("GPU command failed: \\(commandBuffer.error?.localizedDescription ?? String(describing: commandBuffer.status))")
        }

        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress {
                target.getBytes(base, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        let nonClearPixels = pixels.withUnsafeBytes { raw -> Int in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            var count = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    if bytes[offset] > 16 || bytes[offset + 1] > 16 || bytes[offset + 2] > 16 {
                        count += 1
                    }
                }
            }
            return count
        }
        return [
            "gpu_draw|completed",
            "draw_dimensions|\\(width)x\\(height)",
            "draw_primitives|triangle",
            "draw_vertex_count|3",
            "draw_bound_vertex_resources|buffers=\\(boundBuffers),textures=\\(boundTextures),samplers=\\(boundSamplers)",
            "draw_resource_bindings|\\(resourceSummary.isEmpty ? "none" : resourceSummary.sorted().joined(separator: ","))",
            "draw_readback|success",
            "draw_nonclear_pixels|\\(nonClearPixels)",
            "draw_scope|synthetic vertex data and placeholder resources; not Cuphead's real buffers or textures"
        ].joined(separator: "\\n")
    }

    private struct FixtureResources {
        var buffers: [Int: MTLBuffer] = [:]
        var textures: [Int: MTLTexture] = [:]
        var samplers: [Int: MTLSamplerState] = [:]
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
