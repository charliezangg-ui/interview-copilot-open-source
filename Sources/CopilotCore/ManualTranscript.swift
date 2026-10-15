import Foundation

public enum ManualTranscript {
    public static func parse(_ input: String) throws -> [Utterance] {
        var turns: [Utterance] = []
        for raw in input.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let prefixes: [(String, Speaker)] = [("HR：", .interviewer), ("HR:", .interviewer), ("候选人：", .candidate), ("候选人:", .candidate)]
            if let (prefix, speaker) = prefixes.first(where: { line.hasPrefix($0.0) }) {
                let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw InputError.message("说话人后面不能为空，请补充实际问答。") }
                turns.append(.init(speaker: speaker, text: text, seconds: 0, manuallyAdded: true))
            } else if !turns.isEmpty {
                turns[turns.count - 1].text += "\n" + line
            } else {
                throw InputError.message("请以“HR：”或“候选人：”标明说话人；不要粘贴个人判断。")
            }
        }
        guard turns.contains(where: { $0.speaker == .candidate }) else { throw InputError.message("至少需要一段候选人的实际回答，不能只提供问题或判断。") }
        return turns
    }
    private enum InputError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
