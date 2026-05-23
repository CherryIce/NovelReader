import Foundation
import CoreData
import Combine

class ChapterRepository: ChapterRepositoryProtocol {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }
    
    func getChapters(forBookId bookId: UUID) -> AnyPublisher<[Chapter], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ChapterEntity> = ChapterEntity.fetchRequest()
                request.predicate = NSPredicate(format: "book.id == %@", bookId as CVarArg)
                request.sortDescriptors = [NSSortDescriptor(key: "index", ascending: true)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let chapters = entities.map { $0.toChapter() }
                    promise(.success(chapters))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getChapter(bookId: UUID, index: Int) -> AnyPublisher<Chapter?, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<ChapterEntity> = ChapterEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "book.id == %@ AND index == %d",
                    bookId as CVarArg,
                    index
                )
                request.fetchLimit = 1
                
                do {
                    let entity = try self.context.fetch(request).first
                    promise(.success(entity?.toChapter()))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func saveChapters(_ chapters: [Chapter], forBookId: UUID) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                // 先获取书籍实体
                let bookRequest: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                bookRequest.predicate = NSPredicate(format: "id == %@", forBookId as CVarArg)
                
                do {
                    guard let bookEntity = try self.context.fetch(bookRequest).first else {
                        promise(.failure(BookError.notFound))
                        return
                    }
                    
                    // 删除旧章节
                    let oldChapters = bookEntity.chapters?.allObjects as? [ChapterEntity] ?? []
                    oldChapters.forEach { self.context.delete($0) }
                    
                    // 创建新章节
                    for chapter in chapters {
                        let entity = ChapterEntity(context: self.context)
                        entity.fromChapter(chapter, book: bookEntity)
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
    
    func deleteChapters(forBookId bookId: UUID) -> AnyPublisher<Void, Error> {
        Future { [bookId] promise in
            self.context.perform {
                let request: NSFetchRequest<ChapterEntity> = ChapterEntity.fetchRequest()
                request.predicate = NSPredicate(format: "book.id == %@", bookId as CVarArg)
                
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
    
    func getChapterContent(bookId: UUID, index: Int) -> AnyPublisher<String, Error> {
        getChapter(bookId: bookId, index: index)
            .map { $0?.content ?? "" }
            .eraseToAnyPublisher()
    }
}
