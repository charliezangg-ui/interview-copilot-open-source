import XCTest
@testable import CopilotCore
@testable import InterviewCopilot

final class ReviewWorkflowTests: XCTestCase {
    @MainActor func testRetiredEditableRoleRulesCannotAffectNewReviewButRemainInArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldRules = "RETIRED-ROLE-RULES: 当前岗位：全栈/后端。必须独立部署。"
        let archive = SessionArchive(id: UUID(), date: Date(), mode: "合成测试", rubric: oldRules, material: "招聘 JD：财务岗，对账及预算流程。", turns: Sample.turns, frozen: nil, human: "合成判断", comparison: nil, hasGap: false)
        let url = directory.appendingPathComponent(archive.id.uuidString + ".json")
        try JSONEncoder().encode(archive).write(to: url)
        var prompts: [String] = []
        let store = SessionStore(archiveDirectory: directory, requestJSON: { prompt in
            prompts.append(prompt)
            if prompts.count == 1 {
                return Data(#"{"decision":"待补充材料","judgment":"需要更多项目证据","highlights":[],"gaps":[],"evidenceIDs":["demo-2"]}"#.utf8)
            }
            return Data(#"{"items":[{"claim":"合成判断","status":"证据不足","reason":"需要补充","evidenceIDs":[]}]}"#.utf8)
        }, connectForTesting: { "合成连接" })
        XCTAssertTrue(store.restoreArchive(from: url))
        let success = await store.confirmAndSubmitJudgment()
        XCTAssertTrue(success); XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains("RETIRED-ROLE-RULES"))
        XCTAssertFalse(prompts[0].contains("当前岗位：全栈/后端"))
        XCTAssertTrue(prompts[0].contains("招聘 JD：财务岗"))
        XCTAssertTrue(prompts[0].contains(ScreeningDimensions.version))
        XCTAssertEqual(store.frozen?.rubric, Prompts.effectiveRubric(Prompts.rubric))
        let saved = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.rubric, oldRules, "Keep legacy data without using it in a new assessment")
        XCTAssertEqual(saved.human, archive.human)
        XCTAssertTrue(store.reset()); store.human = "下一场合成判断"; XCTAssertTrue(store.save())
        let next = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: URL(fileURLWithPath: store.archivePath)))
        XCTAssertEqual(next.rubric, Prompts.rubric)
    }
    private func fixture(human: String, comparedHuman: String?) -> SessionArchive {
        let assessment = Assessment(decision: "待补充材料", judgment: "需要演示 [demo-4]", highlights: [], gaps: ["可用性待核验"], evidenceIDs: ["demo-4"])
        let frozen = FrozenReview(rubric: Prompts.rubric, material: "合成材料", transcript: Sample.turns, assessment: assessment)
        let comparison = Comparison(items: [.init(claim: "只想带团队", status: "存在相反证据", reason: "接受 IC", evidenceIDs: ["demo-8"])])
        return SessionArchive(id: UUID(), date: Date(), mode: "合成测试", rubric: Prompts.rubric, material: "合成材料", turns: Sample.turns, frozen: frozen, human: human, comparison: comparison, hasGap: false, comparedHuman: comparedHuman)
    }

    @MainActor func testEditingOpinionInvalidatesComparisonButPreservesFrozenReviewAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = fixture(human: "只想带团队", comparedHuman: "只想带团队")
        let url = directory.appendingPathComponent(archive.id.uuidString + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(archive).write(to: url)
        let store = SessionStore(archiveDirectory: directory)
        XCTAssertTrue(store.restoreArchive(from: url))
        XCTAssertNotNil(store.comparison)
        let before = try encoder.encode(store.frozen)
        store.human = "目前接受 IC"
        XCTAssertNil(store.comparison)
        XCTAssertTrue(store.revealed)
        XCTAssertEqual(try encoder.encode(store.frozen), before)
        XCTAssertTrue(store.save())
        let restored = SessionStore(archiveDirectory: directory)
        XCTAssertTrue(restored.restoreArchive(from: url))
        XCTAssertEqual(restored.human, "目前接受 IC")
        XCTAssertNil(restored.comparison)
        XCTAssertEqual(try encoder.encode(restored.frozen), before)
    }

    @MainActor func testLegacyOrMismatchedOpinionCannotReuseComparison() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for sourceOpinion in [nil, "别的观点"] as [String?] {
            let archive = fixture(human: "目前接受 IC", comparedHuman: sourceOpinion)
            let url = directory.appendingPathComponent(archive.id.uuidString + ".json")
            try JSONEncoder().encode(archive).write(to: url)
            let store = SessionStore(archiveDirectory: directory)
            XCTAssertTrue(store.restoreArchive(from: url))
            XCTAssertNil(store.comparison)
            XCTAssertNotNil(store.frozen)
        }
    }

    @MainActor func testResetAndNavigationDoNotLoseDraftAfterWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocked)
        let archive = fixture(human: "另一个记录", comparedHuman: nil)
        let url = root.appendingPathComponent("other.json")
        try JSONEncoder().encode(archive).write(to: url)
        let store = SessionStore(archiveDirectory: blocked)
        store.human = "尚未保存的合成判断"
        XCTAssertFalse(store.reset())
        XCTAssertEqual(store.human, "尚未保存的合成判断")
        XCTAssertFalse(store.restoreArchive(from: url))
        XCTAssertEqual(store.human, "尚未保存的合成判断")
    }

    @MainActor func testOpeningCurrentRecordDoesNotRestoreStaleOpinion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(archiveDirectory: directory)
        store.human = "旧的合成判断"; XCTAssertTrue(store.save())
        store.human = "新的合成判断"
        XCTAssertTrue(store.openLatestArchive())
        XCTAssertEqual(store.human, "新的合成判断")
        let saved = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: URL(fileURLWithPath: store.archivePath)))
        XCTAssertEqual(saved.human, "新的合成判断")
    }
}
