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
        case fixture(String)

        var errorDescription: String? {
            switch self {
            case .noMetalDevice:
                return "This device does not provide a Metal GPU."
            case .emptySource:
                return "The translated Metal shader source is empty."
            case .missingFunction(let name):
                return "Metal compiled the source, but the requested function '\(name)' was not found."
            case .fixture(let message):
                return message
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

        let fragmentSource = positionProbe ? """
        #include <metal_stdlib>
        using namespace metal;
        struct nxn_position_probe_in {
            float4 originalPosition [[user(locn31)]];
        };
        fragment float4 nxn_fixture_fragment(nxn_position_probe_in in [[stage_in]]) {
            float4 encoded = clamp(in.originalPosition * 0.25 + 0.5, 0.0, 1.0);
            return float4(encoded.xyz, encoded.w);
        }
        """ : """
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
    /// When positionOverrideSource is supplied, compile a diagnostic copy that
    /// forces a vertex_id triangle at the end of main0. The original shader's
    /// calculations still execute, but cannot determine the final clip position.
    /// All reflected resources otherwise receive zero-filled buffers or minimal
    /// placeholders; this is not a reconstruction of Cuphead's real resource ABI.
    static func runFixtureOffscreenDraw(
        vertexLibrary: MTLLibrary,
        vertexFunctionName: String,
        positionOverrideSource: String? = nil,
        positionProbe: Bool = false,
        width: Int = 64,
        height: Int = 64,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws -> String {
        guard let device else { throw CompilerError.noMetalDevice }
        guard width > 0, height > 0, width <= 512, height <= 512 else {
            throw CompilerError.fixture("render-target dimensions must be between 1 and 512 pixels")
        }
        if let positionOverrideSource {
            var diagnosticSource = positionOverrideSource
            let stageInput = "main0_in in [[stage_in]]"
            guard diagnosticSource.contains(stageInput),
                  diagnosticSource.contains("return out;") else {
                throw CompilerError.fixture("position-override diagnostic could not locate the translated main0 input or final output")
            }
            diagnosticSource = diagnosticSource.replacingOccurrences(
                of: stageInput,
                with: stageInput + ", uint nxn_vertex_id [[vertex_id]]",
                options: [],
                range: diagnosticSource.range(of: stageInput)
            )
            // SPIRV-Cross currently lowers this runtime uint array to a one-element
            // MSL array. Expand the diagnostic copy to the 64 elements read by
            // this shader so the test does not perform out-of-bounds accesses.
            if diagnosticSource.contains("device _23& vp_s0 [[buffer(2)]]") {
                guard diagnosticSource.contains("uint _m0[1];") else {
                    throw CompilerError.fixture("storage-buffer diagnostic could not locate the one-element MSL array")
                }
                diagnosticSource = diagnosticSource.replacingOccurrences(of: "uint _m0[1];", with: "uint _m0[64];")
            }
            guard diagnosticSource.contains("    float gl_PointSize [[point_size]];\\n};") else {
                throw CompilerError.fixture("position probe could not locate the translated output structure")
            }
            diagnosticSource = diagnosticSource.replacingOccurrences(
                of: "    float gl_PointSize [[point_size]];\\n};",
                with: "    float gl_PointSize [[point_size]];\\n    float4 nxn_original_position [[user(locn31)]];\\n};"
            )
            let override = """
                    out.nxn_original_position = out.gl_Position;
                    float2 nxn_fixture_positions[3] = {
                        float2(-0.8, -0.8),
                        float2( 0.8, -0.8),
                        float2( 0.0,  0.8)
                    };
                    out.gl_Position = float4(nxn_fixture_positions[nxn_vertex_id], 0.0, 1.0);
                    return out;
            """;            guard let finalReturnRange = diagnosticSource.range(of: "return out;", options: .backwards) else {
                throw CompilerError.fixture("position-override diagnostic lost the final output return")
            }
            diagnosticSource.replaceSubrange(finalReturnRange, with: override)
            let diagnosticLibrary = try compile(source: diagnosticSource, device: device)
            let diagnosticReport = try runFixtureOffscreenDraw(
                vertexLibrary: diagnosticLibrary,
                vertexFunctionName: vertexFunctionName,
                positionProbe: true,
                width: width,
                height: height,
                device: device
            )
            let lines = diagnosticReport.components(separatedBy: "\n")
            let pixels = lines.first(where: { $0.hasPrefix("draw_nonclear_pixels|") })
                .map { String($0.dropFirst("draw_nonclear_pixels|".count)) } ?? "missing"
            let control = lines.first(where: { $0.hasPrefix("control_draw_nonclear_pixels|") })
                .map { String($0.dropFirst("control_draw_nonclear_pixels|".count)) } ?? "missing"
            let bindings = lines.first(where: { $0.hasPrefix("draw_resource_bindings|") })
                .map { String($0.dropFirst("draw_resource_bindings|".count)) } ?? "missing"
            return [
                "position_override_compile|success",
                "position_override_draw|completed",
                "position_override_nonclear_pixels|\(pixels)",
                "position_override_control_pixels|\(control)",
                "position_override_resource_bindings|\(bindings)",
                "position_probe|enabled",
                "position_probe_encoding|RGB=clamp(original_clip_xyz*0.25+0.5); alpha=clamp(original_clip_w*0.25+0.5)",
                "position_override_scope|original clip position captured before forced vertex_id triangle; original shader and resources otherwise retained"
            ].joined(separator: "\n")
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
            throw CompilerError.fixture("Metal did not return pipeline reflection")
        }
        guard #available(iOS 16.0, *) else {
            throw CompilerError.fixture("modern Metal resource reflection requires iOS 16 or later")
        }

        var resourceSummary: [String] = []
        var boundBuffers = 0
        var boundTextures = 0
        var boundSamplers = 0
        var resources = FixtureResources()
        var processedBindingIndices = Set<Int>()
        for binding in reflection.vertexBindings where binding.isUsed {
            // Metal may repeat reflection entries for the same argument-buffer
            // binding. Allocate and bind each Metal buffer index only once.
            guard processedBindingIndices.insert(binding.index).inserted else { continue }
            // Metal reserves vertex buffer index 30 for the vertex-descriptor
            // stage-in attributes configured above. It is not a reflected shader
            // resource to allocate in FixtureResources; the synthetic vertex
            // buffer is bound to this slot immediately before the draw.
            if binding.index == 30 { continue }
            if binding.isArgument {
                let argumentBuffer = try makeFixtureArgumentBuffer(
                    vertexFunction: vertexFunction,
                    bindingIndex: binding.index,
                    reflection: reflection,
                    device: device
                )
                resources.buffers[binding.index] = argumentBuffer
                resourceSummary.append("argument-buffer@\(binding.index):\(argumentBuffer.length)")
                boundBuffers += 1
                continue
            }
            switch binding.type {
            case .buffer:
                guard let bufferBinding = binding as? MTLBufferBinding else {
                    throw CompilerError.fixture("Metal did not expose buffer details for binding \(binding.index)")
                }
                let length = max(4096, bufferBinding.bufferDataSize)
                guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                    throw CompilerError.noMetalDevice
                }
                memset(buffer.contents(), 0, buffer.length)
                resourceSummary.append("buffer@\(binding.index):\(length)")
                boundBuffers += 1
                resources.buffers[binding.index] = buffer
            case .texture:
                guard let textureBinding = binding as? MTLTextureBinding else {
                    throw CompilerError.fixture("Metal did not expose texture details for binding \(binding.index)")
                }
                guard textureBinding.textureType == .type2D,
                      textureBinding.arrayLength == 1,
                      !textureBinding.isDepthTexture else {
                    throw CompilerError.fixture(
                        "offscreen fixture supports only single non-depth 2D textures; binding \(binding.index), type \(textureBinding.textureType.rawValue), array length \(textureBinding.arrayLength)"
                    )
                }
                let textureDescriptor = MTLTextureDescriptor()
                textureDescriptor.textureType = .type2D
                textureDescriptor.pixelFormat = .rgba8Unorm
                textureDescriptor.width = 1
                textureDescriptor.height = 1
                textureDescriptor.depth = 1
                textureDescriptor.mipmapLevelCount = 1
                textureDescriptor.sampleCount = 1
                textureDescriptor.arrayLength = 1
                textureDescriptor.usage = [.shaderRead]
                guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                    throw CompilerError.fixture("could not allocate placeholder texture at index \(binding.index)")
                }
                let white: [UInt8] = [255, 255, 255, 255]
                white.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: 4
                        )
                    }
                }
                resources.textures[binding.index] = texture
                resourceSummary.append("texture@\(binding.index):\(textureBinding.textureType)")
                boundTextures += 1
            case .sampler:
                let samplerDescriptor = MTLSamplerDescriptor()
                samplerDescriptor.minFilter = .linear
                samplerDescriptor.magFilter = .linear
                guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
                    throw CompilerError.noMetalDevice
                }
                resources.samplers[binding.index] = sampler
                resourceSummary.append("sampler@\(binding.index)")
                boundSamplers += 1
            default:
                throw CompilerError.fixture("unsupported reflected vertex binding type \(binding.type.rawValue) at index \(binding.index)")
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
            throw CompilerError.missingFunction("GPU command failed: \(commandBuffer.error?.localizedDescription ?? String(describing: commandBuffer.status))")
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
        // Independent known-good control triangle: generated from vertex_id,
        // so it does not depend on the translated shader or game resources.
        let controlVertexSource = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 nxn_fixture_control_vertex(uint vertexID [[vertex_id]]) {
            constexpr float2 positions[3] = {
                float2(-0.8, -0.8),
                float2( 0.8, -0.8),
                float2( 0.0,  0.8)
            };
            return float4(positions[vertexID], 0.0, 1.0);
        }
        """
        let controlVertexLibrary = try compile(source: controlVertexSource, device: device)
        guard let controlVertexFunction = controlVertexLibrary.makeFunction(name: "nxn_fixture_control_vertex") else {
            throw CompilerError.missingFunction("nxn_fixture_control_vertex")
        }
        let controlPipelineDescriptor = MTLRenderPipelineDescriptor()
        controlPipelineDescriptor.label = "Metal offscreen control triangle"
        controlPipelineDescriptor.vertexFunction = controlVertexFunction
        controlPipelineDescriptor.fragmentFunction = fragmentFunction
        controlPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        controlPipelineDescriptor.sampleCount = 1
        let controlPipeline = try device.makeRenderPipelineState(descriptor: controlPipelineDescriptor)

        let controlTargetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        controlTargetDescriptor.usage = [.renderTarget, .shaderRead]
        controlTargetDescriptor.storageMode = .shared
        guard let controlTarget = device.makeTexture(descriptor: controlTargetDescriptor),
              let controlCommandBuffer = queue.makeCommandBuffer() else {
            throw CompilerError.noMetalDevice
        }
        let controlPass = MTLRenderPassDescriptor()
        controlPass.colorAttachments[0].texture = controlTarget
        controlPass.colorAttachments[0].loadAction = .clear
        controlPass.colorAttachments[0].storeAction = .store
        controlPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let controlEncoder = controlCommandBuffer.makeRenderCommandEncoder(descriptor: controlPass) else {
            throw CompilerError.noMetalDevice
        }
        controlEncoder.setRenderPipelineState(controlPipeline)
        controlEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        controlEncoder.endEncoding()
        controlCommandBuffer.commit()
        controlCommandBuffer.waitUntilCompleted()
        guard controlCommandBuffer.status == .completed, controlCommandBuffer.error == nil else {
            throw CompilerError.fixture("control GPU command failed: \(controlCommandBuffer.error?.localizedDescription ?? String(describing: controlCommandBuffer.status))")
        }
        var controlPixels = Data(count: rowBytes * height)
        controlPixels.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress {
                controlTarget.getBytes(base, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        let controlNonClearPixels = controlPixels.withUnsafeBytes { raw -> Int in
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
            "draw_dimensions|\(width)x\(height)",
            "draw_primitives|triangle",
            "draw_vertex_count|3",
            "draw_bound_vertex_resources|buffers=\(boundBuffers),textures=\(boundTextures),samplers=\(boundSamplers)",
            "draw_resource_bindings|\(resourceSummary.isEmpty ? "none" : resourceSummary.sorted().joined(separator: ","))",
            "draw_readback|success",
            "draw_nonclear_pixels|\(nonClearPixels)",
            "control_draw|completed",
            "control_draw_readback|success",
            "control_draw_nonclear_pixels|\(controlNonClearPixels)",
            "control_draw_scope|known-good vertex_id triangle and white fragment; independent of translated shader",
            "draw_scope|synthetic vertex data and placeholder resources; not Cuphead's real buffers or textures"
        ].joined(separator: "\n")
    }

    /// Build the synthetic argument buffer used by the offscreen fixture.
    ///
    /// Current fixtures expose inline float4 arrays and a uint array in the
    /// reflected argument-buffer layouts. Inline constants are written with
    /// MTLArgumentEncoder.constantData(at:), not treated as resource handles.
    /// Real game constants are not available in this smoke test, so this
    /// intentionally zero-fills the inline data while preserving its layout.
    private static func makeFixtureArgumentBuffer(
        vertexFunction: MTLFunction,
        bindingIndex: Int,
        reflection: MTLRenderPipelineReflection,
        device: MTLDevice
    ) throws -> MTLBuffer {
        guard let argument = reflection.vertexArguments?.first(where: { $0.index == bindingIndex }),
              let structure = argument.bufferStructType else {
            throw CompilerError.fixture("argument-buffer layout unavailable at vertex binding index \(bindingIndex)")
        }
        let argumentEncoder = vertexFunction.makeArgumentEncoder(bufferIndex: bindingIndex)

        let expectedDataMembers = structure.members.filter { $0.arrayType() != nil }
        guard !expectedDataMembers.isEmpty,
              expectedDataMembers.count == structure.members.count else {
            let details = argumentBufferSummary(bindingIndex: bindingIndex, reflection: reflection)
            throw CompilerError.fixture("argument buffer contains unsupported non-inline members; \(details)")
        }

        let allocationLength = max(argumentEncoder.encodedLength, argument.bufferDataSize)
        guard allocationLength > 0,
              let buffer = device.makeBuffer(length: allocationLength, options: .storageModeShared) else {
            throw CompilerError.fixture("could not allocate argument buffer at vertex binding index \(bindingIndex)")
        }
        memset(buffer.contents(), 0, buffer.length)
        argumentEncoder.setArgumentBuffer(buffer, offset: 0)

        for member in expectedDataMembers {
            guard let array = member.arrayType(),
                  array.argumentIndexStride == 0,
                  array.elementType == .float4 || array.elementType == .uint else {
                let details = argumentBufferSummary(bindingIndex: bindingIndex, reflection: reflection)
                throw CompilerError.fixture("unsupported inline argument data at vertex binding index \(bindingIndex); \(details)")
            }
            let (byteCount, overflow) = array.stride.multipliedReportingOverflow(by: array.arrayLength)
            guard !overflow, byteCount > 0, byteCount <= buffer.length else {
                throw CompilerError.fixture("invalid inline argument-data size at vertex binding index \(bindingIndex)")
            }
            let destination = argumentEncoder.constantData(at: member.argumentIndex)
            memset(destination, 0, byteCount)
        }
        return buffer
    }

    /// Describe the reflected argument-buffer table for diagnostic output.
    private static func argumentBufferSummary(
        bindingIndex: Int,
        reflection: MTLRenderPipelineReflection
    ) -> String {
        guard let argument = reflection.vertexArguments?.first(where: { $0.index == bindingIndex }) else {
            return "argument_layout=unavailable"
        }
        guard let structure = argument.bufferStructType else {
            return "argument_name=\(argument.name),argument_type=\(argument.bufferDataType.rawValue),members=unavailable"
        }
        let members = structure.members.map { member -> String in
            if let array = member.arrayType() {
                return "\(member.name):type=array:element=\(array.elementType.rawValue):length=\(array.arrayLength):stride=\(array.stride):argument_id_stride=\(array.argumentIndexStride):id=\(member.argumentIndex):offset=\(member.offset)"
            }
            if let pointer = member.pointerType() {
                return "\(member.name):type=pointer:element=\(pointer.elementType.rawValue):size=\(pointer.dataSize):alignment=\(pointer.alignment):id=\(member.argumentIndex):offset=\(member.offset)"
            }
            if let nested = member.structType() {
                return "\(member.name):type=struct:nested_members=\(nested.members.count):id=\(member.argumentIndex):offset=\(member.offset)"
            }
            return "\(member.name):type=\(member.dataType.rawValue):id=\(member.argumentIndex):offset=\(member.offset)"
        }
        return "argument_name=\(argument.name),argument_size=\(argument.bufferDataSize),members=[\(members.joined(separator: ","))]"
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
