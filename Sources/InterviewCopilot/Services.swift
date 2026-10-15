import Foundation

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
enum TextRequestFailures {
    static func isTransient(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("workspace routing discovery timed out") || message.contains("codex 接口超时") || message.contains("codex 连接中断") || message.contains("codex 连接已结束") { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(value.code)
    }
    static func description(_ error: Error) -> String {
        if error.localizedDescription.lowercased().contains("workspace routing discovery timed out") {
            return "Codex 连接路由发现超时，自动重连后仍未恢复。本地内容已保留，可稍后重试。"
        }
        return error.localizedDescription
    }
}
