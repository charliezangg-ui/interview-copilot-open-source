import XCTest
@testable import InterviewCopilot

final class AudioAuthorizationTests: XCTestCase {
    @MainActor func testDeniedRequestShowsFailureAndAllowsRetry() async {
        let store = SessionStore()
        await store.requestScreenAuthorization {
            throw NSError(domain: "TestPermission", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试拒绝"])
        }
        XCTAssertTrue(store.error.contains("测试拒绝"))
        XCTAssertTrue(store.error.contains("录屏与系统录音授权未生效"))
        XCTAssertFalse(store.busy)
        await store.requestScreenAuthorization {}
        XCTAssertEqual(store.error, "")
        XCTAssertTrue(store.status.contains("请点击检测音频"))
        XCTAssertFalse(store.active, "Permission checks must not start recording")
        XCTAssertFalse(store.allowCloud)
        XCTAssertTrue(store.turns.isEmpty)
    }

    @MainActor func testConcurrentRequestDoesNotPromptTwice() async {
        let store = SessionStore()
        var requests = 0
        await store.requestScreenAuthorization {
            requests += 1
            XCTAssertTrue(store.busy)
            await store.requestScreenAuthorization { requests += 1 }
        }
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(store.busy)
    }

    @MainActor func testActiveOrEndingCaptureDoesNotRequestPermission() async {
        let store = SessionStore()
        var requests = 0
        store.active = true
        await store.requestScreenAuthorization { requests += 1 }
        store.active = false
        store.ending = true
        await store.requestScreenAuthorization { requests += 1 }
        XCTAssertEqual(requests, 0)
    }
}
