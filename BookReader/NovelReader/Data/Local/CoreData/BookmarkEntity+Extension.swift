import Foundation
import CoreData

extension BookmarkEntity {
    /// 转换为领域模型
    func toBookmark() -> Bookmark {
        Bookmark(
            id: id ?? UUID(),
            bookId: book?.id ?? UUID(),
            chapterIndex: Int(chapterIndex),
            location: Int(location),
            length: Int(length),
            type: BookmarkType(rawValue: type ?? "bookmark") ?? .bookmark,
            note: note,
            selectedText: selectedText,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }
    
    /// 从领域模型更新
    func fromBookmark(_ bookmark: Bookmark, book: BookEntity) {
        id = bookmark.id
        chapterIndex = Int32(bookmark.chapterIndex)
        location = Int32(bookmark.location)
        length = Int32(bookmark.length)
        type = bookmark.type.rawValue
        note = bookmark.note
        selectedText = bookmark.selectedText
        createdAt = bookmark.createdAt
        updatedAt = bookmark.updatedAt
        self.book = book
    }
}
