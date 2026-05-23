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
            throw ParserError.fileTooLarge(maxSize: fileSize)
        }
        
        // 只读取一次文件数据（使用内存映射优化大文件读取）
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            throw ParserError.readFailed
        }
        
        // 检测编码（基于已读取的 data，避免重复 I/O）
        let detectedEncoding = encoding ?? detectEncoding(from: data, fileURL: fileURL)
        
        // 解码为字符串
        guard let content = String(data: data, encoding: detectedEncoding) else {
            throw ParserError.invalidEncoding
        }
        
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
    
    /// 检测文件编码（基于已读取的 Data，避免重复 I/O）
    private func detectEncoding(from data: Data, fileURL: URL) -> String.Encoding {
        // 1. 检查 BOM（Byte Order Mark）
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return .utf8
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return .utf16LittleEndian
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return .utf16BigEndian
        }
        
        // 2. 启发式检测：读取前 4KB 进行分析
        let sampleSize = min(4096, data.count)
        let sample = data.prefix(sampleSize)
        
        // 检查是否为纯 ASCII（ASCII 是 UTF-8 的子集）
        let isPureASCII = sample.allSatisfy { $0 < 0x80 }
        if isPureASCII {
            return .utf8
        }
        
        // 检查是否为有效 UTF-8（严格验证，避免将 GBK 误判为 UTF-8）
        if isValidUTF8(data: sample) {
            return .utf8
        }
        
        // 3. 尝试 GB18030（GBK 的超集，兼容 GB2312）
        if let _ = try? String(contentsOf: fileURL, encoding: .gb_18030_2000) {
            return .gb_18030_2000
        }
        
        // 4. 尝试 Big5（繁体中文）
        if let _ = try? String(contentsOf: fileURL, encoding: .big5) {
            return .big5
        }
        
        return .utf8 // 最终兜底
    }
    
    /// 严格检查数据是否为有效 UTF-8 编码
    private func isValidUTF8(data: Data.SubSequence) -> Bool {
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            if byte < 0x80 {
                // 单字节 ASCII
                i += 1
            } else if byte >= 0xC2 && byte <= 0xDF {
                // 双字节序列
                guard i + 1 < data.endIndex,
                      data[i + 1] >= 0x80 && data[i + 1] <= 0xBF else { return false }
                i += 2
            } else if byte >= 0xE0 && byte <= 0xEF {
                // 三字节序列
                guard i + 2 < data.endIndex,
                      data[i + 1] >= 0x80 && data[i + 1] <= 0xBF,
                      data[i + 2] >= 0x80 && data[i + 2] <= 0xBF else { return false }
                // E0 开头时，第二个字节不能是 0x80-0x9F（过长编码）
                if byte == 0xE0 && data[i + 1] < 0xA0 { return false }
                i += 3
            } else if byte >= 0xF0 && byte <= 0xF4 {
                // 四字节序列
                guard i + 3 < data.endIndex,
                      data[i + 1] >= 0x80 && data[i + 1] <= 0xBF,
                      data[i + 2] >= 0x80 && data[i + 2] <= 0xBF,
                      data[i + 3] >= 0x80 && data[i + 3] <= 0xBF else { return false }
                // F4 开头时，第二个字节不能超过 0x8F（超出 Unicode 范围）
                if byte == 0xF4 && data[i + 1] > 0x8F { return false }
                i += 4
            } else {
                // 0xC0-0xC1（过长编码）或 0xF5-0xFF（无效字节）
                return false
            }
        }
        return true
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
                        length: chapterContent.count
                    ))
                    currentLocation += chapterContent.count
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
                length: chapterContent.count
            ))
        }
        
        // 如果没有解析到章节，将整本书作为一章
        if chapters.isEmpty {
            chapters.append(ParsedChapter(
                index: 0,
                title: "正文",
                content: content,
                startLocation: 0,
                length: content.count
            ))
        }
        
        return chapters
    }
    
    /// 判断是否为章节标题
    private func isChapterTitle(_ line: String) -> Bool {
        // 过滤太短的行
        guard line.count >= 2 && line.count <= 50 else { return false }
        
        // 检查是否匹配任何章节模式
        for pattern in chapterPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: line.utf16.count)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    return true
                }
            }
        }
        
        return false
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
    case fileTooLarge(maxSize: Int64)
    
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
