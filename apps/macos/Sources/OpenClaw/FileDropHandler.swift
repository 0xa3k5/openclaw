import AppKit
import Foundation
import OpenClawChatUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Dropped File

struct DroppedFile: Sendable {
    let url: URL
    let name: String
    let mimeType: String
    let kind: FileKind

    enum FileKind: Sendable {
        case text
        case image
        case pdf
        case other
    }
}

// MARK: - Process Result

struct FileDropResult: Sendable {
    let message: String
    let attachments: [OpenClawChatAttachmentPayload]
}

// MARK: - File Drop Handler

@MainActor
enum FileDropHandler {

    /// Uploads directory accessible to the agent.
    private static let uploadsDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/workspace/uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Process dropped file URLs and build a chat message + gateway attachments.
    static func process(urls: [URL]) async -> FileDropResult? {
        guard !urls.isEmpty else { return nil }

        var messageParts: [String] = []
        var attachments: [OpenClawChatAttachmentPayload] = []

        for url in urls {
            let file = classify(url: url)

            switch file.kind {
            case .text:
                if let content = readTextFile(url: url) {
                    let truncated = content.count > 50_000
                        ? String(content.prefix(50_000)) + "\n...(truncated)"
                        : content
                    messageParts.append("File: \(file.name)\n```\n\(truncated)\n```")
                } else {
                    messageParts.append("Dropped file: \(file.name) (could not read)")
                }

            case .image:
                let savedPath = saveToUploads(url: url, name: file.name)
                if let data = try? Data(contentsOf: url) {
                    let base64 = data.base64EncodedString()
                    let dataURL = "data:\(file.mimeType);base64,\(base64)"
                    attachments.append(OpenClawChatAttachmentPayload(
                        type: "image",
                        mimeType: file.mimeType,
                        fileName: file.name,
                        content: dataURL))
                    // Embed as markdown image so the chat UI renders inline preview
                    let pathNote = savedPath != nil ? " (saved to \(savedPath!))" : ""
                    messageParts.append("![\(file.name)](\(dataURL))\n\(file.name)\(pathNote)")
                }

            case .pdf:
                let savedPath = saveToUploads(url: url, name: file.name)
                if let text = extractPDFText(url: url) {
                    let truncated = text.count > 50_000
                        ? String(text.prefix(50_000)) + "\n...(truncated)"
                        : text
                    let pathNote = savedPath != nil ? " (saved to \(savedPath!))" : ""
                    messageParts.append("PDF: \(file.name)\(pathNote)\n```\n\(truncated)\n```")
                } else {
                    messageParts.append("Dropped PDF: \(file.name) (could not extract text)")
                }

            case .other:
                let savedPath = saveToUploads(url: url, name: file.name)
                let pathNote = savedPath != nil ? " (saved to \(savedPath!))" : ""
                messageParts.append("Dropped file: \(file.name) (\(file.mimeType))\(pathNote)")
            }
        }

        guard !messageParts.isEmpty else { return nil }
        let message = messageParts.joined(separator: "\n\n")
        return FileDropResult(message: message, attachments: attachments)
    }

    /// Process raw image data (from paste).
    static func processImageData(_ data: Data, name: String = "pasted-image.png") -> FileDropResult? {
        let mimeType = "image/png"
        let base64 = data.base64EncodedString()

        let savedPath = saveDataToUploads(data: data, name: name)

        let dataURL = "data:\(mimeType);base64,\(base64)"
        var messageParts: [String] = []
        let pathNote = savedPath != nil ? " (saved to \(savedPath!))" : ""
        messageParts.append("![\(name)](\(dataURL))\n\(name)\(pathNote)")

        let attachments: [OpenClawChatAttachmentPayload] = [
            OpenClawChatAttachmentPayload(
                type: "image",
                mimeType: mimeType,
                fileName: name,
                content: "data:\(mimeType);base64,\(base64)")
        ]

        return FileDropResult(message: messageParts.joined(), attachments: attachments)
    }

    // MARK: - Save to uploads

    private static func saveToUploads(url: URL, name: String) -> String? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let dest = uploadsDir.appendingPathComponent("\(timestamp)-\(name)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            print("[OpenClaw] Failed to save to uploads: \(error.localizedDescription)")
            return nil
        }
    }

    private static func saveDataToUploads(data: Data, name: String) -> String? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let dest = uploadsDir.appendingPathComponent("\(timestamp)-\(name)")
        do {
            try data.write(to: dest)
            return dest.path
        } catch {
            print("[OpenClaw] Failed to save data to uploads: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Classification

    private static func classify(url: URL) -> DroppedFile {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let textExts: Set<String> = [
            "txt", "md", "swift", "json", "yaml", "yml", "toml",
            "js", "ts", "jsx", "tsx", "py", "rb", "rs", "go",
            "c", "cpp", "h", "hpp", "java", "kt", "sh", "bash",
            "zsh", "css", "scss", "html", "htm", "xml", "svg",
            "sql", "graphql", "env", "ini", "conf", "cfg",
            "log", "csv", "lock", "gitignore", "dockerfile",
            "makefile", "cmake",
        ]

        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico"]

        let kind: DroppedFile.FileKind
        if textExts.contains(ext) || ext.isEmpty {
            kind = .text
        } else if imageExts.contains(ext) {
            kind = .image
        } else if ext == "pdf" {
            kind = .pdf
        } else {
            kind = looksLikeText(url: url) ? .text : .other
        }

        let mimeType: String
        if let utType = UTType(filenameExtension: ext) {
            mimeType = utType.preferredMIMEType ?? "application/octet-stream"
        } else {
            mimeType = "application/octet-stream"
        }

        return DroppedFile(url: url, name: name, mimeType: mimeType, kind: kind)
    }

    // MARK: - Reading

    private static func readTextFile(url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func extractPDFText(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var text = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func looksLikeText(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count < 1_000_000 else { return false }
        let sample = data.prefix(8192)
        let nullCount = sample.filter { $0 == 0 }.count
        return nullCount == 0
    }
}
