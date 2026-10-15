import XCTest
@testable import CopilotCore
@testable import InterviewCopilot

final class MissingTranscriptTests: XCTestCase {
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @MainActor func testSavedJudgmentCannotBecomeEvidenceAndManualNotesEnableSubmission() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var prompts: [String] = [], candidateID = ""
        let store = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            prompts.append(prompt)
            if prompts.count == 1 {
                return try JSONEncoder().encode(Assessment(decision: "待补充材料", judgment: "缺少交付验证", highlights: [], gaps: [], evidenceIDs: [candidateID]))
            }
            return try JSONEncoder().encode(Comparison(items: [.init(claim: "合成观点", status: "证据不足", reason: "需要核验", evidenceIDs: [])]))
        }, connectForTesting: { "合成连接" })
        store.human = "UNIQUE-HR-OPINION-IS-NOT-TRANSCRIPT"
        XCTAssertTrue(store.save())
        XCTAssertNotNil(store.reviewBlocker); XCTAssertTrue(store.canChooseReviewTranscript)
        let blocked = await store.confirmAndSubmitJudgment()
        XCTAssertFalse(blocked)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertFalse(store.addManualTranscript(store.human))
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertTrue(store.addManualTranscript("HR：你负责什么？\n候选人：我负责界面，部署由同事负责。\n没有独立部署。"))
        candidateID = try XCTUnwrap(store.turns.last?.id)
        XCTAssertEqual(store.human, "UNIQUE-HR-OPINION-IS-NOT-TRANSCRIPT")
        XCTAssertNil(store.reviewBlocker); XCTAssertFalse(store.canChooseReviewTranscript)
        XCTAssertTrue(store.turns.allSatisfy { $0.manuallyAdded == true })
        let success = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(success); XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains(store.human))
        XCTAssertTrue(prompts[0].contains("手动补充的面试记录，未经录音核对，不视为逐字原话"))
        XCTAssertTrue(prompts[0].contains("没有独立部署。"))
        let restored = SessionStore(archiveDirectory: root)
        XCTAssertTrue(restored.openLatestArchive())
        XCTAssertEqual(restored.turns, store.turns); XCTAssertEqual(restored.human, store.human)
        XCTAssertEqual(restored.frozen?.transcript, store.turns)
    }

    func testManualNotesRequireCandidateAndKeepMultilineSpeechInOrder() throws {
        XCTAssertThrowsError(try ManualTranscript.parse(""))
        XCTAssertThrowsError(try ManualTranscript.parse("这只是 HR 的判断"))
        XCTAssertThrowsError(try ManualTranscript.parse("HR：为什么？"))
        XCTAssertThrowsError(try ManualTranscript.parse("候选人："))
        let turns = try ManualTranscript.parse("HR: 你负责什么？\n候选人：负责界面。\n上线由同事负责。\nHR：有演示吗？\n候选人: 暂时没有。")
        XCTAssertEqual(turns.map(\.speaker), [.interviewer, .candidate, .interviewer, .candidate])
        XCTAssertEqual(turns[1].text, "负责界面。\n上线由同事负责。")
        XCTAssertEqual(Set(turns.map(\.id)).count, 4)
    }

    @MainActor func testFailedManualSaveDoesNotLoseJudgmentOrClaimTranscriptWasSaved() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let store = SessionStore(archiveDirectory: root)
        store.human = "合成判断"; store.mode = "未开始"
        XCTAssertFalse(store.addManualTranscript("候选人：我负责界面。"))
        XCTAssertTrue(store.turns.isEmpty); XCTAssertEqual(store.mode, "未开始")
        XCTAssertEqual(store.human, "合成判断"); XCTAssertTrue(store.error.contains("本地保存失败"))
    }

    @MainActor func testEndingWithoutWordsMarksArchiveIncompleteAndOffersRecovery() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(archiveDirectory: root)
        store.human = "合成判断"; store.active = true
        await store.finish()
        let archive = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: URL(fileURLWithPath: store.archivePath)))
        XCTAssertTrue(archive.hasGap); XCTAssertTrue(store.error.contains("没有识别出面试文字"))
        XCTAssertTrue(store.canChooseReviewTranscript); XCTAssertNotNil(store.reviewBlocker)
        XCTAssertTrue(store.addManualTranscript("候选人：我负责界面。"))
        XCTAssertNil(store.reviewBlocker)
    }

    @MainActor func testHistoryShowsEmptyAndPopulatedSessionsWithoutMixingJudgments() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let older = SessionStore(archiveDirectory: root)
        older.human = "另一场的判断"; older.turns = Sample.turns; XCTAssertTrue(older.save())
        let current = SessionStore(archiveDirectory: root)
        current.human = "这场的判断"; XCTAssertTrue(current.save())
        let saved = try current.savedSessions()
        XCTAssertEqual(saved.count, 2); XCTAssertEqual(saved.first?.archive.human, "这场的判断")
        let sourceURL = URL(fileURLWithPath: current.archivePath), source = try Data(contentsOf: sourceURL)
        XCTAssertTrue(current.restoreArchive(from: try XCTUnwrap(saved.last?.url)))
        XCTAssertEqual(current.human, "另一场的判断"); XCTAssertEqual(current.turns, Sample.turns)
        let original = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: sourceURL))
        XCTAssertEqual(original.human, "这场的判断"); XCTAssertTrue(original.turns.isEmpty)
        XCTAssertFalse(source.isEmpty)
    }

    func testNoTextAlertDistinguishesSoundFromMissingInputAndInitialStartup() {
        var probe = AudioProbe()
        XCTAssertNil(probe.transcriptionWarning(elapsed: 40, hasText: false, source: "微信"))
        probe.observe(0.02)
        XCTAssertNil(probe.transcriptionWarning(elapsed: 20, hasText: false, source: "微信"))
        XCTAssertNil(probe.transcriptionWarning(elapsed: 40, hasText: true, source: "微信"))
        XCTAssertTrue(probe.transcriptionWarning(elapsed: 40, hasText: false, source: "微信")?.contains("已有声音") == true)
    }
}
