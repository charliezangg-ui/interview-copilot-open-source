import Foundation
import SherpaOnnxC

public struct ASRText: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool
}

public enum Hotwords {
    public static let defaults = "Agent\nAPI\nWorkflow\nCoze\nEino\nKubernetes\nPostgreSQL\nRedis\nPython\nTypeScript"
    /// Raw phrases only; strip the decoder's score/control syntax and bound per-session context.
    public static func normalize(_ input: String) -> String {
        var seen = Set<String>()
        return input.components(separatedBy: CharacterSet(charactersIn: "\n,，;；"))
            .compactMap { line -> String? in
                let value = line.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || " -_.+".unicodeScalars.contains($0) }
                let term = String(String.UnicodeScalarView(value)).trimmingCharacters(in: .whitespaces).uppercased()
                guard !term.isEmpty, term.count <= 64, seen.insert(term).inserted else { return nil }
                return term
            }.prefix(64).joined(separator: "\n")
    }
}

public enum PCM16 {
    public static func floats(_ data: Data) throws -> [Float] {
        guard data.count % 2 == 0 else { throw ASRError.message("音频 PCM 数据不完整，本段转写已停止。") }
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 2).map { i in
                Float(Int16(bitPattern: UInt16(raw[i]) | UInt16(raw[i + 1]) << 8)) / 32768
            }
        }
    }
}

/// Owns one recognizer and one stream. Call on one serial worker, never on the UI thread.
public final class ZipformerDecoder {
    private let recognizer: OpaquePointer
    private let stream: OpaquePointer
    private var previous = ""
    private var finished = false
    private var inputRate: Int?
    public init(directory: URL = LocalModelStore.directory, hotwords: String = Hotwords.defaults) throws {
        try LocalModelStore.validate(at: directory)
        var pointers: [UnsafeMutablePointer<CChar>] = []
        func c(_ text: String) -> UnsafePointer<CChar> {
            let pointer = strdup(text)!; pointers.append(pointer); return UnsafePointer(pointer)
        }
        defer { pointers.forEach { free($0) } }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(directory.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path)
        config.model_config.transducer.decoder = c(directory.appendingPathComponent("decoder-epoch-99-avg-1.onnx").path)
        config.model_config.transducer.joiner = c(directory.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path)
        config.model_config.tokens = c(directory.appendingPathComponent("tokens.txt").path)
        config.model_config.bpe_vocab = c(directory.appendingPathComponent("bpe.vocab").path)
        config.model_config.modeling_unit = c("cjkchar+bpe")
        config.model_config.provider = c("cpu"); config.model_config.num_threads = 2
        config.decoding_method = c("modified_beam_search"); config.max_active_paths = 4
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4; config.rule2_min_trailing_silence = 1.2
        config.rule3_min_utterance_length = 45
        let terms = Hotwords.normalize(hotwords)
        if !terms.isEmpty { config.hotwords_buf = c(terms); config.hotwords_buf_size = Int32(terms.utf8.count) }
        config.hotwords_score = 1.5
        guard let recognizer = SherpaOnnxCreateOnlineRecognizer(&config) else { throw ASRError.message("本地转写模型加载失败。") }
        guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
            SherpaOnnxDestroyOnlineRecognizer(recognizer); throw ASRError.message("无法创建本地转写音轨。")
        }
        self.recognizer = recognizer; self.stream = stream
    }
    deinit { SherpaOnnxDestroyOnlineStream(stream); SherpaOnnxDestroyOnlineRecognizer(recognizer) }
    public func accept(_ pcm: Data, sampleRate: Int = 24000) throws -> [ASRText] {
        guard !finished else { throw ASRError.message("转写已结束，不能继续输入音频。") }
        guard (8000...48000).contains(sampleRate) else { throw ASRError.message("不支持的音频采样率。") }
        guard inputRate == nil || inputRate == sampleRate else { throw ASRError.message("音轨采样率发生变化，请重新开始转写。") }
        inputRate = sampleRate
        let samples = try PCM16.floats(pcm)
        guard !samples.isEmpty else { return [] }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
        return try decode(flush: false)
    }
    public func finish() throws -> [ASRText] {
        guard !finished else { return [] }; finished = true
        // Flush encoder look-ahead; preserve an unfinished last phrase before destroying the stream.
        let rate = inputRate ?? 24000
        let tail = [Float](repeating: 0, count: rate)
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(rate), tail, Int32(tail.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        return try decode(flush: true)
    }
    private func decode(flush: Bool) throws -> [ASRText] {
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream) }
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { throw ASRError.message("转写引擎未返回结果。") }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        let text = result.pointee.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let final = flush || SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0
        var events: [ASRText] = []
        if final {
            if !text.isEmpty || !previous.isEmpty { events.append(.init(text: text.isEmpty ? previous : text, isFinal: true)) }
            previous = ""
            if !flush { SherpaOnnxOnlineStreamReset(recognizer, stream) }
        } else if text != previous { previous = text; events.append(.init(text: text, isFinal: false)) }
        return events
    }
}
