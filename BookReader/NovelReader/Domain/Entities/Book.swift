import Foundation

/// 书籍格式类型
enum BookFormat: String, Codable, CaseIterable {
    case txt
    case epub
    case pdf
}

/// 书籍实体
struct Book: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var author: String?
    var coverImagePath: String?
    var filePath: String
    var format: BookFormat
    var fileSize: Int64
    var createdAt: Date
    var updatedAt: Date
    
    // 阅读进度
    var lastReadChapterIndex: Int
    var lastReadContentOffset: Int // 章节内容中的字符偏移量（精确位置）
    var lastReadAt: Date?
    
    // 阅读设置
    var isFavorite: Bool
    var readingStatus: ReadingStatus
    
    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        coverImagePath: String? = nil,
        filePath: String,
        format: BookFormat,
        fileSize: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastReadChapterIndex: Int = 0,
        lastReadContentOffset: Int = 0,
        lastReadAt: Date? = nil,
        isFavorite: Bool = false,
        readingStatus: ReadingStatus = .unread
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverImagePath = coverImagePath
        self.filePath = filePath
        self.format = format
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReadChapterIndex = lastReadChapterIndex
        self.lastReadContentOffset = lastReadContentOffset
        self.lastReadAt = lastReadAt
        self.isFavorite = isFavorite
        self.readingStatus = readingStatus
    }
    
    /// 计算全局阅读进度
    var globalProgress: Double {
        // 需要在有章节信息时计算
        return 0
    }
}

/// 阅读状态
enum ReadingStatus: String, Codable, CaseIterable {
    case unread
    case reading
    case completed
}

extension Book {
    /// 示例书籍
    static var sample: Book {
        Book(
            title: "示例书籍",
            author: "示例作者",
            filePath: "/path/to/book.txt",
            format: .txt
        )
    }
}
