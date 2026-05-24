import Foundation
import CoreData
import Combine

class BookRepository: BookRepositoryProtocol {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }
    
    func getAllBooks() -> AnyPublisher<[Book], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                // 确保从持久化存储重新获取最新数据，避免返回已删除的缓存对象
                request.returnsObjectsAsFaults = false
                request.includesPropertyValues = true
                
                do {
                    let entities = try self.context.fetch(request)
                    let books = entities.map { $0.toBook() }
                    promise(.success(books))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getBook(byId id: UUID) -> AnyPublisher<Book?, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                request.fetchLimit = 1
                
                do {
                    let entity = try self.context.fetch(request).first
                    promise(.success(entity?.toBook()))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func addBook(_ book: Book) -> AnyPublisher<Book, Error> {
        Future { promise in
            self.context.perform {
                let entity = BookEntity(context: self.context)
                entity.fromBook(book)
                
                do {
                    try self.context.save()
                    promise(.success(book))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func updateBook(_ book: Book) -> AnyPublisher<Book, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", book.id as CVarArg)
                
                do {
                    if let entity = try self.context.fetch(request).first {
                        entity.fromBook(book)
                        try self.context.save()
                        promise(.success(book))
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
    
    func deleteBook(byId id: UUID) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                
                do {
                    if let entity = try self.context.fetch(request).first {
                        self.context.delete(entity)
                        try self.context.save()
                        // 重置 context 以清除所有缓存，确保后续查询拿到最新数据
                        self.context.reset()
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
    
    func searchBooks(query: String) -> AnyPublisher<[Book], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "title CONTAINS[c] %@ OR author CONTAINS[c] %@",
                    query, query
                )
                
                do {
                    let entities = try self.context.fetch(request)
                    let books = entities.map { $0.toBook() }
                    promise(.success(books))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getFavoriteBooks() -> AnyPublisher<[Book], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "isFavorite == YES")
                request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
                
                do {
                    let entities = try self.context.fetch(request)
                    let books = entities.map { $0.toBook() }
                    promise(.success(books))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func getRecentlyReadBooks(limit: Int) -> AnyPublisher<[Book], Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "lastReadAt != nil")
                request.sortDescriptors = [NSSortDescriptor(key: "lastReadAt", ascending: false)]
                request.fetchLimit = limit
                
                do {
                    let entities = try self.context.fetch(request)
                    let books = entities.map { $0.toBook() }
                    promise(.success(books))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func updateReadingProgress(
        bookId: UUID,
        chapterIndex: Int,
        contentOffset: Int,
        readingStatus: ReadingStatus
    ) -> AnyPublisher<Void, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", bookId as CVarArg)
                
                do {
                    if let entity = try self.context.fetch(request).first {
                        entity.lastReadChapterIndex = Int32(chapterIndex)
                        entity.lastReadContentOffset = Int32(contentOffset)
                        entity.lastReadAt = Date()
                        entity.readingStatus = readingStatus.rawValue
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
    
    func toggleFavorite(bookId: UUID) -> AnyPublisher<Bool, Error> {
        Future { promise in
            self.context.perform {
                let request: NSFetchRequest<BookEntity> = BookEntity.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", bookId as CVarArg)
                
                do {
                    if let entity = try self.context.fetch(request).first {
                        entity.isFavorite.toggle()
                        try self.context.save()
                        promise(.success(entity.isFavorite))
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
}
