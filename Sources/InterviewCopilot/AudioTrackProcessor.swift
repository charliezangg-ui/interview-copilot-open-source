import AVFoundation

/// One instance per source, used only on the capture queue. Keep resampler state across buffers.
final class AudioTrackProcessor {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var writtenFrames: AVAudioFramePosition = 0

    init(recordingURL: URL? = nil) throws {
        if let recordingURL {
            file = try AVAudioFile(forWriting: recordingURL, settings: Self.format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordingURL.path)
        }
    }

    func convert(_ input: AVAudioPCMBuffer, seconds: Double? = nil) throws -> (Data, Float) {
        if inputFormat != input.format {
            if inputFormat != nil { throw AppError.message("音频设备格式发生变化，请结束本场并重新检测设备。已收到的录音仍保留。") }
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: Self.format)
            converter?.primeMethod = .none
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / input.format.sampleRate) + 64)) else {
            throw AppError.message("无法创建音频转换器，当前音轨存在缺口。")
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let conversionError { throw conversionError }
        guard result != .error else { throw AppError.message("音频格式转换失败，当前音轨存在缺口。") }
        return try consume(output, seconds: seconds)
    }

    func finish() throws -> Data {
        defer { file = nil }
        guard let converter else { return Data() }
        guard let tail = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 4096) else { return Data() }
        var error: NSError?
        let result = converter.convert(to: tail, error: &error) { _, status in status.pointee = .endOfStream; return nil }
        if let error { throw error }
        guard result != .error else { throw AppError.message("音频转换收尾失败，末尾录音可能不完整。") }
        return try consume(tail, seconds: nil).0
    }

    private func consume(_ output: AVAudioPCMBuffer, seconds: Double?) throws -> (Data, Float) {
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return (Data(), 0) }
        if let file {
            // Preserve real input gaps as silence so a delayed source does not move earlier on playback.
            if let seconds, seconds.isFinite, seconds >= 0, seconds < 6 * 3600 {
                let target = AVAudioFramePosition(seconds * 24000)
                if target - writtenFrames > 2400 {
                    let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 24000)!
                    memset(silence.int16ChannelData![0], 0, 48000)
                    while writtenFrames < target {
                        silence.frameLength = AVAudioFrameCount(min(24000, target - writtenFrames))
                        try file.write(from: silence); writtenFrames += AVAudioFramePosition(silence.frameLength)
                    }
                }
            }
            try file.write(from: output)
            writtenFrames += AVAudioFramePosition(output.frameLength)
        }
        let count = Int(output.frameLength)
        var energy: Float = 0
        for i in 0..<count { let sample = Float(samples[i]) / 32768; energy += sample * sample }
        return (Data(bytes: samples, count: count * 2), sqrt(energy / Float(count)))
    }
}
