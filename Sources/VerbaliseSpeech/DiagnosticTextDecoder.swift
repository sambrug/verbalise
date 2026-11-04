import Foundation
import CoreML
import ArgmaxCore
import WhisperKit
import VerbaliseCore

/// Observe the existing decoder without changing its inputs, retries or results.
/// Composition is necessary because WhisperKit's decodeText is not overridable.
final class DiagnosticTextDecoder: TextDecoding, WhisperMLModel {
    private let base = TextDecoder()
    var model: MLModel? { get { base.model } set { base.model = newValue } }
    var tokenizer: WhisperTokenizer? { get { base.tokenizer } set { base.tokenizer = newValue } }
    var isModelMultilingual: Bool { get { base.isModelMultilingual } set { base.isModelMultilingual = newValue } }
    var logitsFilters: [any LogitsFiltering]? { get { base.logitsFilters } set { base.logitsFilters = newValue } }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func loadModel(at path: URL, computeUnits: MLComputeUnits, prewarmMode: Bool) async throws {
        try await base.loadModel(at: path, computeUnits: computeUnits, prewarmMode: prewarmMode)
    }
    func unloadModel() { base.unloadModel() }
    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? {
        try await base.predictLogits(inputs)
    }
    func prepareDecoderInputs(withPrompt prompt: [Int]) throws -> any DecodingInputsType {
        try base.prepareDecoderInputs(withPrompt: prompt)
    }
    func prefillDecoderInputs(_ inputs: any DecodingInputsType, withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await base.prefillDecoderInputs(inputs, withOptions: options)
    }
    func detectLanguage(from output: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                        sampler: TokenSampling, options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
        try await base.detectLanguage(from: output, using: inputs, sampler: sampler, options: options, temperature: temperature)
    }
    static func updateKVCache(keyTensor: MLMultiArray, keySlice: MLMultiArray,
                              valueTensor: MLMultiArray, valueSlice: MLMultiArray, insertAtIndex index: Int) {
        TextDecoder.updateKVCache(keyTensor: keyTensor, keySlice: keySlice,
                                  valueTensor: valueTensor, valueSlice: valueSlice, insertAtIndex: index)
    }
    func decodeText(from output: any AudioEncoderOutputType, using inputs: any DecodingInputsType,
                    sampler: TokenSampling, options: DecodingOptions,
                    callback: TranscriptionCallback?) async throws -> DecodingResult {
        let started = Diagnostics.now
        let attempt = DecodeTelemetry.current?.begin() ?? 0
        log("decode: attempt_start number=\(attempt) prefill_tokens=\(inputs.initialPrompt.count)")
        do {
            let result = try await base.decodeText(from: output, using: inputs, sampler: sampler, options: options, callback: callback)
            let retry = result.temperature > options.temperature
            DecodeTelemetry.current?.complete(isRetry: retry)
            log(String(format: "decode: attempt_end number=%d elapsed_s=%.3f temperature=%.2f retry_attempt=%@ retry_requested=%@ reason=%@ avg_logprob=%.3f no_speech_prob=%.3f compression=%.3f loops=%.0f prediction_s=%.3f sampling_s=%.3f cache_s=%.3f",
                       attempt, Diagnostics.now - started, result.temperature, String(retry),
                       String(result.fallback?.needsFallback ?? false), result.fallback?.fallbackReason ?? "accepted",
                       result.avgLogProb, result.noSpeechProb, result.compressionRatio,
                       result.timings?.totalDecodingLoops ?? 0, result.timings?.decodingPredictions ?? 0,
                       result.timings?.decodingSampling ?? 0, result.timings?.decodingKvCaching ?? 0))
            return result
        } catch {
            log("decode: attempt_error number=\(attempt) elapsed_s=\(Diagnostics.now - started) error=\(error)")
            throw error
        }
    }
}

/// Per-call counters, shared only by that call's child tasks, never by the model.
final class DecodeTelemetry: @unchecked Sendable {
    @TaskLocal static var current: DecodeTelemetry?
    private let lock = NSLock()
    private var attempts = 0
    private var retries = 0
    func begin() -> Int { lock.withLock { attempts += 1; return attempts } }
    func complete(isRetry: Bool) { lock.withLock { if isRetry { retries += 1 } } }
    var counts: (attempts: Int, retries: Int) { lock.withLock { (attempts, retries) } }
}
