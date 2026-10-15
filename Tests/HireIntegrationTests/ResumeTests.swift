import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import HireIntegration

final class ResumeTests: XCTestCase {
    func testLocalImageOCR() async throws {
        let context = CGContext(data: nil, width: 1600, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 300))
        context.textPosition = CGPoint(x: 50, y: 150)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic engineer shipped a product", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 52, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        CTLineDraw(line, context)
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try await ResumeExtractor.extract(bytes as Data, mime: "image/png")
        XCTAssertTrue(result.usedOCR)
        XCTAssertTrue(result.text.lowercased().contains("engineer"))
    }
    func testPDFTextExtraction() async throws {
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes)!
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 700)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic engineer independently shipped a usable product.", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
        CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        let result = try await ResumeExtractor.extract(bytes as Data, mime: "application/pdf")
        XCTAssertEqual(result.pages, 1)
        XCTAssertFalse(result.usedOCR)
        XCTAssertTrue(result.text.contains("independently shipped"))
        XCTAssertEqual(result.fileExtension, "pdf")
    }
    func testTextImportAndInvalidDownloads() async throws {
        let result = try await ResumeExtractor.extract(Data("合成测试材料：独立开发并上线产品".utf8), mime: "text/plain")
        XCTAssertTrue(result.text.contains("独立开发"))
        for (data, mime) in [(Data("<html>login required</html>".utf8), "text/html"), (Data(), "application/pdf"), (Data(repeating: 65, count: 80001), "text/plain")] {
            do { _ = try await ResumeExtractor.extract(data, mime: mime); XCTFail("Invalid input accepted") }
            catch { /* Expected: no partial or login-page import. */ }
        }
    }
}
