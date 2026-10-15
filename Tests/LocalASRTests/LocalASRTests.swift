import XCTest
@testable import LocalASR

final class LocalASRTests: XCTestCase {
    func testPCMUsesLittleEndianSignedSamplesAndRejectsTruncation() throws {
        let samples = try PCM16.floats(Data([0, 128, 0, 0, 255, 127, 0, 64]))
        XCTAssertEqual(samples, [-1, 0, Float(32767)/32768, 0.5])
        XCTAssertThrowsError(try PCM16.floats(Data([1])))
    }
    func testHotwordsAreBoundedAndDoNotAcceptDecoderControlSyntax() {
        XCTAssertEqual(Hotwords.normalize("Eino\neino,数据库\nCoze:9\nRedis\0"), "EINO\n数据库\nCOZE9\nREDIS")
        XCTAssertEqual(Hotwords.normalize((0..<100).map { "WORD\($0)" }.joined(separator: "\n")).split(separator: "\n").count, 64)
        XCTAssertEqual(Hotwords.normalize(String(repeating: "A", count: 65)), "")
    }
    func testMissingAndCorruptModelsFailBeforeNativeLoading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(LocalModelStore.isInstalled(at: folder))
        XCTAssertThrowsError(try ZipformerDecoder(directory: folder))
        let file = try LocalModelStore.manifest().files[0]
        let url = folder.appendingPathComponent(file.name)
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try LocalModelStore.verify(url, file: file))
    }
    func testNative24kTailDoesNotChangeTheStreamSampleRate() throws {
        guard LocalModelStore.isInstalled() else { throw XCTSkip("Native smoke test requires separately installed, verified model weights.") }
        let decoder = try ZipformerDecoder()
        _ = try decoder.accept(Data(repeating: 0, count: 4800))
        XCTAssertThrowsError(try decoder.accept(Data(repeating: 0, count: 100), sampleRate: 16000))
        XCTAssertTrue(try decoder.finish().isEmpty)
        XCTAssertTrue(try decoder.finish().isEmpty)
        XCTAssertThrowsError(try decoder.accept(Data([0, 0])))
    }
    @MainActor func testOverloadFailsTheWholeStreamInsteadOfSilentlyDroppingAudio() async throws {
        guard LocalModelStore.isInstalled() else { throw XCTSkip("Native smoke test requires separately installed, verified model weights.") }
        let stream = LocalTranscriptionStream(); defer { stream.stop() }
        var failures = 0
        stream.onError = { _ in failures += 1 }
        try await stream.start(hotwords: "")
        stream.append(Data(repeating: 0, count: 48000 * 9), rms: 0)
        XCTAssertEqual(failures, 1)
        let completed = await stream.finish()
        XCTAssertFalse(completed)
    }
}
