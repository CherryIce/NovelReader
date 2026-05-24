import Foundation
import Combine

/// 保存阅读进度用例
protocol SaveProgressUseCaseProtocol {
    func execute(
        bookId: UUID,
        chapterIndex: Int,
        contentOffset: Int,
        readingStatus: ReadingStatus
    ) -> AnyPublisher<Void, Error>
}

class SaveProgressUseCase: SaveProgressUseCaseProtocol {
    private let bookRepository: BookRepositoryProtocol
    
    init(bookRepository: BookRepositoryProtocol) {
        self.bookRepository = bookRepository
    }
    
    func execute(
        bookId: UUID,
        chapterIndex: Int,
        contentOffset: Int,
        readingStatus: ReadingStatus
    ) -> AnyPublisher<Void, Error> {
        return bookRepository.updateReadingProgress(
            bookId: bookId,
            chapterIndex: chapterIndex,
            contentOffset: contentOffset,
            readingStatus: readingStatus
        )
    }
}
