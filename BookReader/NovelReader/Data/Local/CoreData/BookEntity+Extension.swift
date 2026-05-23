import Foundation
import CoreData

extension BookEntity {
    /// 转换为领域模型
    func toBook() -> Book {
        Book(
            id: id ?? UUID(),
            title: title ?? "",
            author: author,
            coverImagePath: coverImagePath,
            filePath: filePath ?? "",
            format: BookFormat(rawValue: format ?? "txt") ?? .txt,
            fileSize: fileSize,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date(),
            lastReadChapterIndex: Int(lastReadChapterIndex),
            lastReadContentOffset: Int(lastReadContentOffset),
            lastReadAt: lastReadAt,
            isFavorite: isFavorite,
            readingStatus: ReadingStatus(rawValue: readingStatus ?? "unread") ?? .unread
        )
    }
    
    /// 从领域模型更新
    func fromBook(_ book: Book) {
        id = book.id
        title = book.title
        author = book.author
        coverImagePath = book.coverImagePath
        filePath = book.filePath
        format = book.format.rawValue
        fileSize = book.fileSize
        createdAt = book.createdAt
        updatedAt = book.updatedAt
        lastReadChapterIndex = Int32(book.lastReadChapterIndex)
        lastReadContentOffset = Int32(book.lastReadContentOffset)
        lastReadAt = book.lastReadAt
        isFavorite = book.isFavorite
        readingStatus = book.readingStatus.rawValue
    }
}
