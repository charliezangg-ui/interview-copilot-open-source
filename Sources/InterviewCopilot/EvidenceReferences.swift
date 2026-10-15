import Foundation
import CopilotCore

enum EvidenceReferences {
    private static let pattern = try! NSRegularExpression(pattern: #"\[([^\[\]\r\n]+)\]"#)

    static func link(for id: String) -> URL {
        var url = URLComponents()
        url.scheme = "interview-copilot"
        url.host = "evidence"
        url.queryItems = [URLQueryItem(name: "id", value: id)]
        return url.url!
    }

    static func target(of url: URL, in turns: [Utterance]) -> String? {
        guard url.scheme == "interview-copilot", url.host == "evidence",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 1, query[0].name == "id", let id = query[0].value,
              turns.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Preserve the exact comment and link only references that exist in this session.
    static func attributed(_ text: String, in turns: [Utterance]) -> AttributedString {
        let ids = Set(turns.map(\.id))
        var result = AttributedString()
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let idRange = Range(match.range(at: 1), in: text) else { continue }
            result += AttributedString(String(text[cursor..<range.lowerBound]))
            var reference = AttributedString(String(text[range]))
            let id = String(text[idRange])
            if ids.contains(id) { reference.link = link(for: id) }
            result += reference
            cursor = range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }
}
