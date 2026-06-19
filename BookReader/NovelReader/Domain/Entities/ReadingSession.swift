import Foundation

/// 阅读会话记录（单次连续阅读）
struct ReadingSession: Identifiable, Codable {
    let id: UUID
    let bookId: UUID
    let bookTitle: String
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    let pagesRead: Int
    
    init(
        id: UUID = UUID(),
        bookId: UUID,
        bookTitle: String,
        startTime: Date,
        endTime: Date,
        pagesRead: Int = 0
    ) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.startTime = startTime
        self.endTime = endTime
        self.duration = endTime.timeIntervalSince(startTime)
        self.pagesRead = pagesRead
    }
}

/// 书籍阅读统计
struct BookReadingStats: Identifiable, Codable {
    let id: UUID
    let bookId: UUID
    let bookTitle: String
    let totalReadingTime: TimeInterval
    let lastReadAt: Date?
    let sessionsCount: Int
    
    init(
        id: UUID = UUID(),
        bookId: UUID,
        bookTitle: String,
        totalReadingTime: TimeInterval,
        lastReadAt: Date? = nil,
        sessionsCount: Int = 0
    ) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.totalReadingTime = totalReadingTime
        self.lastReadAt = lastReadAt
        self.sessionsCount = sessionsCount
    }
}

/// 阅读统计摘要
struct ReadingStatsSummary: Codable {
    let totalReadingTime: TimeInterval
    let todayReadingTime: TimeInterval
    let totalBooksRead: Int
    let totalSessions: Int
    let streakDays: Int
    
    init(
        totalReadingTime: TimeInterval = 0,
        todayReadingTime: TimeInterval = 0,
        totalBooksRead: Int = 0,
        totalSessions: Int = 0,
        streakDays: Int = 0
    ) {
        self.totalReadingTime = totalReadingTime
        self.todayReadingTime = todayReadingTime
        self.totalBooksRead = totalBooksRead
        self.totalSessions = totalSessions
        self.streakDays = streakDays
    }
}

// MARK: - 时间格式化扩展

extension TimeInterval {
    /// 格式化为阅读时长显示字符串（如：2小时30分钟）
    var readingTimeString: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        
        if hours > 0 {
            return "\(hours)小时\(minutes)分钟"
        } else if minutes > 0 {
            return "\(minutes)分钟"
        } else {
            return "少于1分钟"
        }
    }
    
    /// 格式化为简短时长字符串（如：2h 30m）
    var shortReadingTimeString: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
