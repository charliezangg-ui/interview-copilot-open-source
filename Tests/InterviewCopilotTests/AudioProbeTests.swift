import XCTest
@testable import InterviewCopilot

final class AudioProbeTests: XCTestCase {
    func testShortPlaybackRemainsDetectedAfterSilence() {
        var probe = AudioProbe()
        XCTAssertEqual(probe.summary, "尚未收到音频片段")
        probe.observe(0)
        XCTAssertFalse(probe.heardSound)
        XCTAssertEqual(probe.summary, "已收到片段，尚未检测到声音")
        probe.observe(0.05)
        for _ in 0..<100 { probe.observe(0) }
        XCTAssertTrue(probe.heardSound)
        XCTAssertEqual(probe.peak, 0.05)
        XCTAssertEqual(probe.buffers, 102)
    }
    func testInvalidSamplesDoNotCountAsAudio() {
        var probe = AudioProbe()
        for value: Float in [.nan, .infinity, -1] { probe.observe(value) }
        XCTAssertEqual(probe.buffers, 0)
        XCTAssertFalse(probe.heardSound)
    }
}
