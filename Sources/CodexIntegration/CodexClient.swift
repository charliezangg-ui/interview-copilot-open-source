import Foundation
import SystemConfiguration

public enum CodexFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum CodexLane { case preparation, assessment }
public struct CodexApproval: Identifiable {
    public let id: String
    public let detail: String
}
public enum CodexPolicy {
    public static func config(for lane: CodexLane, inherited: [String: Any]) -> [String: Any] {
        var config: [String: Any] = ["memories.generate_memories": false, "features.hooks": false, "features.multi_agent": false]
        if lane == .assessment {
            config["memories.use_memories"] = false
            config["project_doc_max_bytes"] = 0
            config["web_search"] = "disabled"
            config["tools.view_image"] = false
            for feature in ["memories", "shell_tool", "code_mode", "code_mode_host", "apps", "browser_use", "computer_use", "image_generation", "tool_suggest", "skill_search"] { config["features." + feature] = false }
            for name in (inherited["mcp_servers"] as? [String: Any] ?? [:]).keys { config["mcp_servers.\(name).enabled"] = false }
            for name in (inherited["plugins"] as? [String: Any] ?? [:]).keys { config["plugins.\(name).enabled"] = false }
        }
        return config
    }
    public static func finalText(_ turn: [String: Any]) throws -> String {
        guard turn["status"] as? String == "completed" else { throw CodexFailure.message("Codex 未完成本次任务；没有生成有效结果。") }
        let items = turn["items"] as? [[String: Any]] ?? []
        guard let last = items.last(where: { $0["type"] as? String == "agentMessage" && ($0["phase"] as? String != "commentary") }), let text = last["text"] as? String, !text.isEmpty else { throw CodexFailure.message("Codex 没有返回最终回答。") }
        return text
    }
}

/// Same installed Codex, user configuration, login and local tools; never reads/copies auth tokens.
@MainActor public final class CodexClient {
    public var onProgress: ((String) -> Void)?
    public var onApproval: ((CodexApproval?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var turnWaiter: CheckedContinuation<String, Error>?
    private var currentThread: String?
    private var completedTurn: [String: Any]?
    private var approvalIDs: [String: Any] = [:]
    private var approvalQueue: [CodexApproval] = []
    private var inherited: [String: Any] = [:]
    private var ready = false
    private var running = false
    private var generation = UUID()
    private var finalItems: [[String: Any]] = []
    public init() {}
    public func modelCatalog() async throws -> [[String: Any]] {
        _ = try await connect()
        let result = try await rpc("model/list", ["limit": 100, "includeHidden": false])
        return result["data"] as? [[String: Any]] ?? []
    }
    public static var executable: String? {
        try? CodexExecutable.resolve(configuredPath: UserDefaults.standard.string(forKey: CodexExecutable.preferenceKey))
    }
    public func connect() async throws -> String {
        if ready { return "Codex 已连接 · 复用本机登录与配置" }
        guard process == nil else { throw CodexFailure.message("Codex 连接正在初始化，请稍后重试。") }
        let path = try CodexExecutable.resolve(configuredPath: UserDefaults.standard.string(forKey: CodexExecutable.preferenceKey))
        let token = UUID(); generation = token
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["app-server", "--listen", "stdio://", "-c", "memories.generate_memories=false", "-c", "features.hooks=false"]
        var env = ProcessInfo.processInfo.environment
        // Rust CLI networking does not necessarily discover the macOS system HTTP proxy.
        // Reuse the user's enabled proxy; do not change system settings or copy proxy secrets.
        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            for (prefix, key) in [("HTTP", "HTTP_PROXY"), ("HTTPS", "HTTPS_PROXY")] {
                if env[key] == nil, env[key.lowercased()] == nil, proxies[prefix + "Enable"] as? Int == 1,
                   let host = proxies[prefix + "Proxy"] as? String, let port = proxies[prefix + "Port"] as? Int, port > 0, port < 65536 {
                    var proxy = URLComponents(); proxy.scheme = "http"; proxy.host = host; proxy.port = port
                    env[key] = proxy.string
                }
            }
            if env["NO_PROXY"] == nil, env["no_proxy"] == nil { env["NO_PROXY"] = "localhost,127.0.0.1,::1" }
        }
        // These belong to the launching task, not the interview. In particular, do not route
        // desktop plugin calls back into the developer's current Codex conversation.
        for key in ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_APP_TOOLS_PIPE_PATH", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_PERMISSION_PROFILE", "CODEX_TASK_WORKSPACE_VERIFYING_IDENTITY"] { env.removeValue(forKey: key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":" + (env["PATH"] ?? "")
        // Keep the actual user home and CODEX_HOME. Do not create or copy credentials.
        proc.environment = env
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; process = proc
        output?.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in if self?.generation == token { self?.consume(bytes) } }
        }
        proc.terminationHandler = { [weak self] _ in Task { @MainActor in if self?.generation == token { self?.stop("Codex 连接已结束，请重新连接。") } } }
        do {
            try proc.run()
            onProgress?("Codex：正在初始化连接")
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            _ = try await rpc("initialize", ["clientInfo": ["name": "interview_copilot", "title": "Interview Copilot", "version": version], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
            onProgress?("Codex：正在读取账号与工作区路由")
            let account = try await rpc("account/read", [:])
            guard account["account"] is [String: Any] else { throw CodexFailure.message("Codex 尚未登录。请在 Codex 中完成登录。") }
            let settings = try await rpc("config/read", ["includeLayers": false])
            inherited = settings["config"] as? [String: Any] ?? [:]
            ready = true
            return "Codex 已连接 · 复用本机登录、配置和 CLI"
        } catch { stop("Codex 连接失败"); throw error }
    }
    public func run(_ prompt: String, lane: CodexLane, instructions: String, structured: Bool = false) async throws -> String {
        guard !running else { throw CodexFailure.message("Codex 正在处理上一项任务。") }
        running = true; finalItems = []; defer { running = false; currentThread = nil; completedTurn = nil; finalItems = []; onApproval?(nil); approvalIDs = [:]; approvalQueue = [] }
        _ = try await connect()
        let workspace = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InterviewCopilot/AgentWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var params: [String: Any] = ["cwd": workspace.path, "ephemeral": true, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "read-only", "config": CodexPolicy.config(for: lane, inherited: inherited), "developerInstructions": instructions]
        if lane == .assessment { params["baseInstructions"] = instructions }
        let result = try await rpc("thread/start", params)
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodexFailure.message("Codex 未创建任务上下文。") }
        currentThread = id
        var turnParams: [String: Any] = ["threadId": id, "input": [["type": "text", "text": prompt]]]
        if lane == .assessment { turnParams["effort"] = "low" }
        if structured { turnParams["outputSchema"] = ["type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"], "additionalProperties": false] }
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            self?.stop("Codex 本次任务超过 3 分钟，已停止；请缩小任务后重试。")
        }
        defer { timer.cancel() }
        _ = try await rpc("turn/start", turnParams)
        let text: String
        if let completedTurn { text = try CodexPolicy.finalText(completedTurn) }
        else { text = try await withCheckedThrowingContinuation { turnWaiter = $0 } }
        if structured {
            guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let answer = object["answer"] as? String else { throw CodexFailure.message("Codex 返回格式不正确，未生成评估。") }
            return answer
        }
        return text
    }
    public func approve(_ id: String, allow: Bool) {
        guard let rpcID = approvalIDs.removeValue(forKey: id) else { return }
        do {
            try send(["id": rpcID, "result": ["decision": allow ? "accept" : "decline"]])
            approvalQueue.removeAll { $0.id == id }; onApproval?(approvalQueue.first)
        }
        catch { stop("无法回复 Codex 授权请求。") }
    }
    public func stop(_ reason: String = "已停止 Codex 任务") {
        ready = false
        generation = UUID()
        output?.readabilityHandler = nil; output = nil
        try? input?.close(); input = nil
        let proc = process; process = nil; proc?.terminationHandler = nil
        if proc?.isRunning == true { proc?.terminate() }
        let waits = pending; pending = [:]
        let waiter = turnWaiter; turnWaiter = nil
        for item in waits.values { item.resume(throwing: CodexFailure.message(reason)) }
        waiter?.resume(throwing: CodexFailure.message(reason))
        buffer = Data(); approvalIDs = [:]; approvalQueue = []; onApproval?(nil)
    }
    private func send(_ value: [String: Any]) throws {
        guard let input else { throw CodexFailure.message("Codex 未连接。") }
        var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
        try input.write(contentsOf: bytes)
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1; let id = nextID
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            self?.pending.removeValue(forKey: id)?.resume(throwing: CodexFailure.message("Codex 接口超时：" + method))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }
    private func consume(_ data: Data) {
        if data.isEmpty { stop("Codex 连接中断。"); return }
        buffer.append(data)
        guard buffer.count <= 16_000_000 else { stop("Codex 返回内容过大。"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { stop("Codex 协议返回无法解析。"); return }
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let id = message["id"] {
                    if method == "item/fileChange/requestApproval" {
                        try? send(["id": id, "result": ["decision": "decline"]])
                        onProgress?("文本分析不修改文件，已拒绝写入请求")
                    } else if method == "item/commandExecution/requestApproval" {
                        let key = UUID().uuidString; approvalIDs[key] = id
                        let detail = (params["command"] as? String ?? params["reason"] as? String ?? "Codex 请求执行操作")
                        if onApproval != nil {
                            approvalQueue.append(.init(id: key, detail: detail))
                            if approvalQueue.count == 1 { onApproval?(approvalQueue.first) }
                        }
                        else { approve(key, allow: false) }
                    } else {
                        try? send(["id": id, "error": ["code": -32601, "message": "This client does not support this interaction. Do not bypass it."]])
                        onProgress?("当前交互暂不支持：" + method)
                    }
                    continue
                }
                guard params["threadId"] as? String == currentThread else { continue }
                if method == "item/started", let item = params["item"] as? [String: Any] {
                    let labels = ["userMessage": "正在理解请求", "agentMessage": "正在整理回答", "commandExecution": "正在调用本机 CLI", "mcpToolCall": "正在调用已连接工具"]
                    onProgress?("Codex：" + (labels[item["type"] as? String ?? ""] ?? "处理中"))
                }
                if method == "error", let error = params["error"] as? [String: Any] { onProgress?("Codex：" + (error["message"] as? String ?? "请求暂时失败")) }
                if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" { finalItems.append(item) }
                if method == "turn/completed", var turn = params["turn"] as? [String: Any] {
                    if (turn["items"] as? [[String: Any]] ?? []).isEmpty { turn["items"] = finalItems }
                    completedTurn = turn
                    if let waiter = turnWaiter { turnWaiter = nil; waiter.resume(with: Result { try CodexPolicy.finalText(turn) }) }
                }
            } else if let id = message["id"] as? Int, let waiter = pending.removeValue(forKey: id) {
                if let error = message["error"] as? [String: Any] { waiter.resume(throwing: CodexFailure.message("Codex：" + (error["message"] as? String ?? "接口错误"))) }
                else { waiter.resume(returning: message["result"] as? [String: Any] ?? [:]) }
            }
        }
    }
}
