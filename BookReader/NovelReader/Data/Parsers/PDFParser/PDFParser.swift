import Foundation
import UIKit

/// PDF 文件解析器
/// 使用 Apple PDFKit 提取文本内容，按页分割章节
class PDFParser {
    
    /// 最大支持文件大小：200MB
    private let maxFileSize: Int64 = 200 * 1024 * 1024
    
    /// 解析 PDF 文件
    /// - Parameter fileURL: PDF 文件路径
    /// - Returns: 解析结果 ParsedBook
    func parse(fileURL: URL) throws -> ParsedBook {
        // 1. 检查文件存在性
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound
        }
        
        // 2. 检查文件大小
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize > maxFileSize {
            throw ParserError.fileTooLarge(maxSize: fileSize)
        }
        
        // 3. 使用 PDFKit 打开文档
        guard let document = PDFDocument(url: fileURL) else {
            throw ParserError.parseFailed
        }
        
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ParserError.parseFailed
        }
        
        // 4. 提取元数据
        let title = document.documentTitle?.isEmpty == false
            ? document.documentTitle!
            : fileURL.deletingPathExtension().lastPathComponent
        let author = document.documentAuthor?.isEmpty == false ? document.documentAuthor : nil
        
        // 5. 提取每页文本并按逻辑分章
        var chapters: [ParsedChapter] = []
        var totalLocation = 0
        
        // 策略：使用 PDF 大纲（目录）来分章，如果没有大纲则按固定页数分章
        let outline = parseOutline(from: document)
        
        if !outline.isEmpty {
            // 有大纲，按大纲分章
            chapters = parseChaptersByOutline(
                document: document,
                outline: outline,
                pageCount: pageCount
            )
        } else {
            // 无大纲，按页分组（每 N 页为一章，或单页为一章）
            chapters = parseChaptersByPages(
                document: document,
                pageCount: pageCount
            )
        }
        
        // 重新计算 startLocation 和 length
        totalLocation = 0
        for i in chapters.indices {
            chapters[i] = ParsedChapter(
                index: i,
                title: chapters[i].title,
                content: chapters[i].content,
                startLocation: totalLocation,
                length: chapters[i].content.count
            )
            totalLocation += chapters[i].content.count
        }
        
        // 如果没有解析到任何内容，报错
        if chapters.allSatisfy({ $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ParserError.parseFailed
        }
        
        return ParsedBook(
            title: title,
            author: author,
            chapters: chapters,
            format: .pdf,
            filePath: fileURL.path
        )
    }
    
    // MARK: - PDF 大纲解析
    
    /// 大纲节点
    private struct OutlineNode {
        let title: String
        let pageIndex: Int
        let level: Int
    }
    
    /// 解析 PDF 大纲（目录树）
    private func parseOutline(from document: PDFDocument) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        
        guard let outline = document.outlineRoot else {
            return nodes
        }
        
        traverseOutline(outline, level: 0, nodes: &nodes, document: document)
        
        return nodes
    }
    
    /// 递归遍历大纲树
    private func traverseOutline(_ node: PDFOutline, level: Int, nodes: inout [OutlineNode], document: PDFDocument) {
        let title = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // 获取目标页码
        var pageIndex = 0
        if let destination = node.destination,
           let pageRef = destination.page,
           let index = document.index(for: pageRef) {
            pageIndex = index
        }
        
        if !title.isEmpty {
            nodes.append(OutlineNode(title: title, pageIndex: pageIndex, level: level))
        }
        
        // 遍历子节点
        var child = node.child
        while child != nil {
            traverseOutline(child!, level: level + 1, nodes: &nodes, document: document)
            child = child?.next
        }
    }
    
    // MARK: - 按大纲分章
    
    private func parseChaptersByOutline(document: PDFDocument, outline: [OutlineNode], pageCount: Int) -> [ParsedChapter] {
        var chapters: [ParsedChapter] = []
        
        for (index, node) in outline.enumerated() {
            let startPage = node.pageIndex
            let endPage = (index + 1 < outline.count) ? outline[index + 1].pageIndex - 1 : pageCount - 1
            
            let content = extractText(from: document, startPage: startPage, endPage: endPage)
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            chapters.append(ParsedChapter(
                index: chapters.count,
                title: node.title,
                content: trimmedContent,
                startLocation: 0,
                length: trimmedContent.count
            ))
        }
        
        return chapters
    }
    
    // MARK: - 按页分章（无大纲时）
    
    private func parseChaptersByPages(document: PDFDocument, pageCount: Int) -> [ParsedChapter] {
        var chapters: [ParsedChapter] = []
        
        // 根据总页数决定分组策略
        let pagesPerChapter: Int
        if pageCount <= 20 {
            pagesPerChapter = 1 // 少于20页，每页一章
        } else if pageCount <= 100 {
            pagesPerChapter = 5
        } else {
            pagesPerChapter = 10
        }
        
        var startPage = 0
        var chapterIndex = 0
        
        while startPage < pageCount {
            let endPage = min(startPage + pagesPerChapter - 1, pageCount - 1)
            let content = extractText(from: document, startPage: startPage, endPage: endPage)
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let title: String
            if pagesPerChapter == 1 {
                title = "第 \(startPage + 1) 页"
            } else {
                title = "第 \(startPage + 1)-\(endPage + 1) 页"
            }
            
            chapters.append(ParsedChapter(
                index: chapterIndex,
                title: title,
                content: trimmedContent,
                startLocation: 0,
                length: trimmedContent.count
            ))
            
            chapterIndex += 1
            startPage = endPage + 1
        }
        
        return chapters
    }
    
    // MARK: - 文本提取
    
    /// 提取指定页码范围的文本
    private func extractText(from document: PDFDocument, startPage: Int, endPage: Int) -> String {
        var texts: [String] = []
        
        for i in startPage...endPage {
            guard let page = document.page(at: i) else { continue }
            let pageText = page.string ?? ""
            let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                texts.append(trimmed)
            }
        }
        
        return texts.joined(separator: "\n\n")
    }
}
