import Foundation

/// TXT文件解析器
class TXTParser {
    
    /// 最大支持文件大小：50MB
    private let maxFileSize: Int64 = 50 * 1024 * 1024
    
    /// 章节标题正则表达式模式
    private let chapterPatterns: [String] = [
        "^第[一二三四五六七八九十百千万零\\d]+章.*$",  // 第X章
        "^第[\\d]+章.*$",                              // 第1章
        "^Chapter\\s*\\d+.*$",                        // Chapter 1
        "^\\d+[.．、\\s]+.*$",                         // 1. 或 1、
        "^[（(【\\[]?[\\d一二三四五六七八九十]+[)）】\\]]?.*$"  // （一）或【1】
    ]

    private lazy var chapterRegexes: [NSRegularExpression] = chapterPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
    }
    
    /// 解析TXT文件
    /// - Parameters:
    ///   - fileURL: 文件URL
    ///   - encoding: 文件编码，nil时自动检测
    /// - Returns: 解析结果
    func parse(fileURL: URL, encoding: String.Encoding? = nil) throws -> ParsedBook {
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound
        }
        
        // 检查文件大小
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize > maxFileSize {
            throw ParserError.fileTooLarge(actualSize: fileSize)
        }
        
        // 只读取一次文件数据（使用内存映射优化大文件读取）
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            throw ParserError.readFailed
        }
        
        // 以整文件严格解码，避免仅抽样文件头导致编码误判
        let content = try decode(data: data, preferredEncoding: encoding)
        
        // 解析章节
        let chapters = parseChapters(from: content)
        
        // 提取书名（从文件名）
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        
        return ParsedBook(
            title: fileName,
            author: nil,
            chapters: chapters,
            format: .txt,
            filePath: fileURL.path
        )
    }
    
    /// 按显式编码、BOM、常见中文编码顺序解码
    private func decode(data: Data, preferredEncoding: String.Encoding?) throws -> String {
        if let preferredEncoding = preferredEncoding {
            guard let content = String(data: data, encoding: preferredEncoding) else {
                throw ParserError.invalidEncoding
            }
            return content
        }

        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            guard let content = String(data: data, encoding: .utf8) else {
                throw ParserError.invalidEncoding
            }
            return content
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            guard let content = String(data: data, encoding: .utf16LittleEndian) else {
                throw ParserError.invalidEncoding
            }
            return content
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            guard let content = String(data: data, encoding: .utf16BigEndian) else {
                throw ParserError.invalidEncoding
            }
            return content
        }

        for candidate in [String.Encoding.utf8, .gb_18030_2000, .big5] {
            if let content = String(data: data, encoding: candidate) {
                return content
            }
        }

        throw ParserError.invalidEncoding
    }
    
    /// 解析章节
    private func parseChapters(from content: String) -> [ParsedChapter] {
        let lines = content.components(separatedBy: .newlines)
        var chapters: [ParsedChapter] = []
        var currentChapterTitle = "前言"
        var currentChapterContent: [String] = []
        var currentLocation = 0
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // 检查是否是章节标题
            if isChapterTitle(trimmedLine) {
                // 保存上一章节
                if !currentChapterContent.isEmpty {
                    let chapterContent = currentChapterContent.joined(separator: "\n")
                    chapters.append(ParsedChapter(
                        index: chapters.count,
                        title: currentChapterTitle,
                        content: chapterContent,
                        startLocation: currentLocation,
                        length: chapterContent.utf16.count
                    ))
                    currentLocation += chapterContent.utf16.count
                }
                
                // 开始新章节
                currentChapterTitle = trimmedLine
                currentChapterContent = []
            } else {
                currentChapterContent.append(line)
            }
        }
        
        // 保存最后一章
        if !currentChapterContent.isEmpty {
            let chapterContent = currentChapterContent.joined(separator: "\n")
            chapters.append(ParsedChapter(
                index: chapters.count,
                title: currentChapterTitle,
                content: chapterContent,
                startLocation: currentLocation,
                length: chapterContent.utf16.count
            ))
        }
        
        // 如果没有解析到章节，将整本书作为一章
        if chapters.isEmpty {
            chapters.append(ParsedChapter(
                index: 0,
                title: "正文",
                content: content,
                startLocation: 0,
                length: content.utf16.count
            ))
        }
        
        return chapters
    }
    
    /// 判断是否为章节标题
    private func isChapterTitle(_ line: String) -> Bool {
        // 过滤太短的行
        guard line.count >= 2 && line.count <= 50 else { return false }
        
        // 检查是否匹配任何章节模式
        let range = NSRange(location: 0, length: line.utf16.count)
        for regex in chapterRegexes {
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                return true
            }
        }
        
        return false
    }
}

extension TXTParser: BookChapterParsing {
    func parseChapters(fileURL: URL) throws -> [Chapter] {
        try parse(fileURL: fileURL).chapters.map { parsedChapter in
            Chapter(
                index: parsedChapter.index,
                title: parsedChapter.title,
                content: parsedChapter.content,
                startLocation: parsedChapter.startLocation,
                length: parsedChapter.length
            )
        }
    }
}

// MARK: - 解析结果模型

struct ParsedBook {
    let title: String
    let author: String?
    let chapters: [ParsedChapter]
    let format: BookFormat
    let filePath: String
}

struct ParsedChapter {
    let index: Int
    let title: String
    let content: String
    let startLocation: Int
    let length: Int
}

// MARK: - 错误类型

enum ParserError: LocalizedError {
    case fileNotFound
    case readFailed
    case invalidEncoding
    case parseFailed
    case fileTooLarge(actualSize: Int64)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "文件不存在"
        case .readFailed:
            return "文件读取失败，请检查文件权限"
        case .invalidEncoding:
            return "无法识别文件编码，请确保文件为 UTF-8、GBK 或 Big5 编码"
        case .parseFailed:
            return "文件解析失败"
        case .fileTooLarge(let size):
            let sizeMB = size / 1024 / 1024
            return "文件过大（\(sizeMB)MB），暂不支持超过 50MB 的文件"
        }
    }
}

// MARK: - String.Encoding 扩展

extension String.Encoding {
    /// GB18030 编码（GBK 的超集，兼容 GB2312）
    static let gb_18030_2000 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    
    /// Big5 编码（繁体中文）
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5.rawValue)))
}
