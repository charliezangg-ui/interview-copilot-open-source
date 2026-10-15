import XCTest
@testable import CodexIntegration
final class CodexTests: XCTestCase {
    func testAssessmentDisablesExternalEvidenceAndMemory() {
        let config = CodexPolicy.config(for: .assessment, inherited: ["mcp_servers": ["local": [:]], "plugins": ["example@local": [:]]])
        XCTAssertEqual(config["memories.use_memories"] as? Bool, false)
        XCTAssertEqual(config["memories.generate_memories"] as? Bool, false)
        XCTAssertEqual(config["features.shell_tool"] as? Bool, false)
        XCTAssertEqual(config["mcp_servers.local.enabled"] as? Bool, false)
        XCTAssertEqual(config["plugins.example@local.enabled"] as? Bool, false)
        XCTAssertEqual(config["project_doc_max_bytes"] as? Int, 0)
        let prep = CodexPolicy.config(for: .preparation, inherited: [:])
        XCTAssertNil(prep["memories.use_memories"])
        XCTAssertNil(prep["features.shell_tool"])
        XCTAssertEqual(prep["memories.generate_memories"] as? Bool, false)
    }
    func testFinalResultRequiresCompletionAndIgnoresCommentary() throws {
        let items: [[String: Any]] = [["type": "agentMessage", "phase": "final_answer", "text": "answer"], ["type": "agentMessage", "phase": "commentary", "text": "not the result"]]
        XCTAssertEqual(try CodexPolicy.finalText(["status": "completed", "items": items]), "answer")
        for status in ["failed", "interrupted", "inProgress"] { XCTAssertThrowsError(try CodexPolicy.finalText(["status": status, "items": items])) }
        XCTAssertThrowsError(try CodexPolicy.finalText(["status": "completed", "items": []]))
    }
}
