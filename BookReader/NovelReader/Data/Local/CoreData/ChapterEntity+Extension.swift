import Foundation
import CoreData

extension ChapterEntity {
    /// 转换为领域模型
    func toChapter() -> Chapter {
        Chapter(
            id: id ?? UUID(),
            index: Int(index),
            title: title ?? "",
            content: content ?? "",
            startLocation: Int(startLocation),
            length: Int(length)
        )
    }
    
    /// 从领域模型更新
    func fromChapter(_ chapter: Chapter, book: BookEntity) {
        id = chapter.id
        index = Int32(chapter.index)
        title = chapter.title
        content = chapter.content
        startLocation = Int32(chapter.startLocation)
        length = Int32(chapter.length)
        self.book = book
    }
}
