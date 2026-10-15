import XCTest
@testable import CopilotCore

final class HireTests: XCTestCase {
    func testCanonicalLinkPreservesLargeIDsAndRemovesTracking() throws {
        let link = try HireLink("[候选人](https://example.feishu.cn/hire/talent/1234567890123456789?application_id=9876543210987654321&sharer_id=123#section)")
        XCTAssertEqual(link.talentID, "1234567890123456789")
        XCTAssertEqual(link.applicationID, "9876543210987654321")
        XCTAssertEqual(link.canonicalURL, "https://example.feishu.cn/hire/talent/1234567890123456789?application_id=9876543210987654321")
    }
    func testRejectsUnsupportedAndAmbiguousLinks() {
        for link in ["http://example.feishu.cn/hire/talent/123", "https://feishu.cn.evil.test/hire/talent/123", "https://user@example.feishu.cn/hire/talent/123", "https://example.feishu.cn/hire/talent/１２３", "https://example.feishu.cn/hire/talent/123?application_id=1&application_id=2", "https://example.feishu.cn/hire/talent", "https://example.feishu.cn/hire/talent/123?application_id="] {
            XCTAssertThrowsError(try HireLink(link), link)
        }
    }
    func testCandidateVariantsOrderingAndDeduplication() throws {
        let payload = Data(#"{"ok":true,"data":{"talent":{"id":"123","basic_info":{"name":"Synthetic candidate"},"resume_attachment_list":[{"ID":"1","Name":"old.pdf","Mime":"application/pdf","CreateTime":"100"},{"id":"2","name":"new.pdf","mime":"application/pdf","create_time":200},{"ID":"2","Name":"duplicate.pdf"}],"resume_attachment_id_list":["1","3","4"],"notes":"Must never become resume text"}}}"#.utf8)
        let candidate = try HirePayload.candidate(payload, link: HireLink("https://example.feishu.cn/hire/talent/123"))
        XCTAssertEqual(candidate.resumes.map(\.id), ["2", "1", "3", "4"])
        XCTAssertEqual(candidate.resumes.first?.name, "new.pdf")
        XCTAssertNil(candidate.resumes.last?.createdAt)
        XCTAssertThrowsError(try HirePayload.candidate(payload, link: HireLink("https://example.feishu.cn/hire/talent/124")))
    }
    func testNoResumeAndDeniedResponseAreErrors() throws {
        let link = try HireLink("https://example.feishu.cn/hire/talent/123")
        XCTAssertThrowsError(try HirePayload.candidate(Data(#"{"code":0,"data":{"talent":{"id":"123"}}}"#.utf8), link: link))
        XCTAssertThrowsError(try HirePayload.unwrap(Data(#"{"ok":false,"error":{"code":403}}"#.utf8)))
        XCTAssertThrowsError(try HirePayload.unwrap(Data(#"{"code":999,"data":{}}"#.utf8)))
    }
    func testDownloadHostAndRedirectPolicy() {
        XCTAssertTrue(HirePayload.allowedDownload(URL(string: "https://example.feishu.cn/file?token=opaque")!))
        for input in ["http://example.feishu.cn/file", "https://feishu.cn.evil.test/file", "https://127.0.0.1/file", "https://user:pass@example.feishu.cn/file", "https://example.feishu.cn:123/file"] {
            XCTAssertFalse(HirePayload.allowedDownload(URL(string: input)!), input)
        }
    }
}
