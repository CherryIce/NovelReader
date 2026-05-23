import Foundation
import Combine

/// 书籍仓库协议
protocol BookRepositoryProtocol {
    /// 获取所有书籍
    func getAllBooks() -> AnyPublisher<[Book], Error>
    
    /// 根据ID获取书籍
    func getBook(byId id: UUID) -> AnyPublisher<Book?, Error>
    
    /// 添加书籍
    func addBook(_ book: Book) -> AnyPublisher<Book, Error>
    
    /// 更新书籍
    func updateBook(_ book: Book) -> AnyPublisher<Book, Error>
    
    /// 删除书籍
    func deleteBook(byId id: UUID) -> AnyPublisher<Void, Error>
    
    /// 搜索书籍
    func searchBooks(query: String) -> AnyPublisher<[Book], Error>
    
    /// 获取收藏的书籍
    func getFavoriteBooks() -> AnyPublisher<[Book], Error>
    
    /// 获取最近阅读的书籍
    func getRecentlyReadBooks(limit: Int) -> AnyPublisher<[Book], Error>
    
    /// 更新阅读进度
    func updateReadingProgress(
        bookId: UUID,
        chapterIndex: Int,
        contentOffset: Int
    ) -> AnyPublisher<Void, Error>
    
    /// 切换收藏状态
    func toggleFavorite(bookId: UUID) -> AnyPublisher<Bool, Error>
}
