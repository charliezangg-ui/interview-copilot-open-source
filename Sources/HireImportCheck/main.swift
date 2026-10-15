import Foundation
import HireIntegration

@main struct HireImportCheck {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { print("Usage: HireImportCheck '<candidate detail link>'"); return }
        do {
            let importer = HireImporter()
            let candidate = try await importer.lookup(CommandLine.arguments[1])
            let result = try await importer.load(candidate, attachmentID: candidate.resumes[0].id)
            // Do not print candidate identities, text, source URLs, or signed download URLs.
            let report: [String: Any] = ["success": true, "attachments": candidate.resumes.count, "pages": result.pages, "characters": result.text.count, "ocr": result.source.usedOCR, "file_saved": FileManager.default.fileExists(atPath: result.source.localPath)]
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        } catch { fputs("Import check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
