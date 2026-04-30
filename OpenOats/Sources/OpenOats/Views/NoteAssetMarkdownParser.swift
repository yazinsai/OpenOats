import Foundation
import UniformTypeIdentifiers

enum NoteAssetMarkdownBlock: Equatable {
    case text(String)
    case image(altText: String, relativePath: String)
    case fileLink(label: String, relativePath: String)
}

enum NoteAssetMarkdownParser {
    static func parseBody(_ body: String) -> [NoteAssetMarkdownBlock] {
        splitParagraphs(body).map(parseParagraph)
    }

    static func isLocalImagePath(_ relativePath: String) -> Bool {
        guard case .image = localAssetKind(for: relativePath) else { return false }
        return true
    }

    private enum LocalAssetKind {
        case image
        case file
    }

    private static func parseParagraph(_ paragraph: String) -> NoteAssetMarkdownBlock {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)

        if let image = parseStandaloneImage(trimmed) {
            return image
        }

        if let fileLink = parseStandaloneFileLink(trimmed) {
            return fileLink
        }

        return .text(paragraph)
    }

    private static func splitParagraphs(_ body: String) -> [String] {
        var paragraphs: [String] = []
        var currentLines: [String] = []

        for rawLine in body.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentLines.isEmpty {
                    paragraphs.append(currentLines.joined(separator: "\n"))
                    currentLines.removeAll(keepingCapacity: true)
                }
            } else {
                currentLines.append(rawLine)
            }
        }

        if !currentLines.isEmpty {
            paragraphs.append(currentLines.joined(separator: "\n"))
        }

        return paragraphs
    }

    private static func parseStandaloneImage(_ text: String) -> NoteAssetMarkdownBlock? {
        guard let (label, path) = parseMarkdownLink(text, image: true),
              case .image = localAssetKind(for: path) else {
            return nil
        }

        return .image(altText: label, relativePath: path)
    }

    private static func parseStandaloneFileLink(_ text: String) -> NoteAssetMarkdownBlock? {
        guard let (label, path) = parseMarkdownLink(text, image: false),
              let assetKind = localAssetKind(for: path) else {
            return nil
        }

        switch assetKind {
        case .image:
            return .image(altText: label, relativePath: path)
        case .file:
            return .fileLink(label: label, relativePath: path)
        }
    }

    private static func parseMarkdownLink(_ text: String, image: Bool) -> (String, String)? {
        let prefix = image ? "![" : "["
        guard text.hasPrefix(prefix), text.hasSuffix(")") else { return nil }

        let labelStart = text.index(text.startIndex, offsetBy: prefix.count)
        guard let separatorRange = text[labelStart...].range(of: "]("),
              separatorRange.upperBound < text.endIndex else {
            return nil
        }

        let label = String(text[labelStart..<separatorRange.lowerBound])
        let pathEnd = text.index(before: text.endIndex)
        let path = String(text[separatorRange.upperBound..<pathEnd])
        guard !path.isEmpty else { return nil }
        return (label, path)
    }

    private static func localAssetKind(for relativePath: String) -> LocalAssetKind? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.hasPrefix("/") else {
            return nil
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(".."),
              !components.contains(".") else {
            return nil
        }

        guard trimmed.hasPrefix("images/") || trimmed.hasPrefix("attachments/") else {
            return nil
        }

        if let type = UTType(filenameExtension: URL(fileURLWithPath: trimmed).pathExtension),
           type.conforms(to: .image) {
            return .image
        }

        return .file
    }
}
