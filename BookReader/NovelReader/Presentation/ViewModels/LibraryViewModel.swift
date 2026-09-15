import Foundation
import Combine
import OSLog

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case reading
    case completed
    case favorite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .reading: return "在读"
        case .completed: return "已读完"
        case .favorite: return "收藏"
        }
    }
}

/// 书架视图模型
class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var searchQuery: String = "" {
        didSet {
            performSearch()
        }
    }
    @Published var currentFilter: LibraryFilter = .all {
        didSet {
            performSearch()
        }
    }
    @Published var error: BookError?
    @Published var selectedBook: Book?

    // 导入状态
    @Published var isImporting: Bool = false
    @Published var importProgress: String = ""
    @Published var importSuccess: Bool = false
    @Published var importedBookTitle: String = ""
    @Published var importingBookTitle: String = ""  // 正在导入的书籍名称，用于显示卡片

    // 批量导入状态
    @Published var isBatchImporting: Bool = false
    @Published var batchImportProgress: String = ""
    @Published var batchImportTotal: Int = 0
    @Published var batchImportCurrent: Int = 0
    @Published var batchImportSuccess: Bool = false
    @Published var batchImportSuccessCount: Int = 0
    @Published var batchImportFailCount: Int = 0
    @Published var batchImportFailedTitles: [String] = []

    private let bookRepository: BookRepositoryProtocol
    private let txtParser = TXTParser()
    private let epubParser = EPUBParser()
    private let pdfParser = PDFParser()
    private var cancellables = Set<AnyCancellable>()
    private var booksRequestCancellable: AnyCancellable?
    private var importCheckCancellable: AnyCancellable?
    private var importPersistenceCancellable: AnyCancellable?
    private var pendingBatchImports: [(urls: [URL], removesSourceWhenFinished: Bool)] = []
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.freedom.Configures.BookReader",
        category: "BookImport"
    )

    init(bookRepository: BookRepositoryProtocol = BookRepository()) {
        self.bookRepository = bookRepository
    }

    /// 加载书籍列表
    func loadBooks() {
        let publisher: AnyPublisher<[Book], Error>

        switch currentFilter {
        case .all:
            publisher = bookRepository.getAllBooks()
        case .reading:
            publisher = bookRepository.getRecentlyReadBooks(limit: 50)
        case .completed:
            publisher = bookRepository.getAllBooks()
                .map { $0.filter { $0.readingStatus == .completed } }
                .eraseToAnyPublisher()
        case .favorite:
            publisher = bookRepository.getFavoriteBooks()
        }

        booksRequestCancellable?.cancel()
        booksRequestCancellable = publisher
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = self?.userFacingError(from: error)
                    }
                },
                receiveValue: { [weak self] books in
                    self?.books = books
                }
            )
    }

    /// 搜索书籍
    private func performSearch() {
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            loadBooks()
            return
        }

        booksRequestCancellable?.cancel()
        booksRequestCancellable = bookRepository.searchBooks(query: normalizedQuery)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = self?.userFacingError(from: error)
                    }
                },
                receiveValue: { [weak self] books in
                    self?.books = self?.applyCurrentFilter(to: books) ?? books
                }
            )
    }

    /// 设置筛选条件
    func setFilter(_ filter: LibraryFilter) {
        currentFilter = filter
    }

    /// 选择书籍
    func selectBook(_ book: Book) {
        selectedBook = book
    }

    /// 导入书籍
    func importBook(from url: URL) {
        guard !isImporting, !isBatchImporting else { return }
        guard isSupportedBookURL(url) else {
            error = .parseFailed
            return
        }

        importSuccess = false
        importedBookTitle = ""
        importingBookTitle = url.deletingPathExtension().lastPathComponent
        isImporting = true
        importProgress = "正在检查..."
        logger.notice("Import selected: \(url.lastPathComponent, privacy: .private(mask: .hash))")

        importCheckCancellable = bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard case .failure(let error) = completion else { return }
                    self?.isImporting = false
                    self?.importingBookTitle = ""
                    self?.error = self?.userFacingError(from: error)
                    self?.processNextPendingBatchImportIfNeeded()
                },
                receiveValue: { [weak self] books in
                    guard let self else { return }
                    if self.containsFilename(url.lastPathComponent, in: books) {
                        self.isImporting = false
                        self.importingBookTitle = ""
                        self.error = .bookAlreadyExists
                        self.logger.notice("Import rejected as duplicate: \(url.lastPathComponent, privacy: .private(mask: .hash))")
                        self.processNextPendingBatchImportIfNeeded()
                        return
                    }

                    self.performImport(from: url, removesSourceWhenFinished: false) { [weak self] result in
                        guard let self else { return }

                        switch result {
                        case .success(let book):
                            self.publishImportedBooks([book])
                            self.importSuccess = true
                            self.importedBookTitle = book.title
                            self.logger.notice("Import committed: \(book.title, privacy: .private(mask: .hash))")
                        case .failure(let message):
                            self.error = .operationFailed(message: message)
                            self.logger.error("Import failed: \(message, privacy: .private)")
                        }

                        self.isImporting = false
                        self.importingBookTitle = ""
                        self.importProgress = ""
                        self.processNextPendingBatchImportIfNeeded()
                    }
                }
            )
    }

    /// 批量导入书籍
    func importBooks(from urls: [URL], removesSourceWhenFinished: Bool = false) {
        guard !urls.isEmpty else { return }
        guard !isImporting, !isBatchImporting else {
            pendingBatchImports.append((urls, removesSourceWhenFinished))
            logger.notice("Batch import queued: \(urls.count) files")
            return
        }

        batchImportSuccess = false
        batchImportSuccessCount = 0
        batchImportFailCount = 0
        batchImportFailedTitles = []
        batchImportTotal = urls.count
        batchImportCurrent = 0
        isBatchImporting = true
        batchImportProgress = "正在检查 \(urls.count) 个文件..."
        logger.notice("Batch import selected: \(urls.count) files")

        importCheckCancellable = bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard case .failure(let error) = completion else { return }
                    guard let self else { return }
                    self.isBatchImporting = false
                    self.batchImportProgress = ""
                    self.cleanupSourcesIfNeeded(urls, enabled: removesSourceWhenFinished)
                    self.error = self.userFacingError(from: error)
                    self.processNextPendingBatchImportIfNeeded()
                },
                receiveValue: { [weak self] existingBooks in
                    guard let self else { return }

                    var seenFilenames = Set(existingBooks.map {
                        URL(fileURLWithPath: $0.filePath).lastPathComponent.lowercased()
                    })
                    var urlsToImport: [URL] = []
                    var initialFailures: [String] = []

                    for url in urls {
                        let filename = url.lastPathComponent
                        let key = filename.lowercased()
                        guard self.isSupportedBookURL(url), seenFilenames.insert(key).inserted else {
                            initialFailures.append("\(filename): 格式不支持或书籍已存在")
                            if removesSourceWhenFinished {
                                self.cleanupSource(url)
                            }
                            continue
                        }
                        urlsToImport.append(url)
                    }

                    if urlsToImport.isEmpty {
                        self.finishBatchImport(
                            successCount: 0,
                            failedTitles: initialFailures,
                            importedBooks: []
                        )
                        return
                    }

                    self.batchImportTotal = urlsToImport.count
                    self.batchImportCurrent = 0
                    self.batchImportProgress = "准备导入 \(urlsToImport.count) 个文件..."
                    self.processBatchImport(
                        urls: urlsToImport,
                        index: 0,
                        successCount: 0,
                        failedTitles: initialFailures,
                        importedBooks: [],
                        removesSourceWhenFinished: removesSourceWhenFinished
                    )
                }
            )
    }

    private enum ImportResult {
        case success(Book)
        case failure(String)
    }

    private func processBatchImport(
        urls: [URL],
        index: Int,
        successCount: Int,
        failedTitles: [String],
        importedBooks: [Book],
        removesSourceWhenFinished: Bool
    ) {
        guard index < urls.count else {
            finishBatchImport(
                successCount: successCount,
                failedTitles: failedTitles,
                importedBooks: importedBooks
            )
            return
        }

        let url = urls[index]
        batchImportCurrent = index + 1
        batchImportProgress = "正在导入 (\(index + 1)/\(urls.count)): \(url.deletingPathExtension().lastPathComponent)"
        importingBookTitle = url.deletingPathExtension().lastPathComponent

        performImport(from: url, removesSourceWhenFinished: removesSourceWhenFinished) { [weak self] result in
            guard let self else { return }
            var nextSuccessCount = successCount
            var nextFailedTitles = failedTitles
            var nextImportedBooks = importedBooks
            switch result {
            case .success(let book):
                nextSuccessCount += 1
                nextImportedBooks.append(book)
            case .failure(let message):
                nextFailedTitles.append(message)
            }

            self.processBatchImport(
                urls: urls,
                index: index + 1,
                successCount: nextSuccessCount,
                failedTitles: nextFailedTitles,
                importedBooks: nextImportedBooks,
                removesSourceWhenFinished: removesSourceWhenFinished
            )
        }
    }

    private func finishBatchImport(
        successCount: Int,
        failedTitles: [String],
        importedBooks: [Book]
    ) {
        publishImportedBooks(importedBooks)
        isBatchImporting = false
        batchImportProgress = ""
        importingBookTitle = ""
        batchImportSuccess = true
        batchImportSuccessCount = successCount
        batchImportFailCount = failedTitles.count
        batchImportFailedTitles = failedTitles
        logger.notice("Batch import finished: \(successCount) succeeded, \(failedTitles.count) failed")
        processNextPendingBatchImportIfNeeded()
    }

    private func performImport(
        from url: URL,
        removesSourceWhenFinished: Bool,
        completion: @escaping (ImportResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                DispatchQueue.main.async {
                    self.importProgress = "正在解析文件..."
                    self.logger.debug("Parsing: \(url.lastPathComponent, privacy: .private(mask: .hash))")
                }

                let parsedBook = try autoreleasepool {
                    try self.parseBook(at: url)
                }

                DispatchQueue.main.async {
                    self.importProgress = "正在复制文件..."
                    self.logger.debug("Copying: \(url.lastPathComponent, privacy: .private(mask: .hash))")
                }

                guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    throw BookError.fileNotAccessible
                }
                let booksDir = documentsDir.appendingPathComponent("Books")
                try FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
                let destinationURL = booksDir.appendingPathComponent(url.lastPathComponent)
                let stagedURL = booksDir.appendingPathComponent(".book-import-\(UUID().uuidString)")
                do {
                    defer { try? FileManager.default.removeItem(at: stagedURL) }
                    try FileManager.default.copyItem(at: url, to: stagedURL)
                    try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
                } catch {
                    let cocoaError = error as NSError
                    if cocoaError.domain == NSCocoaErrorDomain,
                       cocoaError.code == CocoaError.Code.fileWriteFileExists.rawValue {
                        throw BookError.bookAlreadyExists
                    }
                    throw error
                }

                DispatchQueue.main.async {
                    self.importProgress = "正在保存..."
                    self.logger.debug("Saving: \(url.lastPathComponent, privacy: .private(mask: .hash))")
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                let book = Book(
                    title: parsedBook.title,
                    author: parsedBook.author,
                    filePath: destinationURL.path,
                    format: parsedBook.format,
                    fileSize: fileSize
                )
                let chapters = parsedBook.chapters.map { parsedChapter in
                    Chapter(
                        index: parsedChapter.index,
                        title: parsedChapter.title,
                        content: parsedChapter.content,
                        startLocation: parsedChapter.startLocation,
                        length: parsedChapter.length
                    )
                }

                DispatchQueue.main.async {
                    var savedBook: Book?
                    self.importPersistenceCancellable = self.bookRepository.addBook(book, chapters: chapters)
                        .receive(on: DispatchQueue.main)
                        .first()
                        .sink(
                            receiveCompletion: { [weak self] publisherCompletion in
                                switch publisherCompletion {
                                case .failure(let error):
                                    try? FileManager.default.removeItem(at: destinationURL)
                                    self?.cleanupSourceIfNeeded(url, enabled: removesSourceWhenFinished)
                                    completion(.failure("\(url.lastPathComponent): \(error.localizedDescription)"))
                                case .finished:
                                    guard let savedBook else {
                                        try? FileManager.default.removeItem(at: destinationURL)
                                        self?.cleanupSourceIfNeeded(url, enabled: removesSourceWhenFinished)
                                        completion(.failure("\(url.lastPathComponent): 保存未返回结果"))
                                        return
                                    }
                                    self?.cleanupSourceIfNeeded(url, enabled: removesSourceWhenFinished)
                                    completion(.success(savedBook))
                                }
                            },
                            receiveValue: { book in
                                savedBook = book
                            }
                        )
                }
            } catch {
                DispatchQueue.main.async {
                    self.cleanupSourceIfNeeded(url, enabled: removesSourceWhenFinished)
                    completion(.failure("\(url.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        }
    }

    private func processNextPendingBatchImportIfNeeded() {
        guard !isImporting, !isBatchImporting, !pendingBatchImports.isEmpty else { return }
        let pendingImport = pendingBatchImports.removeFirst()
        importBooks(
            from: pendingImport.urls,
            removesSourceWhenFinished: pendingImport.removesSourceWhenFinished
        )
    }

    private func parseBook(at url: URL) throws -> ParsedBook {
        switch url.pathExtension.lowercased() {
        case "epub":
            return try epubParser.parse(fileURL: url)
        case "pdf":
            return try pdfParser.parse(fileURL: url)
        default:
            return try txtParser.parse(fileURL: url)
        }
    }

    private func isSupportedBookURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["txt", "epub", "pdf"].contains(ext) || ext.isEmpty
    }

    private func containsFilename(_ filename: String, in books: [Book]) -> Bool {
        books.contains {
            URL(fileURLWithPath: $0.filePath).lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame
        }
    }

    private func publishImportedBooks(_ importedBooks: [Book]) {
        guard !importedBooks.isEmpty else { return }

        booksRequestCancellable?.cancel()
        let importedIDs = Set(importedBooks.map(\.id))
        let importedPaths = Set(importedBooks.map(\.filePath))
        var updatedBooks = books.filter {
            !importedIDs.contains($0.id) && !importedPaths.contains($0.filePath)
        }
        let matchingBooks = applyCurrentFilter(to: importedBooks)
            .filter(matchesCurrentSearch)
            .sorted { $0.createdAt > $1.createdAt }
        updatedBooks.insert(contentsOf: matchingBooks, at: 0)
        books = updatedBooks
    }

    private func matchesCurrentSearch(_ book: Book) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return book.title.localizedCaseInsensitiveContains(query)
            || (book.author?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func cleanupSourcesIfNeeded(_ urls: [URL], enabled: Bool) {
        guard enabled else { return }
        urls.forEach(cleanupSource)
    }

    private func cleanupSourceIfNeeded(_ url: URL, enabled: Bool) {
        guard enabled else { return }
        cleanupSource(url)
    }

    private func cleanupSource(_ url: URL) {
        let inboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderWiFiUploads", isDirectory: true)
            .standardizedFileURL
        let rootPrefix = inboxRoot.path.hasSuffix("/") ? inboxRoot.path : inboxRoot.path + "/"
        let source = url.standardizedFileURL
        guard source.path.hasPrefix(rootPrefix) else { return }

        try? FileManager.default.removeItem(at: source)

        let parent = source.deletingLastPathComponent()
        guard parent.path.hasPrefix(rootPrefix),
              (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true else {
            return
        }
        try? FileManager.default.removeItem(at: parent)
    }

    /// 删除书籍（包括数据库记录、本地文件和缓存）
    func deleteBook(_ book: Book) {
        // 先删除数据库记录，避免失败时留下指向已删除文件的书籍记录
        bookRepository.deleteBook(byId: book.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = self?.userFacingError(from: error)
                    }
                },
                receiveValue: { [weak self] _ in
                    let fileURL = URL(fileURLWithPath: book.filePath)
                    var cleanupError: Error?
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        do {
                            try FileManager.default.removeItem(at: fileURL)
                        } catch {
                            cleanupError = error
                        }
                    }
                    PageCacheManager.shared.clearCache(for: book.id)
                    self?.loadBooks()
                    if let cleanupError = cleanupError {
                        self?.error = .operationFailed(
                            message: "书籍记录已删除，但本地文件清理失败：\(cleanupError.localizedDescription)"
                        )
                    }
                }
            )
            .store(in: &cancellables)
    }

    /// 切换收藏状态
    func toggleFavorite(_ book: Book) {
        bookRepository.toggleFavorite(bookId: book.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = self?.userFacingError(from: error)
                    }
                },
                receiveValue: { [weak self] _ in
                    self?.loadBooks()
                }
            )
            .store(in: &cancellables)
    }

    /// 切换已读完状态
    func toggleCompleted(_ book: Book) {
        var updatedBook = book
        updatedBook.readingStatus = book.readingStatus == .completed ? .reading : .completed
        updatedBook.updatedAt = Date()

        bookRepository.updateBook(updatedBook)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = self?.userFacingError(from: error)
                    }
                },
                receiveValue: { [weak self] _ in
                    self?.loadBooks()
                }
            )
            .store(in: &cancellables)
    }

    private func userFacingError(from error: Error) -> BookError {
        if let bookError = error as? BookError {
            return bookError
        }
        if let parserError = error as? ParserError {
            return .operationFailed(message: parserError.localizedDescription)
        }
        return .operationFailed(message: error.localizedDescription)
    }

    private func applyCurrentFilter(to books: [Book]) -> [Book] {
        switch currentFilter {
        case .all:
            return books
        case .reading:
            return books.filter { $0.readingStatus == .reading }
        case .completed:
            return books.filter { $0.readingStatus == .completed }
        case .favorite:
            return books.filter(\.isFavorite)
        }
    }
}
