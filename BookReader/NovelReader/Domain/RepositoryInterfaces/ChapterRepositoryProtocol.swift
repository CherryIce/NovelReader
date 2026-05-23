import Foundation
import Combine

/// 章节仓库协议
protocol ChapterRepositoryProtocol {
    /// 获取书籍的所有章节
    func getChapters(forBookId bookId: UUID) -> AnyPublisher<[Chapter], Error>
    
    /// 获取特定章节
    func getChapter(bookId: UUID, index: Int) -> AnyPublisher<Chapter?, Error>
    
    /// 保存章节（批量）
    func saveChapters(_ chapters: [Chapter], forBookId: UUID) -> AnyPublisher<Void, Error>
    
    /// 删除书籍的所有章节
    func deleteChapters(forBookId: UUID) -> AnyPublisher<Void, Error>
    
    /// 获取章节内容
    func getChapterContent(bookId: UUID, index: Int) -> AnyPublisher<String, Error>
}
