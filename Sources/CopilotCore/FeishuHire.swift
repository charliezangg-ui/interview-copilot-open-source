import Foundation

public enum HireError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
public struct HireLink: Equatable, Codable, Sendable {
    public let talentID: String
    public let applicationID: String?
    public let canonicalURL: String
    public init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let start = text.range(of: "]("), text.hasSuffix(")") { text = String(text[start.upperBound..<text.index(before: text.endIndex)]) }
        guard let url = URLComponents(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              ["feishu.cn", "larksuite.com", "larkoffice.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              url.user == nil, url.password == nil, url.port == nil else { throw HireError.message("请粘贴飞书招聘候选人详情链接（https://…/hire/talent/…）。") }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "hire", parts[1] == "talent", Self.isID(parts[2]) else { throw HireError.message("暂支持 /hire/talent/人才ID 详情链接，不支持列表页或短链接。") }
        let applications = (url.queryItems ?? []).filter { $0.name == "application_id" }
        guard applications.count <= 1, applications.allSatisfy({ Self.isID($0.value ?? "") }) else { throw HireError.message("链接中的投递 ID 无效或重复。") }
        talentID = parts[2]; applicationID = applications.first?.value
        var clean = URLComponents(); clean.scheme = "https"; clean.host = host; clean.path = "/hire/talent/" + talentID
        if let applicationID { clean.queryItems = [.init(name: "application_id", value: applicationID)] }
        canonicalURL = clean.string!
    }
    public static func isID(_ value: String) -> Bool { !value.isEmpty && value.count <= 30 && value.utf8.allSatisfy { (48...57).contains($0) } }
}
public struct HireResume: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mime: String
    public let createdAt: Int64?
    public init(id: String, name: String, mime: String, createdAt: Int64?) { self.id = id; self.name = name; self.mime = mime; self.createdAt = createdAt }
}
public struct HireCandidate: Sendable {
    public let link: HireLink
    public let name: String
    public let resumes: [HireResume]
    public init(link: HireLink, name: String, resumes: [HireResume]) { self.link = link; self.name = name; self.resumes = resumes }
}
public struct HireMaterial: Codable, Sendable {
    public let link: HireLink
    public let candidateName: String
    public let attachmentID: String
    public let fileName: String
    public let localPath: String
    public let importedAt: Date
    public let usedOCR: Bool
    public init(link: HireLink, candidateName: String, attachmentID: String, fileName: String, localPath: String, usedOCR: Bool) {
        self.link = link; self.candidateName = candidateName; self.attachmentID = attachmentID; self.fileName = fileName; self.localPath = localPath; importedAt = Date(); self.usedOCR = usedOCR
    }
}
public enum HirePayload {
    public static func unwrap(_ bytes: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw HireError.message("飞书返回了无法解析的数据。") }
        if root["ok"] as? Bool == false || (root["code"] as? Int ?? 0) != 0 {
            let code = (root["error"] as? [String: Any])?["code"] ?? root["code"] ?? "未知"
            throw HireError.message("飞书读取失败（\(code)）。请检查现有 Bot 的招聘人才及附件读取权限、数据范围和登录状态。")
        }
        guard let data = root["data"] as? [String: Any] else { throw HireError.message("飞书响应缺少数据；未导入材料。") }
        return data
    }
    public static func candidate(_ bytes: Data, link: HireLink) throws -> HireCandidate {
        let data = try unwrap(bytes)
        guard let talent = data["talent"] as? [String: Any], talent["id"] as? String == link.talentID else { throw HireError.message("飞书返回的人才与链接不一致，已停止导入。") }
        let info = talent["basic_info"] as? [String: Any] ?? [:]
        var resumes: [HireResume] = []
        var ids = Set<String>()
        for item in talent["resume_attachment_list"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String ?? item["ID"] as? String, HireLink.isID(id), ids.insert(id).inserted else { continue }
            let time = item["create_time"] ?? item["CreateTime"]
            let stamp = (time as? NSNumber)?.int64Value ?? (time as? String).flatMap(Int64.init)
            resumes.append(.init(id: id, name: item["name"] as? String ?? item["Name"] as? String ?? "简历附件", mime: item["mime"] as? String ?? item["Mime"] as? String ?? "", createdAt: stamp))
        }
        for id in talent["resume_attachment_id_list"] as? [String] ?? [] where HireLink.isID(id) && ids.insert(id).inserted {
            resumes.append(.init(id: id, name: "简历附件", mime: "", createdAt: nil))
        }
        // Unknown timestamps remain unknown; preserve source order for equal/missing timestamps.
        resumes = resumes.enumerated().sorted { a, b in
            if a.element.createdAt == b.element.createdAt { return a.offset < b.offset }
            return (a.element.createdAt ?? Int64.min) > (b.element.createdAt ?? Int64.min)
        }.map(\.element)
        guard !resumes.isEmpty else { throw HireError.message("候选人没有可读取的简历附件；可能尚未上传或超出当前 Bot 数据权限。") }
        return HireCandidate(link: link, name: info["name"] as? String ?? "候选人", resumes: resumes)
    }
    public static func allowedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["feishu.cn", "feishucdn.com", "larksuite.com", "larkoffice.com", "larkcdn.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
