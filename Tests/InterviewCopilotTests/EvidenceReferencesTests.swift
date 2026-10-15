import XCTest
import CopilotCore
@testable import InterviewCopilot

final class EvidenceReferencesTests: XCTestCase {
    private let turns = [
        Utterance(id: "1C25A29E-57C4-412F-AC2F-DB3D82E1E8FA", speaker: .candidate, text: "原话一", seconds: 50),
        Utterance(id: "second", speaker: .candidate, text: "原话二", seconds: 100)
    ]

    func testAdjacentAndRepeatedReferencesLinkToTheirOwnUtteranceAndPreserveText() {
        let first = turns[0].id
        let text = "【判断】\n中文🙂 [\(first)][second]；再次引用 [\(first)]。"
        let attributed = EvidenceReferences.attributed(text, in: turns)
        XCTAssertEqual(String(attributed.characters), text)
        let links = attributed.runs.compactMap { $0.link }
        XCTAssertEqual(links.compactMap { EvidenceReferences.target(of: $0, in: turns) }, [first, "second", first])
    }

    func testUnknownIDsAndSectionLabelsRemainPlainText() {
        let text = "【履历要点】[未知引用] 普通 [标签]\n[second]"
        let attributed = EvidenceReferences.attributed(text, in: turns)
        XCTAssertEqual(String(attributed.characters), text)
        XCTAssertEqual(attributed.runs.compactMap { $0.link }.count, 1)
        XCTAssertNil(EvidenceReferences.target(of: EvidenceReferences.link(for: "unknown"), in: turns))
        XCTAssertNil(EvidenceReferences.target(of: URL(string: "https://example.com/?id=second")!, in: turns))
    }

    func testReferenceRoutingPreservesSpecialCharactersAndRejectsAmbiguousQueries() {
        let id = "片段 +/&?="
        let special = [Utterance(id: id, speaker: .candidate, text: "原话", seconds: 0)]
        XCTAssertEqual(EvidenceReferences.target(of: EvidenceReferences.link(for: id), in: special), id)
        XCTAssertNil(EvidenceReferences.target(of: URL(string: "interview-copilot://evidence?id=second&id=other")!, in: turns))
    }
}
