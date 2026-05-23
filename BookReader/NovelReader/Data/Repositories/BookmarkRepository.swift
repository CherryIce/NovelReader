import Foundation
import CoreData
import Combine

class BookmarkRepository: BookmarkRepositoryProtocol {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }
    
    func getBookmarks(forBookId bookId: UUID) -> AnyPublisher<[Bookmark], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookmarkEntity> = BookmarkEntity.fetchRequest()
                request.predicate = NSPredicate(format: "book.id == %@", bookId as CVarArg)
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let bookmarks = entities.map { $0.toBookmark() }
                    promise(.success(bookmarks))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getBookmarks(forBookId bookId: UUID, type: BookmarkType) -> AnyPublisher<[Bookmark], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookmarkEntity> = BookmarkEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "book.id == %@ AND type == %@",
                    bookId as CVarArg,
                    type.rawValue
                )
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let bookmarks = entities.map { $0.toBookmark() }
                    promise(.success(bookmarks))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func addBookmark(_ bookmark: Bookmark) -> AnyPublisher<Bookmark, Error> {
        Future { promise in
            self.context.perform {
                // 获取书籍实体
                let bookRequest: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                bookRequest.predicate = NSPredicate(format: "id == %@", bookmark.bookId as CVarArg)
                
                do {
                    guard let bookEntity = try self.context.fetch(bookRequest).first else {
                        promise(.failure(BookError.notFound))
                        return
                    }
                    
                    let entity = BookmarkEntity(context: self.context)
                    entity.fromBookmark(bookmark, book: bookEntity)
                    
                    try self.context.save()
                    promise(.success(bookmark))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func updateBookmark(_ bookmark: Bookmark) -> AnyPublisher<Bookmark, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookmarkEntity> = BookmarkEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", bookmark.id as CVarArg)
                
                do {
                    if let entity = try self.context.fetch(request).first {
                        // 获取书籍实体
                        let bookRequest: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                        bookRequest.predicate = NSPredicate(format: "id == %@", bookmark.bookId as CVarArg)
                        
                        if let bookEntity = try self.context.fetch(bookRequest).first {
                            entity.fromBookmark(bookmark, book: bookEntity)
                            try self.context.save()
                            promise(.success(bookmark))
                        } else {
                            promise(.failure(BookError.notFound))
                        }
                    } else {
                        promise(.failure(BookError.notFound))
                    }
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func deleteBookmark(byId id: UUID) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookmarkEntity> = BookmarkEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                
                do {
                    if let entity = try self.context.fetch(request).first {
                        self.context.delete(entity)
                        try self.context.save()
                        promise(.success(()))
                    } else {
                        promise(.failure(BookError.notFound))
                    }
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func deleteBookmarks(forBookId bookId: UUID) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookmarkEntity> = BookmarkEntity.fetchRequest()
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
    
    func hasBookmark(bookId: UUID, chapterIndex: Int, location: Int) -> AnyPublisher<Bookmark?, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookmarkEntity> = BookmarkEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "book.id == %@ AND chapterIndex == %d AND location == %d",
                    bookId as CVarArg,
                    chapterIndex,
                    location
                )
                request.fetchLimit = 1
                
                do {
                    let entity = try self.context.fetch(request).first
                    promise(.success(entity?.toBookmark()))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
}
