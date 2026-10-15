import XCTest
import AVFoundation
@testable import InterviewCopilot

final class AudioTrackProcessorTests: XCTestCase {
    private func buffer(rate: Double, start: Int, count: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { buffer.floatChannelData![0][index] = 0.3 * sin(Float(Double(start + index) / rate * 440 * 2 * .pi)) }
        return buffer
    }

    func testContinuousResamplingPreservesSmallInputChunksAndTail() throws {
        for rate in [44100.0, 48000.0] {
            let whole = try AudioTrackProcessor(), chunked = try AudioTrackProcessor()
            let frames = Int(rate)
            var expected = try whole.convert(buffer(rate: rate, start: 0, count: frames)).0
            expected.append(try whole.finish())
            var actual = Data()
            for start in stride(from: 0, to: frames, by: 441) {
                actual.append(try chunked.convert(buffer(rate: rate, start: start, count: min(441, frames - start))).0)
            }
            actual.append(try chunked.finish())
            XCTAssertEqual(actual.count, expected.count, "Repeated chunks must not lose resampler frames at \(rate) Hz")
            XCTAssertEqual(actual, expected)
            // AVAudioConverter emits a short filter tail at end-of-stream.
            XCTAssertGreaterThanOrEqual(actual.count / 2, 24000)
            XCTAssertLessThanOrEqual(actual.count / 2, 24064)
        }
    }

    func testSeparateLocalRecordingsRetainGapsAndRemainReadableAfterClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = root.appendingPathComponent("microphone.wav"), remote = root.appendingPathComponent("wechat.wav")
        let mic = try AudioTrackProcessor(recordingURL: microphone), candidate = try AudioTrackProcessor(recordingURL: remote)
        _ = try mic.convert(buffer(rate: 24000, start: 0, count: 2400), seconds: 0)
        _ = try candidate.convert(buffer(rate: 24000, start: 0, count: 4800), seconds: 1)
        _ = try mic.finish(); _ = try candidate.finish()
        let micFile = try AVAudioFile(forReading: microphone), candidateFile = try AVAudioFile(forReading: remote)
        XCTAssertEqual(micFile.length, 2400)
        XCTAssertEqual(candidateFile.length, 28800, "Leading missing audio remains silence; sources must not shift earlier")
        let silence = AVAudioPCMBuffer(pcmFormat: candidateFile.processingFormat, frameCapacity: 24000)!
        try candidateFile.read(into: silence, frameCount: 24000)
        XCTAssertTrue((0..<Int(silence.frameLength)).allSatisfy { silence.floatChannelData![0][$0] == 0 })
        let attributes = try FileManager.default.attributesOfItem(atPath: microphone.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDeviceFormatChangeIsExplicitRatherThanDroppingChunks() throws {
        let track = try AudioTrackProcessor()
        _ = try track.convert(buffer(rate: 48000, start: 0, count: 480))
        XCTAssertThrowsError(try track.convert(buffer(rate: 44100, start: 0, count: 441)))
        _ = try track.finish()
    }
}
