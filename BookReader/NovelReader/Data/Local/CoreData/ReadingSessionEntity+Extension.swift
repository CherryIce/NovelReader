import Foundation
import CoreData

extension ReadingSessionEntity {
    /// 转换为领域模型
    func toReadingSession() -> ReadingSession {
        ReadingSession(
            id: id ?? UUID(),
            bookId: bookId ?? UUID(),
            bookTitle: bookTitle ?? "",
            startTime: startTime ?? Date(),
            endTime: endTime ?? Date(),
            pagesRead: Int(pagesRead)
        )
    }
    
    /// 从领域模型更新
    func fromReadingSession(_ session: ReadingSession) {
        id = session.id
        bookId = session.bookId
        bookTitle = session.bookTitle
        startTime = session.startTime
        endTime = session.endTime
        duration = session.duration
        pagesRead = Int32(session.pagesRead)
    }
}
