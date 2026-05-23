import Foundation

/// 书签类型
enum BookmarkType: String, Codable, CaseIterable {
    case bookmark // 普通书签
    case note // 笔记
    case highlight // 高亮
}

/// 书签实体
struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    let bookId: UUID
    var chapterIndex: Int
    var location: Int // 在章节中的位置
    var length: Int // 选中的文本长度（高亮/笔记）
    var type: BookmarkType
    var note: String? // 笔记内容
    var selectedText: String? // 选中的原文
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        bookId: UUID,
        chapterIndex: Int,
        location: Int,
        length: Int = 0,
        type: BookmarkType = .bookmark,
        note: String? = nil,
        selectedText: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterIndex = chapterIndex
        self.location = location
        self.length = length
        self.type = type
        self.note = note
        self.selectedText = selectedText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Bookmark {
    /// 示例书签
    static var sample: Bookmark {
        Bookmark(
            bookId: UUID(),
            chapterIndex: 0,
            location: 100,
            type: .bookmark
        )
    }
}
