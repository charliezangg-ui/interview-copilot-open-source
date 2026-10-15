import Foundation
import AVFoundation
import LocalASR

@main struct ASRCheck {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--install") {
                try await LocalModelStore.install { print($0) }; return
            }
            let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
            guard paths.count == 2 else { throw ASRError.message("Usage: ASRCheck [--no-hotwords] [--repeat] hr.wav candidate.wav | --install. Only use synthetic or consented audio.") }
            let waves = try paths.map { path -> Data in
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
                guard file.processingFormat.sampleRate == 24000, file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw ASRError.message("Use mono PCM WAV at 24000 Hz.")
                }
                try file.read(into: buffer)
                guard let samples = buffer.int16ChannelData?[0] else { throw ASRError.message("Cannot read PCM.") }
                return Data(bytes: samples, count: Int(buffer.frameLength) * 2)
            }
            let streams = [LocalTranscriptionStream(), LocalTranscriptionStream()]
            defer { streams.forEach { $0.stop() } }
            var first = [Double?](repeating: nil, count: 2), lastFinal = [Double?](repeating: nil, count: 2)
            var finals = [0, 0], partials = [0, 0]; var errors: [String] = []; var began = Date()
            for i in 0..<2 {
                streams[i].onText = { text, final in
                    if !text.isEmpty && first[i] == nil { first[i] = Date().timeIntervalSince(began) }
                    if final && !text.isEmpty { finals[i] += 1; lastFinal[i] = Date().timeIntervalSince(began); print("track=\(i) final=\(text)"); fflush(stdout) }
                    else if !final { partials[i] += 1 }
                }
                streams[i].onError = { errors.append($0); print("ERROR \($0)"); fflush(stdout) }
                try await streams[i].start(hotwords: CommandLine.arguments.contains("--no-hotwords") ? "" : Hotwords.defaults)
            }
            print("models_loaded_seconds=\(Date().timeIntervalSince(began))"); fflush(stdout)
            let repeatCount = CommandLine.arguments.contains("--repeat") ? 4 : 1
            let length = waves.map(\.count).max()! + 48000 * 2
            var audio = [Data(), Data()]
            for _ in 0..<repeatCount {
                for i in 0..<2 { audio[i].append(waves[i]); audio[i].append(Data(repeating: 0, count: length - waves[i].count)) }
            }
            began = Date()
            for offset in stride(from: 0, to: audio[0].count, by: 4800) {
                for i in 0..<2 {
                    let end = min(offset + 4800, audio[i].count)
                    streams[i].append(audio[i].subdata(in: offset..<end), rms: 0)
                }
                let remaining = Double(min(offset + 4800, audio[0].count)) / 48000 - Date().timeIntervalSince(began)
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            async let a = streams[0].finish(); async let b = streams[1].finish()
            let success = await (a, b)
            for i in 0..<2 {
                print("track=\(i) first_text_seconds=\(first[i] ?? -1) final_count=\(finals[i]) partial_count=\(partials[i]) last_final_seconds=\(lastFinal[i] ?? -1)")
                let sourceEnd = Double((repeatCount - 1) * length + waves[i].count) / 48000
                print("track=\(i) last_final_minus_source_end_seconds=\((lastFinal[i] ?? 0) - sourceEnd)")
            }
            print("wall_seconds=\(Date().timeIntervalSince(began)) audio_seconds_per_track=\(Double(audio[0].count)/48000) complete=\(success.0 && success.1) errors=\(errors.count)")
            guard success.0, success.1, errors.isEmpty else { exit(1) }
            if CommandLine.arguments.contains("--expect-silence") { guard finals == [0, 0], partials == [0, 0] else { exit(2) } }
            else { guard finals.allSatisfy({ $0 > 0 }), partials.allSatisfy({ $0 > 0 }) else { exit(2) } }
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
}
