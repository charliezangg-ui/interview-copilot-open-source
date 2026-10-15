import Foundation
import PDFKit
import Vision
import AppKit
import CopilotCore

public struct ExtractedResume: Sendable {
    public let text: String
    public let pages: Int
    public let usedOCR: Bool
    public let fileExtension: String
}
public enum ResumeExtractor {
    public static func extract(_ data: Data, mime: String) async throws -> ExtractedResume {
        try await Task.detached {
            guard !data.isEmpty, data.count <= 25_000_000 else { throw HireError.message("简历为空或超过 25 MB。") }
            if data.prefix(5) == Data("%PDF-".utf8) {
                guard let doc = PDFDocument(data: data), !doc.isLocked, doc.pageCount > 0, doc.pageCount <= 30 else { throw HireError.message("PDF 无法读取、已加密或超过 30 页。") }
                var pages: [String] = []; var usedOCR = false
                for index in 0..<doc.pageCount {
                    guard let page = doc.page(at: index) else { throw HireError.message("PDF 存在无法读取的页面。") }
                    var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.count < 20 {
                        let bounds = page.bounds(for: .mediaBox)
                        guard bounds.width > 0, bounds.height > 0 else { throw HireError.message("PDF 页面尺寸无效。") }
                        let scale = min(2.5, 2200 / max(bounds.width, bounds.height))
                        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw HireError.message("无法渲染扫描页。") }
                        text = try recognize(cg); usedOCR = true
                    }
                    guard !text.isEmpty else { throw HireError.message("第 \(index + 1) 页未识别出文字；请检查原文件，未导入不完整简历。") }
                    pages.append("【第 \(index + 1) 页】\n" + text)
                }
                return try result(pages.joined(separator: "\n\n"), pages: doc.pageCount, ocr: usedOCR, ext: "pdf")
            }
            if let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let ext = data.prefix(8) == Data([137,80,78,71,13,10,26,10]) ? "png" : "jpg"
                return try result(recognize(cg), pages: 1, ocr: true, ext: ext)
            }
            if mime == "text/plain", let text = String(data: data, encoding: .utf8) { return try result(text, pages: 1, ocr: false, ext: "txt") }
            throw HireError.message("未取得可解析的 PDF、图片或文本。Word 等文件需飞书成功生成 PDF 预览，请检查附件权限。")
        }.value
    }
    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private static func result(_ text: String, pages: Int, ocr: Bool, ext: String) throws -> ExtractedResume {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HireError.message("未识别到简历文字。") }
        guard text.count <= 80000 else { throw HireError.message("解析结果超过 8 万字符，未截断导入，请缩小文件范围。") }
        return ExtractedResume(text: text, pages: pages, usedOCR: ocr, fileExtension: ext)
    }
}
