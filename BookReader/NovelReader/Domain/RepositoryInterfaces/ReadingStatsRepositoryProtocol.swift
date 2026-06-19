import Foundation
import Combine

/// 阅读统计仓库协议
protocol ReadingStatsRepositoryProtocol {
    /// 保存阅读会话
    func saveReadingSession(_ session: ReadingSession) -> AnyPublisher<Void, Error>
    
    /// 获取所有阅读会话
    func getAllSessions() -> AnyPublisher<[ReadingSession], Error>
    
    /// 获取指定书籍的阅读会话
    func getSessions(forBookId bookId: UUID) -> AnyPublisher<[ReadingSession], Error>
    
    /// 获取今日阅读会话
    func getTodaySessions() -> AnyPublisher<[ReadingSession], Error>
    
    /// 获取指定日期范围的阅读会话
    func getSessions(from startDate: Date, to endDate: Date) -> AnyPublisher<[ReadingSession], Error>
    
    /// 获取所有书籍的阅读统计
    func getAllBookStats() -> AnyPublisher<[BookReadingStats], Error>
    
    /// 获取指定书籍的阅读统计
    func getBookStats(forBookId bookId: UUID) -> AnyPublisher<BookReadingStats?, Error>
    
    /// 获取阅读统计摘要
    func getReadingStatsSummary() -> AnyPublisher<ReadingStatsSummary, Error>
    
    /// 删除指定书籍的所有阅读记录
    func deleteSessions(forBookId bookId: UUID) -> AnyPublisher<Void, Error>
}
