import XCTest
@testable import CopilotCore
@testable import InterviewCopilot

final class TranscriptCleanupTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private var turn: Utterance { .init(id: "source-1", speaker: .candidate, text: "不是我做的那个API是同事负责", seconds: 12) }

    @MainActor func testCleanupRequiresConsentAndDraftDoesNotReplaceSourceOrLeakPrivateContext() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            calls += 1
            XCTAssertFalse(prompt.contains("SECRET-RESUME")); XCTAssertFalse(prompt.contains("SECRET-HR"))
            XCTAssertTrue(prompt.contains("不是我做的"))
            return Data(#"{"changes":[{"n":1,"text":"不是我做的，那个 API 是同事负责。"}]}"#.utf8)
        }, connectForTesting: { "已连接" })
        store.turns = [turn]; store.material = "SECRET-RESUME"; store.human = "SECRET-HR"
        await store.generateCleanup()
        XCTAssertEqual(calls, 0)
        await store.confirmAndGenerateCleanup()
        XCTAssertEqual(calls, 1); XCTAssertFalse(store.allowCloud)
        XCTAssertEqual(store.turns, [turn]); XCTAssertEqual(store.cleanupDraft.count, 1)
        XCTAssertTrue(store.reviewBlocker?.contains("校对草稿") == true)
        let restored = SessionStore(archiveDirectory: root)
        XCTAssertTrue(restored.openLatestArchive()); XCTAssertEqual(restored.cleanupDraft, store.cleanupDraft)
        XCTAssertTrue(restored.applyTranscriptEdits(restored.cleanupDraft))
        XCTAssertEqual(restored.turns[0].id, turn.id); XCTAssertEqual(restored.turns[0].speaker, turn.speaker)
        XCTAssertEqual(restored.turns[0].seconds, turn.seconds)
        XCTAssertEqual(restored.originalTexts[turn.id], turn.text)
        XCTAssertEqual(restored.turns[0].text, "不是我做的，那个 API 是同事负责。")
        XCTAssertTrue(restored.cleanupDraft.isEmpty)
    }

    @MainActor func testCorrectionRetainsOriginalAndPriorReviewAcrossReload() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(archiveDirectory: root)
        store.turns = [turn]
        let assessment = Assessment(decision: "待补充材料", judgment: "旧结论", highlights: [], gaps: [], evidenceIDs: [turn.id])
        let frozen = FrozenReview(rubric: "标准", material: "", transcript: [turn], assessment: assessment)
        store.frozen = frozen; store.revealed = true
        XCTAssertTrue(store.applyTranscriptEdits([.init(id: turn.id, text: "不是我做的，那个 API 是同事负责。")]))
        XCTAssertNil(store.frozen); XCTAssertFalse(store.revealed)
        XCTAssertTrue(store.applyTranscriptEdits([.init(id: turn.id, text: "不是我做的，那个 API 是同事负责的。")]))
        XCTAssertEqual(store.originalTexts[turn.id], turn.text, "Never replace original ASR with an intermediate edit")
        let saved = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: URL(fileURLWithPath: store.archivePath)))
        XCTAssertEqual(saved.previousReviews?.count, 1)
        XCTAssertEqual(saved.previousReviews?.first?.id, frozen.id)
        XCTAssertEqual(saved.previousReviews?.first?.transcript, [turn])
        let restored = SessionStore(archiveDirectory: root)
        XCTAssertTrue(restored.openLatestArchive()); XCTAssertEqual(restored.originalTexts, store.originalTexts)
    }

    @MainActor func testMalformedBatchAndRejectedEditsCannotChangeTranscript() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            Data(#"{"changes":[{"n":999,"text":"编造内容"}]}"#.utf8)
        })
        store.turns = [turn]; store.allowCloud = true; store.codexReady = true
        await store.generateCleanup()
        XCTAssertTrue(store.cleanupDraft.isEmpty); XCTAssertEqual(store.turns, [turn])
        XCTAssertTrue(store.error.contains("未知片段"))
        XCTAssertFalse(store.applyTranscriptEdits([.init(id: turn.id, text: " ")]))
        XCTAssertFalse(store.applyTranscriptEdits([.init(id: turn.id, text: "改一"), .init(id: turn.id, text: "改二")]))
        XCTAssertEqual(store.turns, [turn])
        store.active = true
        XCTAssertFalse(store.applyTranscriptEdits([.init(id: turn.id, text: "录音时不能改")]))
    }

    @MainActor func testWriteFailureRollsBackCorrectionAndReview() throws {
        let root = directory(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("file")
        try Data().write(to: blocked)
        let store = SessionStore(archiveDirectory: blocked)
        store.turns = [turn]
        XCTAssertFalse(store.applyTranscriptEdits([.init(id: turn.id, text: "不能写盘的修改")]))
        XCTAssertEqual(store.turns, [turn]); XCTAssertTrue(store.originalTexts.isEmpty)
    }

    @MainActor func testFinishingDoesNotStartHiddenAnalysisBeforeTextIsChecked() async {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in calls += 1; return Data() })
        store.turns = [turn]; store.active = true; store.allowCloud = true; store.codexReady = true
        await store.finish()
        XCTAssertEqual(calls, 0); XCTAssertNil(store.frozen)
        XCTAssertTrue(store.status.contains("校对"))
    }

    func testLongTranscriptIsBatchedWithoutLosingOrReorderingTurns() throws {
        let turns = (0..<53).map { Utterance(id: "\($0)", speaker: .candidate, text: String(repeating: "话", count: 400), seconds: Double($0)) }
        let batches = TranscriptCleanup.batches(turns)
        XCTAssertEqual(batches.flatMap { $0 }, turns)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 100 && $0.reduce(0) { $0 + $1.text.count } <= 8000 })
    }

    private var longTurns: [Utterance] {
        (0..<101).map { .init(id: "resume-\($0)", speaker: .candidate, text: ($0 == 0 ? "第一段" : $0 == 100 ? "最后一段" : "") + "这个 API 是同事做的我只做了测试", seconds: Double($0)) }
    }

    @MainActor func testOneConnectionForMultipleBatchesAndProgressSurvivesFailureAndRelaunch() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var requests = 0, connections = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            requests += 1
            if requests == 2 { throw AppError.message("合成中途失败") }
            return Data(#"{"changes":[{"n":1,"text":"这个 API 是同事做的，我只做了测试。"}]}"#.utf8)
        }, connectForTesting: { connections += 1; return "已连接" })
        store.turns = longTurns; store.allowCloud = true
        await store.generateCleanup()
        XCTAssertEqual(connections, 1); XCTAssertEqual(requests, 2)
        XCTAssertEqual(store.cleanupProgress?.completedBatches, 1)
        XCTAssertTrue(store.cleanupDraft.isEmpty); XCTAssertEqual(store.turns, longTurns)
        var resumedCalls = 0
        let restored = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            resumedCalls += 1
            XCTAssertTrue(prompt.contains("最后一段")); XCTAssertFalse(prompt.contains("第一段"))
            return Data(#"{"changes":[]}"#.utf8)
        }, connectForTesting: { "已连接" })
        XCTAssertTrue(restored.openLatestArchive()); XCTAssertTrue(restored.canResumeCleanup)
        await restored.confirmAndGenerateCleanup()
        XCTAssertEqual(resumedCalls, 1, "Do not resend the completed batch")
        XCTAssertFalse(restored.allowCloud); XCTAssertEqual(restored.cleanupDraft.count, 1)
        XCTAssertEqual(restored.cleanupDraft.first?.id, "resume-0"); XCTAssertNil(restored.cleanupProgress)
    }

    @MainActor func testRoutingDiscoveryFailureRetriesConnectionBeforeSendingText() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var connections = 0, requests = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            requests += 1; return Data(#"{"changes":[]}"#.utf8)
        }, connectForTesting: {
            connections += 1
            if connections == 1 { throw AppError.message("Codex: workspace routing discovery timed out") }
            return "已连接"
        })
        store.turns = [turn]
        await store.confirmAndGenerateCleanup()
        XCTAssertEqual(connections, 2); XCTAssertEqual(requests, 1)
        XCTAssertFalse(store.allowCloud); XCTAssertTrue(store.error.isEmpty); XCTAssertFalse(store.busy)
    }

    @MainActor func testRepeatedRoutingFailureStopsAfterOneRetryAndRestoresConsent() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var connections = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            XCTFail("Failed connection must not send text"); return Data()
        }, connectForTesting: {
            connections += 1; throw AppError.message("Codex: workspace routing discovery timed out")
        })
        store.turns = [turn]
        await store.confirmAndGenerateCleanup()
        XCTAssertEqual(connections, 2); XCTAssertFalse(store.allowCloud); XCTAssertFalse(store.busy)
        XCTAssertTrue(store.error.contains("连接路由发现超时")); XCTAssertEqual(store.turns, [turn])
    }

    @MainActor func testCancellationStopsPendingRequestAndKeepsCompletedBatch() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let waiting = expectation(description: "Second batch waiting")
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1
            if calls == 2 {
                waiting.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            return Data(#"{"changes":[]}"#.utf8)
        }, connectForTesting: { "已连接" })
        store.turns = longTurns; store.allowCloud = true
        let task = Task { await store.generateCleanup() }
        await fulfillment(of: [waiting], timeout: 2)
        store.cancelCleanup(); await task.value
        XCTAssertFalse(store.busy); XCTAssertFalse(store.cleanupRunning)
        XCTAssertEqual(store.cleanupProgress?.completedBatches, 1)
        XCTAssertTrue(store.cleanupStatus.contains("已停止")); XCTAssertTrue(store.error.isEmpty)
        let restored = SessionStore(archiveDirectory: root)
        XCTAssertTrue(restored.openLatestArchive()); XCTAssertTrue(restored.canResumeCleanup)
    }

    @MainActor func testSourceChangesInvalidateSavedProgress() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1
            if calls == 2 { throw AppError.message("合成错误") }
            return Data(#"{"changes":[]}"#.utf8)
        }, connectForTesting: { "已连接" })
        store.turns = longTurns; store.allowCloud = true
        await store.generateCleanup()
        XCTAssertTrue(store.canResumeCleanup)
        store.turns[0].text = "修改后的文字"
        XCTAssertFalse(store.canResumeCleanup)
        await store.generateCleanup()
        XCTAssertEqual(calls, 4, "Recheck both batches when the source changes")
        XCTAssertNil(store.cleanupProgress)
    }

    func testRetryPolicyDoesNotRetryInvalidJSONOrMissingLogin() {
        XCTAssertTrue(TextRequestFailures.isTransient(URLError(.timedOut)))
        XCTAssertFalse(TextRequestFailures.isTransient(AppError.message("尚未登录本机 Codex")))
        XCTAssertFalse(TextRequestFailures.isTransient(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid"))))
    }

    @MainActor func testLiveSyntheticCleanupWithReusedConnectionWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["COPILOT_LIVE_SYNTHETIC_CLEANUP"] == "1" else {
            throw XCTSkip("Live service smoke test is opt-in and uses synthetic text only.")
        }
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(archiveDirectory: root)
        store.turns = longTurns.enumerated().map { index, turn in
            var result = turn; result.text = index == 0 || index == 100 ? turn.text : "嗯。"; return result
        }
        store.allowCloud = true
        XCTAssertEqual(TranscriptCleanup.batches(store.turns).count, 2)
        let started = Date()
        await store.generateCleanup()
        XCTAssertTrue(store.error.isEmpty, store.error)
        XCTAssertNil(store.cleanupProgress); XCTAssertFalse(store.busy)
        print("synthetic_cleanup_batches=2 elapsed_seconds=\(Int(Date().timeIntervalSince(started))) changes=\(store.cleanupDraft.count)")
        store.stopCodex()
    }

    func testCompactWireDoesNotSendUUIDOrTimestampsAndMapsBackExactly() throws {
        let source = [
            Utterance(id: "03D7B1DC-F514-4D0B-988E-92F02F0DB6A9", speaker: .candidate, text: "先说第一句", seconds: 12345),
            Utterance(id: "D24CA002-5BBD-4E6E-B692-4A9CDE26C09B", speaker: .candidate, text: "再说第二句", seconds: 12346)
        ]
        let prompt = try TranscriptCleanup.prompt(turns: source, hotwords: "API")
        XCTAssertFalse(prompt.contains(source[0].id)); XCTAssertFalse(prompt.contains(source[1].id))
        XCTAssertFalse(prompt.contains("12345")); XCTAssertFalse(prompt.contains("seconds"))
        let result = try TranscriptCleanup.decode(Data(#"{"changes":[{"n":2,"text":"再说第二句。"}]}"#.utf8), in: source)
        XCTAssertEqual(result.changes, [.init(id: source[1].id, text: "再说第二句。")])
        XCTAssertThrowsError(try TranscriptCleanup.decode(Data(#"{"changes":[{"n":0,"text":"错号"}]}"#.utf8), in: source))
        XCTAssertThrowsError(try TranscriptCleanup.decode(Data(#"{"changes":[{"n":1,"text":"一"},{"n":1,"text":"二"}]}"#.utf8), in: source))
    }

    @MainActor func testLegacyProgressDoesNotMixOldEditingPolicyWithNewResults() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let progress = CleanupProgress(source: longTurns, hotwords: "API", completedBatches: 1)
        var legacy = progress; legacy.revision = nil
        let archive = SessionArchive(id: UUID(), date: Date(), mode: "合成测试", rubric: "", material: "", turns: longTurns, frozen: nil, human: "", comparison: nil, hasGap: false, asrHotwords: "API", cleanupProgress: legacy)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(archive).write(to: url)
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1; return Data(#"{"changes":[]}"#.utf8)
        }, connectForTesting: { "已连接" })
        XCTAssertTrue(store.restoreArchive(from: url)); XCTAssertFalse(store.canResumeCleanup)
        store.allowCloud = true
        await store.generateCleanup()
        XCTAssertEqual(calls, 2, "Old-policy partial results must not be reused")
    }

    @MainActor func testLiveReadableCleanupQualityWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["COPILOT_LIVE_SYNTHETIC_CLEANUP"] == "1" else {
            throw XCTSkip("Live quality check uses invented speech only.")
        }
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = [
            "呃那个我我主要是负责框架的那个主练路然后就是把不同组件给串起来具体模块不是我做的",
            "然后就是算法同事说那个效果变好了我没参与评测所以那个具体数字我我也不清楚",
            "然后我们做的是相册文管理不同业务它它拼三少文的策略不一样组件要保留自定义的能力",
            "呃然后那个这个服务延迟是180毫秒不是18毫秒只是测试环境还没有在线上验证",
            "其实最终我们就是，呃，就是通过调研，然后去选型。然后同时也那个，组件是通用的，同时也保留足够的定制能力。"
        ]
        let store = SessionStore(archiveDirectory: root)
        store.turns = source.enumerated().map { .init(id: "quality-\($0.offset)", speaker: .candidate, text: $0.element, seconds: Double($0.offset)) }
        store.asrHotwords = "Agent\nHarness\n上下文管理"
        store.allowCloud = true
        let started = Date()
        await store.generateCleanup()
        XCTAssertTrue(store.error.isEmpty, store.error)
        let edits = Dictionary(uniqueKeysWithValues: store.cleanupDraft.map { ($0.id, $0.text) })
        let ownership = edits["quality-0"] ?? ""
        XCTAssertTrue(ownership.contains("主链路") && ownership.contains("组件") && ownership.contains("不是我"))
        XCTAssertFalse(ownership.contains("呃") || ownership.contains("我我") || ownership.contains("那个"))
        XCTAssertLessThan(ownership.count, source[0].count)
        let uncertainty = edits["quality-1"] ?? ""
        XCTAssertTrue(uncertainty.contains("不清楚") || uncertainty.contains("不知道"))
        XCTAssertTrue(uncertainty.contains("没参与") || uncertainty.contains("没有参与") || uncertainty.contains("未参与"))
        XCTAssertTrue((edits["quality-2"] ?? "").contains("上下文"))
        let numbers = edits["quality-3"] ?? ""
        XCTAssertTrue(numbers.contains("180")); XCTAssertNotNil(numbers.range(of: #"(?<!\d)18(?!\d)"#, options: .regularExpression))
        XCTAssertTrue(numbers.contains("不是")); XCTAssertTrue(numbers.contains("未") || numbers.contains("没有"))
        let alreadyPunctuated = edits["quality-4"] ?? ""
        XCTAssertFalse(alreadyPunctuated.contains("呃") || alreadyPunctuated.contains("那个"))
        XCTAssertTrue(alreadyPunctuated.contains("调研") && alreadyPunctuated.contains("选型") && alreadyPunctuated.contains("定制"))
        print("synthetic_readability_elapsed_seconds=\(Int(Date().timeIntervalSince(started)))")
        for edit in store.cleanupDraft { print("\(edit.id): \(edit.text)") }
        store.stopCodex()
    }
}
