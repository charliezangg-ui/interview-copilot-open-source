import Foundation
import CryptoKit

public enum ASRError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public struct ModelFile: Codable {
    public let name: String
    public let url: URL
    public let sha256: String
    public let size: Int
}
public struct ModelManifest: Codable {
    public let repository: String
    public let revision: String
    public let files: [ModelFile]
}

public enum LocalModelStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InterviewCopilot/Models/zipformer-zh-en", isDirectory: true)
    }
    public static func manifest() throws -> ModelManifest {
        // App bundles keep resources in Contents/Resources; SwiftPM command-line checks use Bundle.module.
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json") ?? Bundle.module.url(forResource: "model-manifest", withExtension: "json") else {
            throw ASRError.message("缺少本地转写模型清单，请重新安装应用。")
        }
        return try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }
    /// Cheap availability check for the UI. Full hashes are checked before native model loading.
    public static func isInstalled(at folder: URL = directory) -> Bool {
        guard let files = try? manifest().files else { return false }
        return files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path)
            return (attributes?[.size] as? NSNumber)?.intValue == file.size
        }
    }
    public static func verify(_ url: URL, file: ModelFile) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var size = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data); size += data.count }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == file.size, actual == file.sha256 else { throw ASRError.message("模型文件校验失败：\(file.name)。请重新下载模型。") }
    }
    public static func validate(at folder: URL = directory) throws {
        for file in try manifest().files {
            let url = folder.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ASRError.message("本地转写模型尚未安装，请在设置中下载。") }
            try verify(url, file: file)
        }
    }
    public static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try manifest().files
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(file.name)
            let valid = await Task.detached { (try? verify(destination, file: file)) != nil }.value
            if valid { continue }
            progress("下载模型 \(index + 1)/\(files.count)：\(file.name)")
            let (temporary, response) = try await session.download(from: file.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ASRError.message("模型下载失败，请检查网络后重试。") }
            try await Task.detached { try verify(temporary, file: file) }.value
            // A failed download never replaces an installed file.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        }
        progress("中英本地转写模型已就绪")
    }
}
