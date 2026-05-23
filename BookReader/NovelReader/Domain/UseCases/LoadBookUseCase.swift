import Foundation
import Combine

/// 加载书籍用例
protocol LoadBookUseCaseProtocol {
    func execute(bookId: UUID) -> AnyPublisher<(Book, [Chapter]), Error>
}

class LoadBookUseCase: LoadBookUseCaseProtocol {
    private let bookRepository: BookRepositoryProtocol
    private let chapterRepository: ChapterRepositoryProtocol
    
    init(
        bookRepository: BookRepositoryProtocol,
        chapterRepository: ChapterRepositoryProtocol
    ) {
        self.bookRepository = bookRepository
        self.chapterRepository = chapterRepository
    }
    
    func execute(bookId: UUID) -> AnyPublisher<(Book, [Chapter]), Error> {
        let bookPublisher = bookRepository.getBook(byId: bookId)
        let chaptersPublisher = chapterRepository.getChapters(forBookId: bookId)
        
        return Publishers.Zip(bookPublisher, chaptersPublisher)
            .tryMap { book, chapters in
                guard let book = book else {
                    throw BookError.notFound
                }
                return (book, chapters)
            }
            .eraseToAnyPublisher()
    }
}

enum BookError: LocalizedError, Identifiable {
    case notFound
    case parseFailed
    case fileNotAccessible
    case bookAlreadyExists

    var id: String {
        switch self {
        case .notFound: return "notFound"
        case .parseFailed: return "parseFailed"
        case .fileNotAccessible: return "fileNotAccessible"
        case .bookAlreadyExists: return "bookAlreadyExists"
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
        }
    }
}
