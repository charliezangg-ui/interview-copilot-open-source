import XCTest
@testable import CopilotCore
final class CoreTests: XCTestCase {
    func testDefaultReviewRequiresExplicitJobRequirementsWithoutAssumingTechnicalRole() {
        let prompt = Prompts.independent(rubric: Prompts.rubric, material: "简历自述：后端工程师", turns: Sample.turns)
        XCTAssertTrue(prompt.contains("仅采用用户在材料中明确提供的招聘 JD"))
        XCTAssertTrue(prompt.contains("缺少目标岗位或核心要求时写待补充材料"))
        XCTAssertFalse(prompt.contains("当前岗位：全栈/后端"))
        XCTAssertFalse(prompt.contains("硬门槛：已有借助 AI 独立完成"))
        for item in ScreeningDimensions.items { XCTAssertTrue(prompt.contains(item.definition)) }
    }
    func testEvidenceRejectsHRAndInventedIDs() throws {
        XCTAssertThrowsError(try Evidence.validate(["demo-1"], in: Sample.turns))
        XCTAssertThrowsError(try Evidence.validate(["fake"], in: Sample.turns))
        XCTAssertNoThrow(try Evidence.validate(["demo-2"], in: Sample.turns))
    }
    func testTopicSwitchPreservesAllTurnsAndReturns() {
        let turns = Sample.turns + [.init(id: "return", speaker: .candidate, text: "补充部署的情况", seconds: 80)]
        let segments = TopicRules.segments(turns)
        XCTAssertEqual(segments.flatMap(\.turns), turns)
        XCTAssertEqual(segments.last?.title, "独立交付与上线")
        XCTAssertGreaterThan(segments.count, 2)
    }
    func testComparisonCannotMutateFrozenReview() throws {
        let assessment = Assessment(decision: "待补充材料", judgment: "需演示", highlights: [], gaps: ["独立交付"], evidenceIDs: ["demo-2"])
        let frozen = FrozenReview(rubric: "标准", material: "简历", transcript: Sample.turns, assessment: assessment)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(frozen)
        let a = Prompts.comparison(frozen: frozen, human: "非常优秀")
        let b = Prompts.comparison(frozen: frozen, human: "完全不行")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(before, try encoder.encode(frozen))
        let independent = Prompts.independent(rubric: "标准", material: "简历", turns: Sample.turns)
        XCTAssertFalse(independent.contains("非常优秀"))
        XCTAssertFalse(independent.contains("完全不行"))
    }
    func testCommonDimensionsSurviveCustomRoleAndAreNotDuplicated() {
        for role in ["研究岗：以实验与论文为主要成果", "财务岗：以对账和流程交付为主要成果", ""] {
            let effective = Prompts.effectiveRubric(role)
            XCTAssertEqual(Prompts.effectiveRubric(effective), effective)
            XCTAssertTrue(effective.hasSuffix(role))
            for prompt in [Prompts.independent(rubric: role, material: "", turns: Sample.turns),
                           Prompts.live(rubric: role, material: "", turns: Sample.turns)] {
                for item in ScreeningDimensions.items { XCTAssertTrue(prompt.contains(item.definition)) }
                XCTAssertTrue(prompt.contains("不编造数字权重"))
                XCTAssertFalse(prompt.contains("当前岗位：全栈/后端"), "Custom roles must not inherit the default delivery gate")
            }
        }
    }
    func testOldFrozenComparisonDoesNotRetroactivelyAdoptNewDimensions() {
        let assessment = Assessment(decision: "待补充材料", judgment: "需演示", highlights: [], gaps: [], evidenceIDs: [])
        let frozen = FrozenReview(rubric: "旧版标准", material: "", transcript: Sample.turns, assessment: assessment)
        let comparison = Prompts.comparison(frozen: frozen, human: "合成判断")
        XCTAssertFalse(comparison.contains(ScreeningDimensions.version))
        XCTAssertEqual(frozen.rubric, "旧版标准")
    }
    func testAdvanceRequiresCandidateEvidence() {
        let empty = Assessment(decision: "推进", judgment: "好", highlights: [], gaps: [], evidenceIDs: [])
        XCTAssertThrowsError(try Evidence.validate(empty, in: Sample.turns))
    }
}
