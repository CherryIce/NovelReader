import Foundation
import CoreData
import Combine

class ReadingStatsRepository: ReadingStatsRepositoryProtocol {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }
    
    func saveReadingSession(_ session: ReadingSession) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                let entity = ReadingSessionEntity(context: self.context)
                entity.fromReadingSession(session)
                
                // 关联到书籍
                let bookRequest: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                bookRequest.predicate = NSPredicate(format: "id == %@", session.bookId as CVarArg)
                
                do {
                    if let book = try self.context.fetch(bookRequest).first {
                        entity.book = book
                    }
                    try self.context.save()
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getAllSessions() -> AnyPublisher<[ReadingSession], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "startTime", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let sessions = entities.map { $0.toReadingSession() }
                    promise(.success(sessions))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getSessions(forBookId bookId: UUID) -> AnyPublisher<[ReadingSession], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.predicate = NSPredicate(format: "bookId == %@", bookId as CVarArg)
                request.sortDescriptors = [NSSortDescriptor(key: "startTime", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let sessions = entities.map { $0.toReadingSession() }
                    promise(.success(sessions))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getTodaySessions() -> AnyPublisher<[ReadingSession], Error> {
        Future { promise in
            self.context.perform {
                let calendar = Calendar.current
                let startOfDay = calendar.startOfDay(for: Date())
                let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
                
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "startTime >= %@ AND startTime < %@",
                    startOfDay as NSDate,
                    endOfDay as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "startTime", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let sessions = entities.map { $0.toReadingSession() }
                    promise(.success(sessions))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getSessions(from startDate: Date, to endDate: Date) -> AnyPublisher<[ReadingSession], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "startTime >= %@ AND startTime < %@",
                    startDate as NSDate,
                    endDate as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "startTime", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let sessions = entities.map { $0.toReadingSession() }
                    promise(.success(sessions))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getAllBookStats() -> AnyPublisher<[BookReadingStats], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "startTime", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    
                    // 按书籍分组统计
                    var statsByBook: [UUID: BookReadingStats] = [:]
                    
                    for entity in entities {
                        let bookId = entity.bookId ?? UUID()
                        let bookTitle = entity.bookTitle ?? ""
                        let duration = entity.duration
                        let endTime = entity.endTime
                        
                        if var existingStats = statsByBook[bookId] {
                            let newTotalTime = existingStats.totalReadingTime + duration
                            let newSessionsCount = existingStats.sessionsCount + 1
                            let lastReadAt = existingStats.lastReadAt
                            
                            statsByBook[bookId] = BookReadingStats(
                                id: existingStats.id,
                                bookId: bookId,
                                bookTitle: bookTitle,
                                totalReadingTime: newTotalTime,
                                lastReadAt: max(lastReadAt ?? Date.distantPast, endTime ?? Date.distantPast),
                                sessionsCount: newSessionsCount
                            )
                        } else {
                            statsByBook[bookId] = BookReadingStats(
                                bookId: bookId,
                                bookTitle: bookTitle,
                                totalReadingTime: duration,
                                lastReadAt: endTime,
                                sessionsCount: 1
                            )
                        }
                    }
                    
                    let stats = Array(statsByBook.values).sorted { $0.totalReadingTime > $1.totalReadingTime }
                    promise(.success(stats))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getBookStats(forBookId bookId: UUID) -> AnyPublisher<BookReadingStats?, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.predicate = NSPredicate(format: "bookId == %@", bookId as CVarArg)
                request.sortDescriptors = [NSSortDescriptor(key: "startTime", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    guard !entities.isEmpty else {
                        promise(.success(nil))
                        return
                    }
                    
                    let totalTime = entities.reduce(0) { $0 + $1.duration }
                    let bookTitle = entities.first?.bookTitle ?? ""
                    let lastReadAt = entities.first?.endTime
                    
                    let stats = BookReadingStats(
                        bookId: bookId,
                        bookTitle: bookTitle,
                        totalReadingTime: totalTime,
                        lastReadAt: lastReadAt,
                        sessionsCount: entities.count
                    )
                    promise(.success(stats))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getReadingStatsSummary() -> AnyPublisher<ReadingStatsSummary, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                
                do {
                    let entities = try self.context.fetch(request)
                    
                    let totalTime = entities.reduce(0) { $0 + $1.duration }
                    let totalSessions = entities.count
                    
                    // 计算今日阅读时长
                    let calendar = Calendar.current
                    let startOfDay = calendar.startOfDay(for: Date())
                    let todayTime = entities
                        .filter { ($0.startTime ?? Date.distantPast) >= startOfDay }
                        .reduce(0) { $0 + $1.duration }
                    
                    // 获取有阅读记录的唯一书籍数量
                    let uniqueBookIds = Set(entities.compactMap { $0.bookId })
                    
                    // 计算连续阅读天数
                    let streakDays = self.calculateStreakDays(from: entities)
                    
                    let summary = ReadingStatsSummary(
                        totalReadingTime: totalTime,
                        todayReadingTime: todayTime,
                        totalBooksRead: uniqueBookIds.count,
                        totalSessions: totalSessions,
                        streakDays: streakDays
                    )
                    promise(.success(summary))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func deleteSessions(forBookId bookId: UUID) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ReadingSessionEntity> = ReadingSessionEntity.fetchRequest()
                request.predicate = NSPredicate(format: "bookId == %@", bookId as CVarArg)
                
                do {
                    let entities = try self.context.fetch(request)
                    entities.forEach { self.context.delete($0) }
                    try self.context.save()
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    // MARK: - 私有方法
    
    /// 计算连续阅读天数
    private func calculateStreakDays(from entities: [ReadingSessionEntity]) -> Int {
        guard !entities.isEmpty else { return 0 }
        
        let calendar = Calendar.current
        let dates = entities
            .compactMap { $0.startTime }
            .map { calendar.startOfDay(for: $0) }
            .sorted(by: >)
        
        guard let mostRecentDate = dates.first else { return 0 }
        
        // 如果最近阅读不是今天或昨天，连续天数为0
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        
        if mostRecentDate < yesterday {
            return 0
        }
        
        // 计算连续天数
        var streak = 1
        var currentDate = mostRecentDate
        let uniqueDates = Set(dates)
        
        while true {
            let previousDate = calendar.date(byAdding: .day, value: -1, to: currentDate)!
            if uniqueDates.contains(previousDate) {
                streak += 1
                currentDate = previousDate
            } else {
                break
            }
        }
        
        return streak
    }
}
