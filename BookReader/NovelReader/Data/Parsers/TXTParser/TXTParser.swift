import Foundation

/// TXT文件解析器
class TXTParser {
    
    /// 最大支持文件大小：50MB
    private let maxFileSize: Int64 = 50 * 1024 * 1024
    
    /// 明确的章节标记。括号必须成对，不能把以“一”或数字开头的正文当标题。
    private let explicitChapterPatterns: [String] = [
        "^第[零〇一二两三四五六七八九十百千万\\d０-９]+章.*$",
        "^Chapter\\s*\\d+\\b.*$",
        "^(?:（[一二三四五六七八九十\\d]+）|\\([一二三四五六七八九十\\d]+\\)|【[一二三四五六七八九十\\d]+】|\\[[一二三四五六七八九十\\d]+\\])(?:[^。！？；]*)$"
    ]
    private let supplementalChapterPatterns: [String] = [
        "^第[零〇一二两三四五六七八九十百千万\\d０-９]+回.*$",
        "^第[零〇一二两三四五六七八九十百千万\\d０-９]+卷.{0,35}第[零〇一二两三四五六七八九十百千万\\d０-９]+章.*$"
    ]
    private let numberedChapterPattern = "^([1-9]\\d{0,3})[.．、][ \\t　]*(?!\\d)[^。！？；，,……\\r\\n]{1,40}$"

    private lazy var explicitChapterRegexes: [NSRegularExpression] = (explicitChapterPatterns + supplementalChapterPatterns).compactMap {
        try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
    }
    private lazy var supplementalChapterRegexes: [NSRegularExpression] = supplementalChapterPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
    }
    private lazy var volumeChapterRegex = try? NSRegularExpression(pattern: supplementalChapterPatterns[1])
    private lazy var numberedChapterRegex = try? NSRegularExpression(pattern: numberedChapterPattern)
    
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
            throw ParserError.fileTooLarge(actualSize: fileSize, maximumSize: maxFileSize)
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
        let detectedTitles = chapterTitleIndexes(in: lines)
        let redundantTitles = redundantTitleIndexes(in: lines, titles: detectedTitles)
        let titles = detectedTitles.subtracting(redundantTitles)
        var chapters: [ParsedChapter] = []
        var currentChapterTitle = "前言"
        var currentChapterContent: [String] = []
        var currentLocation = 0
        var hasChapterHeading = false
        
        for (lineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // 检查是否是章节标题
            if titles.contains(lineIndex) {
                // 保存上一章节
                if !currentChapterContent.isEmpty || hasChapterHeading {
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
                hasChapterHeading = true
            } else if !redundantTitles.contains(lineIndex) {
                currentChapterContent.append(line)
            }
        }
        
        // 保存最后一章
        if !currentChapterContent.isEmpty || hasChapterHeading {
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
    
    /// 先选择整本书使用的标题样式；已有明确章节标记时忽略数字列表。
    private func chapterTitleIndexes(in lines: [String]) -> Set<Int> {
        let explicit = Set(lines.indices.filter { isExplicitTitle(lines[$0].trimmingCharacters(in: .whitespaces)) })
        if !explicit.isEmpty { return explicit }

        let numbered = lines.indices.compactMap { index -> (index: Int, number: Int)? in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard let number = numberedTitleNumber(line) else { return nil }
            return (index, number)
        }

        var titles = Set<Int>()
        for (first, second) in zip(numbered, numbered.dropFirst()) {
            guard second.number == first.number + 1 else { continue }
            let bodyLength = lines[(first.index + 1)..<second.index]
                .reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
            guard bodyLength >= 50 else { continue }
            titles.insert(first.index)
            titles.insert(second.index)
        }
        return titles
    }

    /// 卷章复合标题后若紧跟同一章的短标题，只保留一个目录项和一份正文。
    private func redundantTitleIndexes(in lines: [String], titles: Set<Int>) -> Set<Int> {
        guard let volumeChapterRegex else { return [] }
        var redundant = Set<Int>()
        for index in titles where titles.contains(index + 1) {
            let first = lines[index].trimmingCharacters(in: .whitespaces)
            let second = lines[index + 1].trimmingCharacters(in: .whitespaces)
            let firstRange = NSRange(location: 0, length: first.utf16.count)
            guard volumeChapterRegex.firstMatch(in: first, range: firstRange) != nil,
                  let chapterPart = chapterPart(in: first),
                  chapterPart == second.filter({ !$0.isWhitespace }) else { continue }
            redundant.insert(index + 1)
        }
        return redundant
    }

    private func chapterPart(in title: String) -> String? {
        guard let range = title.range(
            of: "第[零〇一二两三四五六七八九十百千万\\d０-９]+章",
            options: .regularExpression
        ) else { return nil }
        return String(title[range.lowerBound...].filter { !$0.isWhitespace })
    }

    private func isExplicitTitle(_ line: String) -> Bool {
        guard (2...50).contains(line.count) else { return false }
        let range = NSRange(location: 0, length: line.utf16.count)
        for regex in explicitChapterRegexes {
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private func isSupplementalTitle(_ line: String) -> Bool {
        guard (2...50).contains(line.count) else { return false }
        let range = NSRange(location: 0, length: line.utf16.count)
        return supplementalChapterRegexes.contains {
            $0.firstMatch(in: line, range: range) != nil
        }
    }

    private func numberedTitleNumber(_ line: String) -> Int? {
        guard (2...50).contains(line.count), let regex = numberedChapterRegex else { return nil }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[numberRange])
    }

    /// 已保存目录含旧版宽松规则产生的标题时，打开书籍后从原文件重建。
    func needsLegacyRepair(_ chapters: [Chapter]) -> Bool {
        // 旧规则遗漏的“回”或“卷…章”可能仍藏在已保存的正文中。
        if chapters.contains(where: { chapter in
            chapter.content.components(separatedBy: .newlines).contains {
                isSupplementalTitle($0.trimmingCharacters(in: .whitespaces))
            }
        }) {
            return true
        }
        let hasExplicitTitle = chapters.contains { isExplicitTitle($0.title) }
        guard hasExplicitTitle else {
            let numberedChapters = chapters.enumerated().filter { index, chapter in
                !(index == 0 && (chapter.title == "前言" || chapter.title == "正文"))
            }
            guard !numberedChapters.isEmpty else { return false }
            let numbered = numberedChapters.compactMap { index, chapter -> (index: Int, number: Int)? in
                guard let number = numberedTitleNumber(chapter.title) else { return nil }
                return (index, number)
            }
            guard numbered.count == numberedChapters.count, numbered.count >= 2 else { return true }

            var accepted = Set<Int>()
            for (first, second) in zip(numbered, numbered.dropFirst()) {
                let bodyLength = chapters[first.index].content
                    .trimmingCharacters(in: .whitespacesAndNewlines).count
                guard second.number == first.number + 1, bodyLength >= 50 else { continue }
                accepted.insert(first.index)
                accepted.insert(second.index)
            }
            return accepted.count != numbered.count
        }
        return chapters.enumerated().contains { index, chapter in
            if index == 0 && chapter.title == "前言" { return false }
            return !isExplicitTitle(chapter.title)
        }
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
    case fileTooLarge(actualSize: Int64, maximumSize: Int64)
    
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
        case .fileTooLarge(let size, let maximumSize):
            let sizeMB = size / 1024 / 1024
            let maximumSizeMB = maximumSize / 1024 / 1024
            return "文件过大（\(sizeMB)MB），暂不支持超过 \(maximumSizeMB)MB 的文件"
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
