import Combine
import Foundation

struct BookNoteSummary: Identifiable, Equatable {
    let book: Book
    let annotations: [ReaderAnnotationGroup]

    var id: UUID { book.id }
    var updatedAt: Date { annotations.map(\.updatedAt).max() ?? .distantPast }
}

final class NotesViewModel: ObservableObject {
    @Published private(set) var summaries: [BookNoteSummary] = []
    @Published private(set) var isLoading = false
    @Published var searchText = ""
    @Published var errorMessage: String?

    private let bookRepository: BookRepositoryProtocol
    private let bookmarkRepository: BookmarkRepositoryProtocol
    private var loadCancellable: AnyCancellable?

    init(
        bookRepository: BookRepositoryProtocol = BookRepository(),
        bookmarkRepository: BookmarkRepositoryProtocol = BookmarkRepository()
    ) {
        self.bookRepository = bookRepository
        self.bookmarkRepository = bookmarkRepository
    }

    var filteredSummaries: [BookNoteSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { summary in
            summary.book.title.localizedCaseInsensitiveContains(query)
                || (summary.book.author?.localizedCaseInsensitiveContains(query) ?? false)
                || summary.annotations.contains { annotation in
                    annotation.selectedText.localizedCaseInsensitiveContains(query)
                        || annotation.thoughts.contains {
                            $0.note?.localizedCaseInsensitiveContains(query) ?? false
                        }
                }
        }
    }

    var totalAnnotationCount: Int {
        summaries.reduce(0) { $0 + $1.annotations.count }
    }

    func loadNotes() {
        isLoading = true
        errorMessage = nil
        loadCancellable?.cancel()
        loadCancellable = Publishers.Zip(
            bookRepository.getAllBooks(),
            bookmarkRepository.getAllAnnotations()
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { [weak self] completion in
                guard let self else { return }
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            },
            receiveValue: { [weak self] books, bookmarks in
                guard let self else { return }
                let bookmarksByBook = Dictionary(grouping: bookmarks, by: \.bookId)
                self.summaries = books.compactMap { book in
                    let groups = ReaderAnnotationGroup.groups(
                        from: bookmarksByBook[book.id] ?? []
                    )
                    return groups.isEmpty ? nil : BookNoteSummary(book: book, annotations: groups)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                self.isLoading = false
            }
        )
    }
}

final class BookNotesViewModel: ObservableObject {
    @Published private(set) var annotations: [ReaderAnnotationGroup] = []
    @Published private(set) var chapterTitles: [Int: String] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let book: Book
    private let bookmarkRepository: BookmarkRepositoryProtocol
    private let chapterRepository: ChapterRepositoryProtocol
    private var loadCancellable: AnyCancellable?

    init(
        book: Book,
        bookmarkRepository: BookmarkRepositoryProtocol = BookmarkRepository(),
        chapterRepository: ChapterRepositoryProtocol = ChapterRepository()
    ) {
        self.book = book
        self.bookmarkRepository = bookmarkRepository
        self.chapterRepository = chapterRepository
    }

    func loadNotes() {
        isLoading = true
        errorMessage = nil
        loadCancellable?.cancel()
        loadCancellable = Publishers.Zip(
            bookmarkRepository.getBookmarks(forBookId: book.id),
            chapterRepository.getChapters(forBookId: book.id)
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { [weak self] completion in
                guard let self else { return }
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            },
            receiveValue: { [weak self] bookmarks, chapters in
                guard let self else { return }
                self.annotations = ReaderAnnotationGroup.groups(from: bookmarks)
                self.chapterTitles = chapters.reduce(into: [:]) { result, chapter in
                    result[chapter.index] = chapter.title
                }
                self.isLoading = false
            }
        )
    }

    func chapterTitle(for index: Int) -> String {
        chapterTitles[index] ?? "第 \(index + 1) 章"
    }
}
