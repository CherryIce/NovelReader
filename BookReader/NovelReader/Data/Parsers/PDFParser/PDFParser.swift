import Foundation
import PDFKit

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
            throw ParserError.fileTooLarge(actualSize: fileSize, maximumSize: maxFileSize)
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
        let attributes = document.documentAttributes
        let metadataTitle = attributes?[PDFDocumentAttribute.titleAttribute] as? String
        let metadataAuthor = attributes?[PDFDocumentAttribute.authorAttribute] as? String
        let title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent
        let author = metadataAuthor.flatMap { $0.isEmpty ? nil : $0 }
        
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

            // 部分 PDF 的目录目标页无效或全部落在同一页。目录无法形成有效章节时，
            // 回退到稳定的按页分章，避免导入失败或生成空书籍。
            if chapters.isEmpty {
                chapters = parseChaptersByPages(
                    document: document,
                    pageCount: pageCount
                )
            }
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
                length: chapters[i].content.utf16.count
            )
            totalLocation += chapters[i].content.utf16.count
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
    }

    struct PageRange: Equatable {
        let startPage: Int
        let endPage: Int
    }

    /// 将 PDF 大纲中的页码整理为递增、不重叠且位于文档范围内的章节区间。
    /// PDF 目录允许嵌套、重复目标页，第三方文件也可能写入越界目标页。
    static func normalizedPageRanges(pageIndices: [Int], pageCount: Int) -> [PageRange] {
        guard pageCount > 0 else { return [] }

        let validStartPages = Array(Set(pageIndices.filter { (0..<pageCount).contains($0) })).sorted()
        return validStartPages.enumerated().map { index, startPage in
            let endPage = index + 1 < validStartPages.count
                ? validStartPages[index + 1] - 1
                : pageCount - 1
            return PageRange(startPage: startPage, endPage: endPage)
        }
    }
    
    /// 解析 PDF 大纲（目录树）
    private func parseOutline(from document: PDFDocument) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        
        guard let outline = document.outlineRoot else {
            return nodes
        }
        
        traverseOutline(outline, nodes: &nodes, document: document)
        
        return nodes
    }
    
    /// 递归遍历大纲树
    private func traverseOutline(_ node: PDFOutline, nodes: inout [OutlineNode], document: PDFDocument) {
        let title = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 没有目标页的分组节点不能作为章节起点，否则会被错误归到第 1 页。
        if !title.isEmpty,
           let page = node.destination?.page {
            nodes.append(OutlineNode(title: title, pageIndex: document.index(for: page)))
        }
        
        // 遍历子节点
        for childIndex in 0..<node.numberOfChildren {
            if let child = node.child(at: childIndex) {
                traverseOutline(child, nodes: &nodes, document: document)
            }
        }
    }
    
    // MARK: - 按大纲分章
    
    private func parseChaptersByOutline(document: PDFDocument, outline: [OutlineNode], pageCount: Int) -> [ParsedChapter] {
        var chapters: [ParsedChapter] = []

        // 同一页可能同时挂有父级和子级目录。保留遍历到的第一个标题，
        // 再按实际页码排序，避免出现 5...3 这类非法闭区间导致运行时崩溃。
        var nodeByPage: [Int: OutlineNode] = [:]
        for node in outline where (0..<pageCount).contains(node.pageIndex) {
            if nodeByPage[node.pageIndex] == nil {
                nodeByPage[node.pageIndex] = node
            }
        }

        let ranges = Self.normalizedPageRanges(
            pageIndices: Array(nodeByPage.keys),
            pageCount: pageCount
        )

        for range in ranges {
            guard let node = nodeByPage[range.startPage] else { continue }
            let content = extractText(
                from: document,
                startPage: range.startPage,
                endPage: range.endPage
            )
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedContent.isEmpty else { continue }
            
            chapters.append(ParsedChapter(
                index: chapters.count,
                title: node.title,
                content: trimmedContent,
                startLocation: 0,
                length: trimmedContent.utf16.count
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
                length: trimmedContent.utf16.count
            ))
            
            chapterIndex += 1
            startPage = endPage + 1
        }
        
        return chapters
    }
    
    // MARK: - 文本提取
    
    /// 提取指定页码范围的文本
    private func extractText(from document: PDFDocument, startPage: Int, endPage: Int) -> String {
        guard document.pageCount > 0 else { return "" }

        let lowerBound = max(0, startPage)
        let upperBound = min(endPage, document.pageCount - 1)
        guard lowerBound <= upperBound else { return "" }

        var texts: [String] = []
        
        for i in lowerBound...upperBound {
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
