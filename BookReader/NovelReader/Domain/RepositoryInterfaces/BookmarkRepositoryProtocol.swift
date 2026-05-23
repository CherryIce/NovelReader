import Foundation
import Combine

/// 书签仓库协议
protocol BookmarkRepositoryProtocol {
    /// 获取书籍的所有书签
    func getBookmarks(forBookId bookId: UUID) -> AnyPublisher<[Bookmark], Error>
    
    /// 获取特定类型的书签
    func getBookmarks(forBookId bookId: UUID, type: BookmarkType) -> AnyPublisher<[Bookmark], Error>
    
    /// 添加书签
    func addBookmark(_ bookmark: Bookmark) -> AnyPublisher<Bookmark, Error>
    
    /// 更新书签
    func updateBookmark(_ bookmark: Bookmark) -> AnyPublisher<Bookmark, Error>
    
    /// 删除书签
    func deleteBookmark(byId id: UUID) -> AnyPublisher<Void, Error>
    
    /// 删除书籍的所有书签
    func deleteBookmarks(forBookId: UUID) -> AnyPublisher<Void, Error>
    
    /// 检查位置是否有书签
    func hasBookmark(bookId: UUID, chapterIndex: Int, location: Int) -> AnyPublisher<Bookmark?, Error>
}
