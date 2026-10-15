import XCTest
@testable import InterviewCopilot

final class JudgmentSaveTests: XCTestCase {
    @MainActor func testOfflineJudgmentPersistsAndCanBeDecoded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(archiveDirectory: directory)
        store.allowCloud = false
        store.human = "合成测试：需要补充个人交付证据"
        XCTAssertEqual(store.judgmentSaveStatus, "有未保存的修改")
        XCTAssertTrue(store.save(announce: true))
        XCTAssertEqual(store.judgmentSaveStatus, "我的判断已保存到本机")
        let archive = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: URL(fileURLWithPath: store.archivePath)))
        XCTAssertEqual(archive.human, store.human)
        XCTAssertNil(archive.frozen)
        XCTAssertNil(archive.comparison)
        let restored = SessionStore(archiveDirectory: directory)
        restored.openLatestArchive()
        XCTAssertEqual(restored.human, store.human)
        XCTAssertEqual(URL(fileURLWithPath: restored.archivePath).resolvingSymlinksInPath(), URL(fileURLWithPath: store.archivePath).resolvingSymlinksInPath())
        XCTAssertEqual(restored.judgmentSaveStatus, "已恢复本地保存的判断")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.archivePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let path = store.archivePath
        store.human = ""
        XCTAssertEqual(store.judgmentSaveStatus, "有未保存的修改")
        XCTAssertTrue(store.save(announce: true))
        XCTAssertEqual(store.archivePath, path)
        let cleared = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(cleared.human, "")
    }

    @MainActor func testWriteFailureDoesNotClaimSavedOrLoseDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("file-not-directory")
        try Data("fixture".utf8).write(to: blocked)
        let store = SessionStore(archiveDirectory: blocked)
        store.human = "保留合成草稿"
        XCTAssertFalse(store.save(announce: true))
        XCTAssertTrue(store.judgmentSaveStatus.hasPrefix("保存失败"))
        XCTAssertTrue(store.error.hasPrefix("本地保存失败"))
        XCTAssertEqual(store.human, "保留合成草稿")
        XCTAssertEqual(store.archivePath, "")
        try FileManager.default.removeItem(at: blocked)
        XCTAssertTrue(store.save(announce: true))
        XCTAssertEqual(store.error, "")
        XCTAssertEqual(store.judgmentSaveStatus, "我的判断已保存到本机")
    }
}
