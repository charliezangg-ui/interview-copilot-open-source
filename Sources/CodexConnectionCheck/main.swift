import Foundation
import CodexIntegration
import CopilotCore
@main struct CodexConnectionCheck {
    @MainActor static func main() async {
        let client = CodexClient(); client.onProgress = { print($0); fflush(stdout) }; defer { client.stop() }
        do {
            print(try await client.connect())
            if CommandLine.arguments.contains("--models") {
                let catalog = try await client.modelCatalog()
                for model in catalog {
                    let safe = model.filter { ["model", "displayName", "defaultReasoningEffort", "supportedReasoningEfforts", "isDefault"].contains($0.key) }
                    print(String(decoding: try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), as: UTF8.self))
                }
            }
            if CommandLine.arguments.contains("--cleanup") {
                let turns = [Utterance(id: "synthetic-cleanup-1", speaker: .candidate, text: "不是我做的那个API是同事负责我只做了测试", seconds: 1)]
                let prompt = try TranscriptCleanup.prompt(turns: turns, hotwords: "API")
                let answer = try await client.run(prompt, lane: .assessment, instructions: TranscriptCleanup.instructions + "返回外层 JSON 的 answer 字段，其内容是请求要求的完整 JSON 字符串。", structured: true)
                let result = try TranscriptCleanup.decode(Data(answer.utf8), in: turns)
                try TranscriptCleanup.validate(result.changes, in: turns)
                guard let text = result.changes.first?.text, text.contains("不是我做的"), text.contains("同事"), text.contains("测试"), text.contains("，") || text.contains("。") else {
                    throw NSError(domain: "CleanupCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "合成校对未保留责任归属或未恢复标点。"])
                }
                print("synthetic_cleanup_valid=true changes=\(result.changes.count)")
            }
            if CommandLine.arguments.contains("--review") {
                let started = Date()
                let answer = try await client.run(Prompts.independent(rubric: Prompts.rubric, material: "合成测试，无真实候选人", turns: Sample.turns), lane: .assessment, instructions: Prompts.system + "返回外层 JSON 的 answer 字段，其内容是请求要求的完整 JSON 字符串。禁止工具调用。", structured: true)
                let result = try JSONDecoder().decode(Assessment.self, from: Data(answer.utf8))
                try Evidence.validate(result, in: Sample.turns)
                print("synthetic_review_valid=true evidence_count=\(result.evidenceIDs.count) elapsed_seconds=\(Int(Date().timeIntervalSince(started)))")
            }
            if CommandLine.arguments.contains("--tools") {
                let answer = try await client.run("只读检查两个项目，实际调用 shell：1. lark-cli --version；2. 检查 ~/.codex/memories/MEMORY.md 是否存在，只报告存在与否，不输出内容。不联网，不修改文件。报告实际结果，没执行就写未验证。", lane: .preparation, instructions: "这是应用连接验收。只执行用户指定的两项只读命令。不要读取简历、Memory 正文或其他资料；不要写入文件。")
                print(answer)
            }
            if CommandLine.arguments.contains("--run") {
                let answer = try await client.run("这是合成连接测试。只返回 answer 字段，内容为 JSON 字符串 {\"connected\":true}。不要读取文件或调用工具。", lane: .assessment, instructions: "Only answer the supplied synthetic task. Do not call tools.", structured: true)
                print(answer)
            }
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
