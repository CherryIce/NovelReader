import Foundation
import Combine
import OSLog

protocol BookChapterParsing {
    func parseChapters(fileURL: URL) throws -> [Chapter]
}

/// 根据文件扩展名选择对应解析器，供旧数据缺少章节记录时重建章节。
final class FormatAwareBookParser: BookChapterParsing {
    private let txtParser = TXTParser()
    private let epubParser = EPUBParser()
    private let pdfParser = PDFParser()

    func parseChapters(fileURL: URL) throws -> [Chapter] {
        let parsedBook: ParsedBook
        switch fileURL.pathExtension.lowercased() {
        case "epub":
            parsedBook = try epubParser.parse(fileURL: fileURL)
        case "pdf":
            parsedBook = try pdfParser.parse(fileURL: fileURL)
        default:
            parsedBook = try txtParser.parse(fileURL: fileURL)
        }

        return parsedBook.chapters.map { parsedChapter in
            Chapter(
                index: parsedChapter.index,
                title: parsedChapter.title,
                content: parsedChapter.content,
                startLocation: parsedChapter.startLocation,
                length: parsedChapter.length
            )
        }
    }
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
    private let txtParser = TXTParser()
    private let logger = Logger(subsystem: "com.freedom.Configures.BookReader", category: "TXTChapterRepair")
    
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
            .flatMap { [chapterRepository, parser, parsingQueue, txtParser, logger] book, chapters -> AnyPublisher<(Book, [Chapter]), Error> in
                let needsRepair = book.format == .txt && txtParser.needsLegacyRepair(chapters)
                guard chapters.isEmpty || needsRepair else {
                    return Just((book, chapters))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }

                // 仓库读取时可能已将旧容器路径修正，调用方传入的 URL 仍是打开前的快照。
                let sourceURL = FileManager.default.fileExists(atPath: book.filePath)
                    ? URL(fileURLWithPath: book.filePath)
                    : fileURL

                return Deferred {
                    Future<[Chapter], Error> { promise in
                        parsingQueue.async {
                            do {
                                promise(.success(try parser.parseChapters(fileURL: sourceURL)))
                            } catch {
                                promise(.failure(error))
                            }
                        }
                    }
                }
                .flatMap { parsedChapters -> AnyPublisher<(Book, [Chapter]), Error> in
                    if needsRepair {
                        return chapterRepository.rebuildChaptersPreservingPositions(
                            parsedChapters,
                            forBookId: book.id
                        )
                        .map { updatedBook in
                            PageCacheManager.shared.clearCache(for: book.id)
                            return (updatedBook, parsedChapters)
                        }
                        .eraseToAnyPublisher()
                    }
                    return chapterRepository.saveChapters(parsedChapters, forBookId: book.id)
                        .map { (book, parsedChapters) }
                        .eraseToAnyPublisher()
                }
                .catch { error -> AnyPublisher<(Book, [Chapter]), Error> in
                    guard needsRepair else {
                        return Fail(error: error).eraseToAnyPublisher()
                    }
                    logger.error("TXT chapter repair failed: \(error.localizedDescription, privacy: .public)")
                    return Just((book, chapters))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
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
