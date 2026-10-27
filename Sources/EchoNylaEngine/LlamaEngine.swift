import CoreGraphics
import Darwin
import Foundation
import llama

/// The two files of an installed model: its weights and its picture reader (projector).
public struct ModelPaths: Equatable, Sendable {
    public var model: URL
    public var projector: URL

    public init(model: URL, projector: URL) {
        self.model = model
        self.projector = projector
    }
}

/// A picture for the model, as plain RGB bytes.
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    /// Draws `image` into RGB, shrunk so its longer side is at most `maxSide` pixels. The model
    /// reads pictures in small tiles; bigger pictures only cost time.
    public init?(_ image: CGImage, maxSide: Int = 1_280) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        self.width = width
        self.height = height
        self.bytes = rgb
    }
}

/// What came back from one question.
public struct EngineReply: Sendable {
    public var text: String
    public var promptTokens: Int
    public var generatedTokens: Int
    /// Time for this question, including loading the model if it wasn't loaded.
    public var seconds: Double
    /// The most memory EchoNyla has used so far (what Activity Monitor calls Memory), in bytes.
    public var peakMemoryBytes: UInt64
}

public enum EngineError: LocalizedError {
    case modelDidNotLoad
    case pictureReaderDidNotLoad
    case contextDidNotStart
    case badGrammar
    case pictureNotRead(Int32)
    case evaluationFailed(Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelDidNotLoad: return "The on-device model couldn't be loaded."
        case .pictureReaderDidNotLoad: return "The model's picture reader couldn't be loaded."
        case .contextDidNotStart: return "The on-device model couldn't start."
        case .badGrammar: return "The answer format couldn't be set up."
        case .pictureNotRead(let code): return "The picture couldn't be read (error \(code))."
        case .evaluationFailed(let code): return "The model stopped with error \(code)."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Runs the on-device model with llama.cpp. One question at a time, on its own queue. The model is
/// loaded on the first question and let go after a minute without questions, so it uses no
/// memory while EchoNyla isn't sorting.
public final class LlamaEngine: @unchecked Sendable {
    public static let shared = LlamaEngine()

    public struct Options: Sendable {
        /// Layers on the Mac's graphics chip: -1 for all of them, 0 to run on the processor only.
        public var gpuLayers: Int32 = -1
        public var contextTokens: UInt32 = 6_144
        /// Prism's recommendation for light Mac use: pictures are shrunk to at most this many tokens.
        public var imageMaxTokens: Int32 = 1_024
        public var maxAnswerTokens = 320
        public var idleUnloadSeconds: Double = 60

        public init() {}
    }

    public var options = Options()
    private let queue = DispatchQueue(label: "EchoNyla.LlamaEngine", qos: .userInitiated)
    private var loadedPaths: ModelPaths?
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vision: OpaquePointer?
    private var idleUnload: DispatchWorkItem?
    private let cancelLock = NSLock()
    private var cancelRequested = false
    private static let backendStarted: Bool = {
        llama_log_set({ _, _, _ in }, nil)
        mtmd_helper_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        return true
    }()

    public init() {}

    /// Stops the question being answered, if any.
    public func cancel() {
        setCancelled(true)
    }

    /// Lets go of the model now.
    public func unload() {
        queue.async { self.freeModel() }
    }

    /// Asks one question. `prompt` is the whole conversation; when `image` is given, `prompt`
    /// must contain the picture marker (`marker`) exactly once. `grammar` fixes the answer's shape.
    public func generate(paths: ModelPaths, prompt: String, image: RGBImage?, grammar: String) async throws -> EngineReply {
        setCancelled(false)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(paths: paths, prompt: prompt, image: image, grammar: grammar))
                } catch {
                    continuation.resume(throwing: error)
                }
                self.scheduleIdleUnload()
            }
        }
    }

    /// The text that marks where the picture goes in a prompt.
    public static var marker: String { String(cString: mtmd_default_marker()) }

    // MARK: On the engine's queue

    private func run(paths: ModelPaths, prompt: String, image: RGBImage?, grammar: String) throws -> EngineReply {
        let started = Date()
        idleUnload?.cancel()
        try load(paths)
        guard let model, let context, let vision else { throw EngineError.modelDidNotLoad }
        let vocab = llama_model_get_vocab(model)

        llama_memory_clear(llama_get_memory(context), true)

        // The prompt and picture, split into text and picture chunks, then read by the model.
        guard let chunks = mtmd_input_chunks_init() else { throw EngineError.contextDidNotStart }
        defer { mtmd_input_chunks_free(chunks) }
        var bitmap: OpaquePointer?
        if let image {
            bitmap = image.bytes.withUnsafeBufferPointer { buffer in
                mtmd_bitmap_init(UInt32(image.width), UInt32(image.height), buffer.baseAddress)
            }
        }
        defer { if let bitmap { mtmd_bitmap_free(bitmap) } }
        let tokenized: Int32 = prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: strlen(text), add_special: true, parse_special: true)
            if let bitmap {
                var bitmaps: [OpaquePointer?] = [bitmap]
                return bitmaps.withUnsafeMutableBufferPointer { pointer in
                    mtmd_tokenize(vision, chunks, &input, pointer.baseAddress, 1)
                }
            }
            return mtmd_tokenize(vision, chunks, &input, nil, 0)
        }
        guard tokenized == 0 else { throw EngineError.pictureNotRead(tokenized) }
        let promptTokens = Int(mtmd_helper_get_n_tokens(chunks))

        var position: llama_pos = 0
        let evaluated = mtmd_helper_eval_chunks(vision, context, chunks, 0, 0, 512, true, &position)
        guard evaluated == 0 else { throw EngineError.evaluationFailed(evaluated) }

        // The answer, one token at a time, kept to the grammar.
        guard let sampler = makeSampler(vocab: vocab, grammar: grammar) else { throw EngineError.badGrammar }
        defer { llama_sampler_free(sampler) }
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var output: [UInt8] = []
        var generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        while generated < options.maxAnswerTokens {
            if isCancelled() { throw EngineError.cancelled }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length > 0 { output += piece[0..<Int(length)].map { UInt8(bitPattern: $0) } }
            generated += 1

            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            position += 1
            let result = llama_decode(context, batch)
            guard result == 0 else { throw EngineError.evaluationFailed(result) }
        }
        return EngineReply(text: String(decoding: output, as: UTF8.self), promptTokens: promptTokens, generatedTokens: generated,
                           seconds: Date().timeIntervalSince(started), peakMemoryBytes: Self.peakMemory())
    }

    /// Prism's sampling for Bonsai 2 with thinking off (temperature 0.7, top-p 0.8, top-k 20,
    /// presence penalty 1.5 over 64 tokens), behind the grammar. A fixed seed keeps answers repeatable.
    private func makeSampler(vocab: OpaquePointer?, grammar: String) -> UnsafeMutablePointer<llama_sampler>? {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
        guard let constrained = llama_sampler_init_grammar(vocab, grammar, "root") else {
            llama_sampler_free(chain)
            return nil
        }
        llama_sampler_chain_add(chain, constrained)
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.0, 0.0, 1.5))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.8, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(42))
        return chain
    }

    private func load(_ paths: ModelPaths) throws {
        if loadedPaths == paths, model != nil, context != nil, vision != nil { return }
        freeModel()
        _ = Self.backendStarted
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = options.gpuLayers
        guard let loaded = llama_model_load_from_file(paths.model.path, modelParams) else { throw EngineError.modelDidNotLoad }
        model = loaded

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = options.contextTokens
        contextParams.n_batch = 2_048
        contextParams.n_ubatch = 512
        let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let started = llama_init_from_model(loaded, contextParams) else {
            freeModel()
            throw EngineError.contextDidNotStart
        }
        context = started

        var visionParams = mtmd_context_params_default()
        visionParams.use_gpu = options.gpuLayers != 0
        visionParams.n_threads = threads
        visionParams.print_timings = false
        visionParams.warmup = false
        visionParams.image_max_tokens = options.imageMaxTokens
        guard let reader = mtmd_init_from_file(paths.projector.path, loaded, visionParams) else {
            freeModel()
            throw EngineError.pictureReaderDidNotLoad
        }
        vision = reader
        loadedPaths = paths
    }

    private func freeModel() {
        idleUnload?.cancel()
        idleUnload = nil
        if let vision { mtmd_free(vision) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        vision = nil
        context = nil
        model = nil
        loadedPaths = nil
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.freeModel() }
        idleUnload = work
        queue.asyncAfter(deadline: .now() + options.idleUnloadSeconds, execute: work)
    }

    private func setCancelled(_ value: Bool) {
        cancelLock.lock()
        cancelRequested = value
        cancelLock.unlock()
    }

    private func isCancelled() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    /// The most memory this process has used, including the model's memory on the graphics chip.
    public static func peakMemory() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return max(UInt64(max(0, info.ledger_phys_footprint_peak)), info.phys_footprint)
    }
}
