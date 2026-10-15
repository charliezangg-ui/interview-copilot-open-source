import Foundation

/// Resolve installed executables directly, without invoking a shell or reading credentials.
public enum CodexExecutable {
    public static let preferenceKey = "codexExecutablePath"

    public static func resolve(configuredPath: String? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        if let override = [configuredPath, environment["COPILOT_CODEX_PATH"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            let path = override.hasPrefix("~/") ? home.appendingPathComponent(String(override.dropFirst(2))).path : override
            guard path.hasPrefix("/"), isExecutable(path) else {
                throw CodexFailure.message("指定的 Codex 文件不存在或不可执行。请在设置中重新选择 Codex 可执行文件，或恢复自动查找。")
            }
            return path
        }
        let appSuffixes = ["ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                           "Codex.app/Contents/Resources/codex"]
        let apps = ["/Applications", home.appendingPathComponent("Applications").path]
            .flatMap { base in appSuffixes.map { base + "/" + $0 } }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let candidates = apps + [home.appendingPathComponent(".local/bin/codex").path,
                                 "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + pathDirectories.map { $0 + "/codex" }
        guard let path = candidates.first(where: isExecutable) else {
            throw CodexFailure.message("未找到 Codex。请安装并登录 Codex，或在设置中选择 Codex 可执行文件。")
        }
        return path
    }

    public static func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
