import XCTest
@testable import CodexIntegration

final class CodexExecutableTests: XCTestCase {
    func testExplicitPathWithSpacesAndSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("custom codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let link = folder.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(try CodexExecutable.resolve(configuredPath: link.path, environment: [:]), link.path)
        XCTAssertEqual(try CodexExecutable.resolve(environment: ["COPILOT_CODEX_PATH": "~/custom codex"], home: folder), executable.path)
    }

    func testInvalidOverrideDoesNotSilentlyRunAnotherInstallation() throws {
        XCTAssertThrowsError(try CodexExecutable.resolve(configuredPath: "/missing-codex", environment: [:]))
        XCTAssertThrowsError(try CodexExecutable.resolve(configuredPath: "codex", environment: [:]))
        XCTAssertThrowsError(try CodexExecutable.resolve(configuredPath: "/usr/bin", environment: [:]))
        XCTAssertThrowsError(try CodexExecutable.resolve(configuredPath: "/etc/hosts", environment: [:]))
        XCTAssertThrowsError(try CodexExecutable.resolve(configuredPath: "/missing-codex", environment: ["COPILOT_CODEX_PATH": "/bin/sh"]))
    }
}
