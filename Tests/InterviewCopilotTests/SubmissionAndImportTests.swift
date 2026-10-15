import XCTest
@testable import CopilotCore
@testable import HireIntegration
@testable import InterviewCopilot

final class SubmissionAndImportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var assessment: Assessment {
        Assessment(decision: "待补充材料", judgment: "需要演示 [demo-4]", highlights: [], gaps: ["可用性待核验"], evidenceIDs: ["demo-4"])
    }
    private var comparison: Comparison {
        Comparison(items: [.init(claim: "合成观点", status: "证据不足", reason: "需要补充证据", evidenceIDs: [])])
    }
    @MainActor func testSubmitCreatesIndependentReviewThenComparisonWithoutLeakingOpinion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var prompts: [String] = []
        let store = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            prompts.append(prompt)
            return prompts.count == 1 ? try JSONEncoder().encode(self.assessment) : try JSONEncoder().encode(self.comparison)
        })
        store.turns = Sample.turns; store.human = "UNIQUE-HR-OPINION-DO-NOT-LEAK"
        store.codexReady = true; store.allowCloud = true
        XCTAssertTrue(store.save(announce: true))
        XCTAssertNil(store.reviewBlocker, "Unfrozen review must not disable submission")
        await store.submitJudgment()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains(store.human))
        XCTAssertTrue(prompts[1].contains(store.human))
        XCTAssertNotNil(store.frozen); XCTAssertNotNil(store.comparison); XCTAssertTrue(store.revealed)
        XCTAssertEqual(store.frozen?.rubric, Prompts.effectiveRubric(Prompts.rubric), "Archive the exact common and role rules used by the assessment")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(store.frozen)
        store.human = "Changed opinion"
        await store.submitJudgment()
        XCTAssertEqual(prompts.count, 3, "Re-submission must reuse the fixed independent review")
        XCTAssertEqual(try encoder.encode(store.frozen), original)
    }
    @MainActor func testOfflineSaveAllowsSetupButNeverSendsData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in calls += 1; return Data() })
        store.turns = Sample.turns; store.human = "本地合成判断"
        XCTAssertTrue(store.save(announce: true)); XCTAssertNil(store.reviewBlocker)
        await store.submitJudgment()
        XCTAssertEqual(calls, 0); XCTAssertFalse(store.allowCloud); XCTAssertNil(store.frozen)
        XCTAssertTrue(store.status.contains("请连接本机 Codex"))
    }
    @MainActor func testFailedIndependentReviewDoesNotRunComparison() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1; throw AppError.message("合成网络错误")
        })
        store.turns = Sample.turns; store.human = "合成判断"; store.codexReady = true; store.allowCloud = true
        await store.submitJudgment()
        XCTAssertEqual(calls, 1); XCTAssertNil(store.comparison); XCTAssertNil(store.frozen)
        XCTAssertTrue(store.error.contains("合成网络错误"))
        XCTAssertFalse(store.busy)
    }
    @MainActor func testConfirmedSubmitReconnectsAndContinuesWithOneTimeConsent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var connections = 0
        var prompts: [String] = []
        let store = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            prompts.append(prompt)
            return prompts.count == 1 ? try JSONEncoder().encode(self.assessment) : try JSONEncoder().encode(self.comparison)
        }, connectForTesting: { connections += 1; return "已连接" })
        store.turns = Sample.turns; store.human = "CONFIRMED-HR-ONLY"
        XCTAssertFalse(store.allowCloud); XCTAssertFalse(store.codexReady)
        let completed = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(completed); XCTAssertEqual(connections, 1); XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains(store.human)); XCTAssertTrue(prompts[1].contains(store.human))
        XCTAssertFalse(store.allowCloud, "One-time consent must not enable later automatic analysis")
        XCTAssertTrue(store.codexReady); XCTAssertTrue(store.revealed); XCTAssertFalse(store.busy)
        let repeated = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(repeated); XCTAssertEqual(connections, 1, "Reuse the existing connection")
        XCTAssertEqual(prompts.count, 3, "Reuse the independent review")
    }
    @MainActor func testConnectionFailureIsRetryableAndNeverSendsCandidateData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1; return Data()
        }, connectForTesting: { throw AppError.message("合成连接失败") })
        store.turns = Sample.turns; store.human = "合成判断"
        let completed = await store.confirmAndSubmitJudgment()
        XCTAssertFalse(completed); XCTAssertEqual(calls, 0); XCTAssertFalse(store.allowCloud)
        XCTAssertFalse(store.codexReady); XCTAssertFalse(store.busy); XCTAssertNil(store.reviewBlocker)
        XCTAssertTrue(store.error.contains("合成连接失败")); XCTAssertFalse(store.archivePath.isEmpty)
    }
    @MainActor func testCloudPermissionAloneDoesNotBypassCodexConnection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1; return Data()
        }, connectForTesting: { XCTFail("Submission needs explicit connection confirmation"); return "" })
        store.turns = Sample.turns; store.human = "合成判断"; store.allowCloud = true
        XCTAssertFalse(store.canCloud)
        await store.submitJudgment()
        XCTAssertEqual(calls, 0); XCTAssertNil(store.frozen)
        XCTAssertFalse(store.codexReady); XCTAssertNil(store.reviewBlocker)
        XCTAssertTrue(store.status.contains("连接本机 Codex")); XCTAssertFalse(store.archivePath.isEmpty)
    }
    @MainActor func testLiveImportKeepsRecordingAndTranscriptAndRejectsOtherCandidate() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let link = try HireLink("https://example.feishu.cn/hire/talent/123")
        let candidate = HireCandidate(link: link, name: "合成候选人", resumes: [.init(id: "456", name: "fixture.txt", mime: "text/plain", createdAt: nil)])
        let source = HireMaterial(link: link, candidateName: candidate.name, attachmentID: "456", fileName: "fixture.txt", localPath: root.appendingPathComponent("fixture.txt").path, usedOCR: false)
        let store = SessionStore(archiveDirectory: root)
        store.turns = Sample.turns; store.material = "旧材料"; store.hireURL = link.canonicalURL; store.active = true
        await store.importHireLink(lookup: { _ in candidate }, load: { _, _ in
            XCTAssertTrue(store.active); XCTAssertFalse(store.busy); XCTAssertTrue(store.importingMaterial)
            XCTAssertFalse(store.reset())
            store.add(.init(id: "during-import", speaker: .candidate, text: "导入期间继续说话", seconds: 100))
            return ImportedResume(source: source, text: "合成简历正文", pages: 1)
        })
        XCTAssertTrue(store.active); XCTAssertFalse(store.importingMaterial)
        XCTAssertTrue(store.material.contains("合成简历正文")); XCTAssertEqual(store.turns.count, Sample.turns.count + 1)
        XCTAssertEqual(store.hireMaterial?.link.talentID, "123")
        store.hireURL = "https://example.feishu.cn/hire/talent/999"
        await store.importHireLink(lookup: { _ in XCTFail("Must reject before external lookup"); return candidate })
        XCTAssertTrue(store.error.contains("另一位候选人"))
        XCTAssertEqual(store.hireMaterial?.link.talentID, "123")
    }
    @MainActor func testFinishWhileImportingStopsRecordingAndDefersAssessment() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let link = try HireLink("https://example.feishu.cn/hire/talent/123")
        let candidate = HireCandidate(link: link, name: "合成候选人", resumes: [.init(id: "456", name: "fixture", mime: "text/plain", createdAt: nil)])
        let source = HireMaterial(link: link, candidateName: candidate.name, attachmentID: "456", fileName: "fixture", localPath: "fixture", usedOCR: false)
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in calls += 1; return Data() })
        store.active = true; store.turns = Sample.turns; store.hireURL = link.canonicalURL
        store.allowCloud = true; store.codexReady = true
        await store.importHireLink(lookup: { _ in candidate }, load: { _, _ in
            await store.finish()
            XCTAssertFalse(store.active); XCTAssertFalse(store.ending)
            XCTAssertEqual(calls, 0)
            return ImportedResume(source: source, text: "迟到的简历", pages: 1)
        })
        XCTAssertTrue(store.material.contains("迟到的简历")); XCTAssertNil(store.frozen)
    }

    @MainActor func testConfirmedReviewRetriesRoutingDiscoveryBeforeSendingAnyText() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var connections = 0, prompts: [String] = []
        let store = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            prompts.append(prompt)
            return prompts.count == 1 ? try JSONEncoder().encode(self.assessment) : try JSONEncoder().encode(self.comparison)
        }, connectForTesting: {
            connections += 1
            if connections == 1 { throw AppError.message("Codex: workspace routing discovery timed out") }
            return "已连接"
        })
        store.turns = Sample.turns; store.human = "RETRY-HR-ONLY"
        let result = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(result); XCTAssertEqual(connections, 2); XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains(store.human)); XCTAssertTrue(prompts[1].contains(store.human))
        XCTAssertFalse(store.allowCloud); XCTAssertFalse(store.busy)
    }

    @MainActor func testReviewRequestRoutingFailureReconnectsAndKeepsHumanOutOfIndependentContext() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var connections = 0, prompts: [String] = []
        let store = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            prompts.append(prompt)
            if prompts.count == 1 { throw AppError.message("Codex: workspace routing discovery timed out") }
            return prompts.count == 2 ? try JSONEncoder().encode(self.assessment) : try JSONEncoder().encode(self.comparison)
        }, connectForTesting: { connections += 1; return "已连接" })
        store.turns = Sample.turns; store.human = "ISOLATED-HR-JUDGMENT"
        let completed = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(completed)
        XCTAssertEqual(connections, 2); XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(prompts[0], prompts[1], "Retry the same independent input")
        XCTAssertFalse(prompts[1].contains(store.human)); XCTAssertTrue(prompts[2].contains(store.human))
        XCTAssertFalse(store.allowCloud)
    }

    @MainActor func testComparisonFailureDoesNotRecomputeIndependentReviewAfterRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, connections = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1
            if calls == 1 { return try JSONEncoder().encode(self.assessment) }
            throw AppError.message("Codex: workspace routing discovery timed out")
        }, connectForTesting: { connections += 1; return "已连接" })
        store.turns = Sample.turns; store.human = "合成观点"
        let failed = await store.confirmAndSubmitJudgment()
        XCTAssertFalse(failed)
        XCTAssertEqual(calls, 3, "Initial review once, comparison twice")
        XCTAssertEqual(connections, 2); XCTAssertNotNil(store.frozen); XCTAssertNil(store.comparison)
        XCTAssertTrue(store.status.contains("只继续对照")); XCTAssertFalse(store.allowCloud)
        let id = store.frozen?.id
        var resumedCalls = 0
        let restored = SessionStore(archiveDirectory: root, requestJSON: { prompt in
            resumedCalls += 1; XCTAssertTrue(prompt.contains("待检验HR观点"))
            return try JSONEncoder().encode(self.comparison)
        }, connectForTesting: { "已连接" })
        XCTAssertTrue(restored.openLatestArchive()); XCTAssertEqual(restored.frozen?.id, id)
        let resumed = await restored.confirmAndSubmitJudgment()
        XCTAssertTrue(resumed)
        XCTAssertEqual(resumedCalls, 1); XCTAssertEqual(restored.frozen?.id, id)
    }

    @MainActor func testRepeatedRoutingFailureLeavesLocalJudgmentAndOffersRetryWithoutAnalysis() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var connections = 0, requests = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            requests += 1; return Data()
        }, connectForTesting: {
            connections += 1; throw AppError.message("Codex: workspace routing discovery timed out")
        })
        store.turns = Sample.turns; store.human = "仍应保留的本地观点"
        let failed = await store.confirmAndSubmitJudgment()
        XCTAssertFalse(failed)
        XCTAssertEqual(connections, 2); XCTAssertEqual(requests, 0)
        XCTAssertFalse(store.allowCloud); XCTAssertFalse(store.busy); XCTAssertFalse(store.codexReady)
        XCTAssertTrue(store.error.contains("路由发现超时")); XCTAssertNil(store.frozen)
        let restored = SessionStore(archiveDirectory: root)
        XCTAssertTrue(restored.openLatestArchive()); XCTAssertEqual(restored.human, store.human)
    }

    @MainActor func testMalformedAssessmentIsNotRetriedOrCompared() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let store = SessionStore(archiveDirectory: root, requestJSON: { _ in
            calls += 1; return Data("bad JSON".utf8)
        }, connectForTesting: { "已连接" })
        store.turns = Sample.turns; store.human = "合成观点"
        let failed = await store.confirmAndSubmitJudgment()
        XCTAssertFalse(failed)
        XCTAssertEqual(calls, 1); XCTAssertNil(store.frozen); XCTAssertNil(store.comparison)
        XCTAssertFalse(store.allowCloud)
    }

    @MainActor func testLiveSyntheticReviewSubmissionWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["COPILOT_LIVE_SYNTHETIC_REVIEW"] == "1" else {
            throw XCTSkip("Live review smoke test uses synthetic sample and judgment only.")
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(archiveDirectory: root)
        store.turns = Sample.turns
        store.material = "合成验收材料，无真实候选人"
        store.human = "合成观点：候选人讲过部署，但还需要可复现演示。"
        let started = Date()
        let completed = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(completed, store.error)
        XCTAssertNotNil(store.frozen); XCTAssertNotNil(store.comparison)
        XCTAssertTrue(store.revealed); XCTAssertFalse(store.allowCloud); XCTAssertFalse(store.busy)
        print("synthetic_review_submission_completed=\(completed) elapsed_seconds=\(Int(Date().timeIntervalSince(started)))")
        store.stopCodex()
    }
}
