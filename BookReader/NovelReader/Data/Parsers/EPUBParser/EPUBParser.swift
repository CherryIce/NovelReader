import Foundation
import UIKit

private func containedFileURL(baseURL: URL, relativePath: String) -> URL? {
    let normalizedPath = relativePath.replacingOccurrences(of: "\\", with: "/")
    guard !normalizedPath.isEmpty, !normalizedPath.hasPrefix("/") else { return nil }

    let standardizedBase = baseURL.standardizedFileURL
    let candidate = standardizedBase.appendingPathComponent(normalizedPath).standardizedFileURL
    let basePrefix = standardizedBase.path.hasSuffix("/")
        ? standardizedBase.path
        : standardizedBase.path + "/"
    guard candidate.path.hasPrefix(basePrefix) else { return nil }
    return candidate
}

/// EPUB 文件解析器
/// EPUB 本质是 ZIP 压缩包，内含 XHTML/HTML 内容文件
class EPUBParser {
    
    /// 最大支持文件大小：200MB
    private let maxFileSize: Int64 = 200 * 1024 * 1024
    
    /// 解析 EPUB 文件
    /// - Parameter fileURL: EPUB 文件路径
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
            throw ParserError.fileTooLarge(actualSize: fileSize)
        }
        
        // 3. 解压 EPUB 到临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        try FileManager.default.unzipItem(at: fileURL, to: tempDir)
        
        // 4. 解析 container.xml 获取 OPF 路径
        let containerPath = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = FileManager.default.contents(atPath: containerPath.path),
              let containerXML = String(data: containerData, encoding: .utf8) else {
            throw ParserError.parseFailed
        }
        
        let opfRelativePath = parseContainerXML(containerXML)
        guard let opfFullPath = containedFileURL(baseURL: tempDir, relativePath: opfRelativePath) else {
            throw ParserError.parseFailed
        }
        let opfDir = opfFullPath.deletingLastPathComponent()
        
        // 5. 解析 OPF 文件获取元数据和阅读顺序
        guard let opfData = FileManager.default.contents(atPath: opfFullPath.path),
              let opfXML = String(data: opfData, encoding: .utf8) else {
            throw ParserError.parseFailed
        }
        
        let opfInfo = parseOPF(opfXML)
        
        // 6. 按阅读顺序解析每个 XHTML/HTML 文件的内容
        var chapters: [ParsedChapter] = []
        var totalLocation = 0
        
        for (index, spineItem) in opfInfo.spineOrder.enumerated() {
            // 在 manifest 中查找对应的 href
            guard let manifestItem = opfInfo.manifest[spineItem],
                  let href = manifestItem.href else {
                continue
            }
            
            // 解码 URL（处理 percent encoding）
            let decodedHref = href.removingPercentEncoding ?? href
            guard let contentPath = containedFileURL(baseURL: opfDir, relativePath: decodedHref) else {
                continue
            }
            
            // 读取内容文件
            guard let contentData = FileManager.default.contents(atPath: contentPath.path),
                  let htmlString = String(data: contentData, encoding: .utf8) else {
                continue
            }
            
            // 提取纯文本和标题
            let (title, content) = extractTextFromHTML(htmlString, fallbackTitle: "第\(index + 1)章")
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !trimmedContent.isEmpty else { continue }
            
            let chapterLength = trimmedContent.utf16.count
            chapters.append(ParsedChapter(
                index: chapters.count,
                title: title,
                content: trimmedContent,
                startLocation: totalLocation,
                length: chapterLength
            ))
            totalLocation += chapterLength
        }
        
        // 如果没有解析到任何章节，尝试直接扫描目录下的 HTML 文件
        if chapters.isEmpty {
            chapters = try fallbackParseHTMLFiles(in: opfDir)
        }
        
        // 如果仍然为空，报错
        if chapters.isEmpty {
            throw ParserError.parseFailed
        }
        
        // 7. 提取书名
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let title = opfInfo.title ?? fileName
        let author = opfInfo.author
        
        return ParsedBook(
            title: title,
            author: author,
            chapters: chapters,
            format: .epub,
            filePath: fileURL.path
        )
    }
    
    // MARK: - XML 解析
    
    /// 解析 container.xml，返回 OPF 文件的相对路径
    private func parseContainerXML(_ xml: String) -> String {
        // 使用正则提取 rootfile 的 full-path
        let pattern = #"full-path="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            // 默认路径
            return "OEBPS/content.opf"
        }
        return String(xml[range])
    }
    
    /// OPF 解析结果
    private struct OPFInfo {
        var title: String?
        var author: String?
        var manifest: [String: (mediaType: String?, href: String?)] = [:]
        var spineOrder: [String] = []
    }
    
    /// 解析 OPF 文件
    private func parseOPF(_ xml: String) -> OPFInfo {
        var info = OPFInfo()
        
        // 提取标题
        if let match = firstMatch(xml: xml, pattern: #"<dc:title[^>]*>([^<]*)</dc:title>"#) {
            info.title = decodeHTMLEntities(match)
        }
        
        // 提取作者
        if let match = firstMatch(xml: xml, pattern: #"<dc:creator[^>]*>([^<]*)</dc:creator>"#) {
            info.author = decodeHTMLEntities(match)
        }
        
        // 提取 manifest 项
        // 使用更宽松的正则来匹配 manifest item
        let itemPattern = #"<item\s+([^>]+)/?>|<item\s+([^>]+)>"#
        if let regex = try? NSRegularExpression(pattern: itemPattern, options: [.caseInsensitive]) {
            let fullRange = NSRange(xml.startIndex..., in: xml)
            regex.enumerateMatches(in: xml, options: [], range: fullRange) { match, _, _ in
                guard let match = match else { return }
                let tagContent: String
                let firstRange = match.range(at: 1)
                let secondRange = match.range(at: 2)
                if firstRange.location != NSNotFound {
                    tagContent = (xml as NSString).substring(with: firstRange)
                } else if secondRange.location != NSNotFound {
                    tagContent = (xml as NSString).substring(with: secondRange)
                } else {
                    return
                }
                
                let id = extractAttribute(tagContent, name: "id")
                let href = extractAttribute(tagContent, name: "href")
                let mediaType = extractAttribute(tagContent, name: "media-type")
                
                if let id = id {
                    info.manifest[id] = (mediaType: mediaType, href: href)
                }
            }
        }
        
        // 提取 spine 阅读顺序
        let spinePattern = #"<itemref\s+[^>]*idref="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: spinePattern, options: [.caseInsensitive]) {
            let fullRange = NSRange(xml.startIndex..., in: xml)
            regex.enumerateMatches(in: xml, options: [], range: fullRange) { match, _, _ in
                guard let match = match,
                      let range = Range(match.range(at: 1), in: xml) else { return }
                info.spineOrder.append(String(xml[range]))
            }
        }
        
        return info
    }
    
    // MARK: - HTML 文本提取
    
    /// 从 HTML 中提取纯文本和章节标题
    private func extractTextFromHTML(_ html: String, fallbackTitle: String) -> (title: String, content: String) {
        // 提取 <title> 或 <h1>-<h3> 作为章节标题
        var chapterTitle = fallbackTitle
        
        // 优先匹配 <h1>, <h2>, <h3>
        let headingPatterns = [
            #"<h[1-3][^>]*>([^<]*(?:<[^>]*>[^<]*)*)</h[1-3]>"#,
            #"<title[^>]*>([^<]*)</title>"#
        ]
        
        for pattern in headingPatterns {
            if let match = firstMatch(xml: html, pattern: pattern) {
                let cleanTitle = stripHTMLTags(match).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    chapterTitle = cleanTitle
                    break
                }
            }
        }
        
        // 提取 body 内容
        let bodyContent: String
        if let bodyRange = html.range(of: "<body", options: .caseInsensitive),
           let bodyStart = html.range(of: ">", range: bodyRange.upperBound..<html.endIndex),
           let bodyEnd = html.range(of: "</body>", options: .caseInsensitive, range: bodyStart.upperBound..<html.endIndex) {
            bodyContent = String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
        } else {
            bodyContent = html
        }
        
        // 移除 script 和 style 标签及其内容
        var cleanContent = bodyContent
        cleanContent = removeTagAndContent(cleanContent, tagName: "script")
        cleanContent = removeTagAndContent(cleanContent, tagName: "style")
        
        // 将块级元素替换为换行
        let blockTags = ["p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote", "hr"]
        for tag in blockTags {
            let closePattern = "</\(tag)>"
            let selfClosePattern = "<\(tag)[^>]*/?>"
            cleanContent = cleanContent.replacingOccurrences(of: closePattern, with: "\n", options: .caseInsensitive)
            cleanContent = cleanContent.replacingOccurrences(of: selfClosePattern, with: "\n", options: .caseInsensitive)
        }
        
        // 移除所有剩余 HTML 标签
        cleanContent = stripHTMLTags(cleanContent)
        
        // 解码 HTML 实体
        cleanContent = decodeHTMLEntities(cleanContent)
        
        // 清理多余空白
        cleanContent = cleanContent
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n +", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        
        return (chapterTitle, cleanContent.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    /// 移除指定标签及其内容
    private func removeTagAndContent(_ html: String, tagName: String) -> String {
        // 匹配 <tag ...>...</tag>（非贪婪）
        let pattern = "<\(tagName)[^>]*>.*?</\(tagName)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }
    
    /// 去除所有 HTML 标签
    private func stripHTMLTags(_ html: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }
    
    /// 解码常见 HTML 实体
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        // 命名实体
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&#39;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&copy;", "©"),
            ("&reg;", "®"),
            ("&trade;", "™"),
            ("&laquo;", "«"),
            ("&raquo;", "»"),
            ("&ldquo;", "\u{201C}"),
            ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        
        // 数字实体 &#NNNN;
        let numericPattern = "&#(\\d+);"
        if let regex = try? NSRegularExpression(pattern: numericPattern, options: []) {
            let nsResult = result as NSString
            let range = NSRange(location: 0, length: nsResult.length)
            let matches = regex.matches(in: result, options: [], range: range)
            // 从后往前替换，避免索引偏移
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let code = Int(result[codeRange]),
                   let scalar = Unicode.Scalar(code) {
                    let char = Character(scalar)
                    if let matchRange = Range(match.range, in: result) {
                        result.replaceSubrange(matchRange, with: String(char))
                    }
                }
            }
        }
        
        return result
    }
    
    // MARK: - 工具方法
    
    /// 正则首次匹配
    private func firstMatch(xml: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range),
              let matchRange = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[matchRange])
    }
    
    /// 从 HTML 属性字符串中提取指定属性值
    private func extractAttribute(_ tagContent: String, name: String) -> String? {
        // 匹配 name="value" 或 name='value'
        // 动态构建正则
        let dynamicPattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: dynamicPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(tagContent.startIndex..., in: tagContent)
        guard let match = regex.firstMatch(in: tagContent, options: [], range: range),
              let matchRange = Range(match.range(at: 1), in: tagContent) else {
            return nil
        }
        return String(tagContent[matchRange])
    }
    
    /// 回退方案：扫描目录中的 HTML/XHTML 文件
    private func fallbackParseHTMLFiles(in directory: URL) throws -> [ParsedChapter] {
        var chapters: [ParsedChapter] = []
        var totalLocation = 0
        
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let htmlFiles = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "html" || ext == "htm" || ext == "xhtml"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        for (index, fileURL) in htmlFiles.enumerated() {
            guard let data = FileManager.default.contents(atPath: fileURL.path),
                  let html = String(data: data, encoding: .utf8) else {
                continue
            }
            
            let (title, content) = extractTextFromHTML(html, fallbackTitle: "第\(index + 1)章")
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContent.isEmpty else { continue }
            
            let length = trimmedContent.utf16.count
            chapters.append(ParsedChapter(
                index: chapters.count,
                title: title,
                content: trimmedContent,
                startLocation: totalLocation,
                length: length
            ))
            totalLocation += length
        }
        
        return chapters
    }
}

// MARK: - FileManager ZIP 解压扩展

extension FileManager {
    /// 解压 ZIP 文件到目标目录（使用系统内置的 libcompression）
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let archive = Archive(url: sourceURL) else {
            throw ParserError.parseFailed
        }
        
        try archive.extract(to: destinationURL)
    }
}

// MARK: - 轻量级 ZIP 解压（基于 Compression 框架的 raw deflate）

import Compression

/// 简易 ZIP Archive 解压器
/// 仅支持 DEFLATE 和 STORE 方法，满足 EPUB 需求
private final class Archive {
    private let fileHandle: FileHandle
    private let fileSize: UInt64
    private let centralDirectoryOffset: UInt64
    private var entries: [Entry] = []
    private static let maximumEntrySize: UInt64 = 64 * 1024 * 1024
    private static let maximumTotalUncompressedSize: UInt64 = 256 * 1024 * 1024
    
    struct Entry {
        let filename: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let compressionMethod: UInt16
        let localHeaderOffset: UInt32
        let crc32: UInt32
    }
    
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        self.fileHandle = handle

        do {
            // 读取 End of Central Directory Record
            let fileSize = try handle.seekToEnd()
            self.fileSize = fileSize
            let maximumEOCDSearchLength = 65_557
            let tailLength = min(maximumEOCDSearchLength, Int(fileSize))
            try handle.seek(toOffset: fileSize - UInt64(tailLength))
            let tailData = handle.readData(ofLength: tailLength)

            guard let eocdOffset = Self.findEOCD(in: tailData),
                  let totalEntries = tailData.readUInt16LE(at: eocdOffset + 10),
                  let centralDirectorySize = tailData.readUInt32LE(at: eocdOffset + 12),
                  let centralDirectoryOffset = tailData.readUInt32LE(at: eocdOffset + 16) else {
                handle.closeFile()
                return nil
            }

            let directoryEnd = UInt64(centralDirectoryOffset) + UInt64(centralDirectorySize)
            guard directoryEnd <= fileSize else {
                handle.closeFile()
                return nil
            }

            self.centralDirectoryOffset = UInt64(centralDirectoryOffset)

            // 解析 Central Directory
            try handle.seek(toOffset: self.centralDirectoryOffset)
            let cdData = handle.readData(ofLength: Int(centralDirectorySize))
            guard cdData.count == Int(centralDirectorySize) else {
                handle.closeFile()
                return nil
            }

            var offset = 0
            var totalUncompressedSize: UInt64 = 0
            for _ in 0..<totalEntries {
                guard offset + 46 <= cdData.count,
                      cdData.readUInt32LE(at: offset) == 0x02014B50,
                      let compressionMethod = cdData.readUInt16LE(at: offset + 10),
                      let crc32 = cdData.readUInt32LE(at: offset + 16),
                      let compressedSize = cdData.readUInt32LE(at: offset + 20),
                      let uncompressedSize = cdData.readUInt32LE(at: offset + 24),
                      let filenameLength = cdData.readUInt16LE(at: offset + 28),
                      let extraLength = cdData.readUInt16LE(at: offset + 30),
                      let commentLength = cdData.readUInt16LE(at: offset + 32),
                      let localHeaderOffset = cdData.readUInt32LE(at: offset + 42) else {
                    handle.closeFile()
                    return nil
                }

                let filenameByteCount = Int(filenameLength)
                let extraByteCount = Int(extraLength)
                let commentByteCount = Int(commentLength)
                let entryLength = 46 + filenameByteCount + extraByteCount + commentByteCount
                guard offset + entryLength <= cdData.count else {
                    handle.closeFile()
                    return nil
                }

                let filenameStart = offset + 46
                let filenameEnd = filenameStart + Int(filenameLength)
                let filenameData = Data(cdData[filenameStart..<filenameEnd])
                guard let filename = String(data: filenameData, encoding: .utf8), !filename.isEmpty else {
                    handle.closeFile()
                    return nil
                }

                let entryUncompressedSize = UInt64(uncompressedSize)
                guard entryUncompressedSize <= Self.maximumEntrySize,
                      totalUncompressedSize <= Self.maximumTotalUncompressedSize - entryUncompressedSize else {
                    handle.closeFile()
                    return nil
                }
                totalUncompressedSize += entryUncompressedSize

                entries.append(Entry(
                    filename: filename,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    compressionMethod: compressionMethod,
                    localHeaderOffset: localHeaderOffset,
                    crc32: crc32
                ))
                offset += entryLength
            }

            guard entries.count == Int(totalEntries) else {
                handle.closeFile()
                return nil
            }
        } catch {
            handle.closeFile()
            return nil
        }
    }
    
    func extract(to destinationURL: URL) throws {
        for entry in entries {
            // 跳过目录和隐藏文件（macOS 的 __MACOSX 等）
            if entry.filename.hasSuffix("/") || entry.filename.hasPrefix("__MACOSX") || entry.filename.contains("/__MACOSX") {
                continue
            }

            guard let targetURL = containedFileURL(baseURL: destinationURL, relativePath: entry.filename) else {
                throw ParserError.parseFailed
            }

            // 创建父目录
            let parentDir = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // 读取 Local File Header 获取实际数据偏移
            try fileHandle.seek(toOffset: UInt64(entry.localHeaderOffset))
            let localHeader = fileHandle.readData(ofLength: 30)
            guard localHeader.count == 30,
                  localHeader.readUInt32LE(at: 0) == 0x04034B50,
                  let localFilenameLen = localHeader.readUInt16LE(at: 26),
                  let localExtraLen = localHeader.readUInt16LE(at: 28) else {
                throw ParserError.parseFailed
            }

            let dataOffset = UInt64(entry.localHeaderOffset) + 30 + UInt64(localFilenameLen) + UInt64(localExtraLen)
            guard dataOffset <= fileSize,
                  UInt64(entry.compressedSize) <= fileSize - dataOffset else {
                throw ParserError.parseFailed
            }

            try fileHandle.seek(toOffset: dataOffset)
            let compressedData = fileHandle.readData(ofLength: Int(entry.compressedSize))
            guard compressedData.count == Int(entry.compressedSize) else {
                throw ParserError.parseFailed
            }

            let decompressedData: Data
            switch entry.compressionMethod {
            case 0: // STORE
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ParserError.parseFailed
                }
                decompressedData = compressedData
            case 8: // DEFLATE
                decompressedData = try inflateDeflateData(compressedData, expectedSize: Int(entry.uncompressedSize))
            default:
                throw ParserError.parseFailed
            }

            try decompressedData.write(to: targetURL, options: [.atomic, .withoutOverwriting])
        }
    }

    /// 使用 Compression 框架的 compression_decode_buffer 解压 raw DEFLATE 数据
    private func inflateDeflateData(_ compressedData: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw ParserError.parseFailed }
        if expectedSize == 0 { return Data() }

        var outputBuffer = [UInt8](repeating: 0, count: expectedSize)

        let decodedSize = compressedData.withUnsafeBytes { srcPtr -> Int in
            outputBuffer.withUnsafeMutableBufferPointer { dstPtr in
                compression_decode_buffer(
                    dstPtr.baseAddress!,
                    dstPtr.count,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    compressedData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize == expectedSize else { throw ParserError.parseFailed }
        return Data(outputBuffer)
    }
    
    deinit {
        try? fileHandle.close()
    }
    
    // MARK: - 辅助
    
    /// 在文件尾部数据中查找 End of Central Directory Record
    private static func findEOCD(in tailData: Data) -> Int? {
        guard tailData.count >= 22 else { return nil }
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let tailBytes = [UInt8](tailData)

        for i in stride(from: tailBytes.count - 22, through: 0, by: -1) {
            if i + 4 <= tailBytes.count {
                if tailBytes[i] == signature[0] &&
                   tailBytes[i+1] == signature[1] &&
                   tailBytes[i+2] == signature[2] &&
                   tailBytes[i+3] == signature[3] {
                    return i
                }
            }
        }
        return nil
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16? {
        guard offset >= startIndex, offset + 2 <= endIndex else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= startIndex, offset + 4 <= endIndex else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
