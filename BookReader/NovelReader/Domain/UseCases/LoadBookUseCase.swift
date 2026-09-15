import Foundation
import Combine

protocol BookChapterParsing {
    func parseChapters(fileURL: URL) throws -> [Chapter]
}

/// 加载书籍用例
protocol LoadBookUseCaseProtocol {
    func execute(bookId: UUID, fileURL: URL) -> AnyPublisher<(Book, [Chapter]), Error>
}

class LoadBookUseCase: LoadBookUseCaseProtocol {
    private let bookRepository: BookRepositoryProtocol
    private let chapterRepository: ChapterRepositoryProtocol
    private let parser: BookChapterParsing
    private let parsingQueue: DispatchQueue
    
    init(
        bookRepository: BookRepositoryProtocol,
        chapterRepository: ChapterRepositoryProtocol,
        parser: BookChapterParsing,
        parsingQueue: DispatchQueue = DispatchQueue(
            label: "com.freedom.Configures.BookReader.chapterParsing",
            qos: .userInitiated
        )
    ) {
        self.bookRepository = bookRepository
        self.chapterRepository = chapterRepository
        self.parser = parser
        self.parsingQueue = parsingQueue
    }
    
    func execute(bookId: UUID, fileURL: URL) -> AnyPublisher<(Book, [Chapter]), Error> {
        let bookPublisher = bookRepository.getBook(byId: bookId)
        let chaptersPublisher = chapterRepository.getChapters(forBookId: bookId)
        
        return Publishers.Zip(bookPublisher, chaptersPublisher)
            .tryMap { book, chapters -> (Book, [Chapter]) in
                guard let book = book else {
                    throw BookError.notFound
                }
                return (book, chapters)
            }
            .flatMap { [chapterRepository, parser, parsingQueue] book, chapters -> AnyPublisher<(Book, [Chapter]), Error> in
                guard chapters.isEmpty else {
                    return Just((book, chapters))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }

                return Deferred {
                    Future<[Chapter], Error> { promise in
                        parsingQueue.async {
                            do {
                                promise(.success(try parser.parseChapters(fileURL: fileURL)))
                            } catch {
                                promise(.failure(error))
                            }
                        }
                    }
                }
                .flatMap { parsedChapters in
                    chapterRepository.saveChapters(parsedChapters, forBookId: book.id)
                        .map { (book, parsedChapters) }
                }
                .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}

enum BookError: LocalizedError, Identifiable {
    case notFound
    case parseFailed
    case fileNotAccessible
    case bookAlreadyExists
    case operationFailed(message: String)

    var id: String {
        switch self {
        case .notFound: return "notFound"
        case .parseFailed: return "parseFailed"
        case .fileNotAccessible: return "fileNotAccessible"
        case .bookAlreadyExists: return "bookAlreadyExists"
        case .operationFailed: return "operationFailed"
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .notFound:
            return "书籍不存在"
        case .parseFailed:
            return "解析失败"
        case .fileNotAccessible:
            return "文件无法访问"
        case .bookAlreadyExists:
            return "该书籍已导入"
        case .operationFailed(let message):
            return message
        }
    }
}
