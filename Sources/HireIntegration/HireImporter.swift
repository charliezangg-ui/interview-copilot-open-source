import Foundation
import CopilotCore

public enum LarkCLI {
    public static func get(_ path: String, params: [String: Any] = [:]) async throws -> Data {
        let json = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8)!
        return try await Task.detached {
            let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lark-cli").path, "/opt/homebrew/bin/lark-cli", "/usr/local/bin/lark-cli"]
            guard let executable = candidates.first(where: FileManager.default.isExecutableFile) else { throw HireError.message("未找到现有 lark-cli。请在本机安装并登录后重试，无需把飞书密钥填进面试助手。") }
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            // Finder-launched apps omit Homebrew/local Node paths used by the existing CLI wrapper.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "")
            process.environment = environment
            process.arguments = ["api", "GET", path, "--params", json, "--as", "bot", "--format", "json"]
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
            defer { watchdog.cancel() }
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard bytes.count <= 8_000_000 else { throw HireError.message("飞书响应过大，已停止解析。") }
            if process.terminationStatus != 0 {
                if !bytes.isEmpty { _ = try HirePayload.unwrap(bytes) }
                throw HireError.message("飞书读取未完成。请检查 lark-cli 登录、Bot 权限或网络后重试。")
            }
            return bytes
        }.value
    }
}
private final class DownloadGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(HirePayload.allowedDownload) == true ? request : nil)
    }
}
public struct ImportedResume: Sendable {
    public let source: HireMaterial
    public let text: String
    public let pages: Int
}
public struct HireImporter: Sendable {
    public init() {}
    public func lookup(_ input: String) async throws -> HireCandidate {
        let link = try HireLink(input)
        let data = try await LarkCLI.get("/open-apis/hire/v1/talents/" + link.talentID)
        return try HirePayload.candidate(data, link: link)
    }
    public func load(_ candidate: HireCandidate, attachmentID: String) async throws -> ImportedResume {
        guard candidate.resumes.contains(where: { $0.id == attachmentID }), HireLink.isID(attachmentID) else { throw HireError.message("所选附件不属于该候选人。") }
        let data = try HirePayload.unwrap(await LarkCLI.get("/open-apis/hire/v1/attachments/" + attachmentID, params: ["type": 1]))
        guard let attachment = data["attachment"] as? [String: Any], attachment["id"] as? String == attachmentID else { throw HireError.message("附件身份校验失败，未导入。") }
        let name = attachment["name"] as? String ?? "简历附件"
        let mime = attachment["mime"] as? String ?? ""
        var location = attachment["url"] as? String ?? ""
        if !["application/pdf", "text/plain", "image/png", "image/jpeg"].contains(mime) && !["pdf", "txt", "png", "jpg", "jpeg"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
            let preview = try HirePayload.unwrap(await LarkCLI.get("/open-apis/hire/v1/attachments/" + attachmentID + "/preview"))
            location = preview["url"] as? String ?? ""
        }
        guard let url = URL(string: location), HirePayload.allowedDownload(url) else { throw HireError.message("飞书返回的下载地址不是受支持的安全附件地址。") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: DownloadGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Signed URL only: never send bot credentials to a download host or persist the URL.
        let (stream, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url.map(HirePayload.allowedDownload) == true else { throw HireError.message("简历下载失败或链接过期，请重新导入。") }
        guard response.expectedContentLength <= 25_000_000 else { throw HireError.message("简历超过 25 MB，暂不支持自动解析。") }
        var bytes = Data()
        for try await byte in stream {
            bytes.append(byte)
            if bytes.count > 25_000_000 { throw HireError.message("简历超过 25 MB，已停止下载。") }
        }
        let extracted = try await ResumeExtractor.extract(bytes, mime: http.mimeType ?? mime)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InterviewCopilot/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString + "." + extracted.fileExtension)
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let source = HireMaterial(link: candidate.link, candidateName: candidate.name, attachmentID: attachmentID, fileName: name, localPath: file.path, usedOCR: extracted.usedOCR)
        return ImportedResume(source: source, text: extracted.text, pages: extracted.pages)
    }
}
