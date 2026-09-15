import Foundation
import Combine

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
    private let chapterRepository: ChapterRepositoryProtocol
    private let txtParser = TXTParser()
    private let epubParser = EPUBParser()
    private let pdfParser = PDFParser()
    private var cancellables = Set<AnyCancellable>()
    private var booksRequestCancellable: AnyCancellable?

    init(
        bookRepository: BookRepositoryProtocol = BookRepository(),
        chapterRepository: ChapterRepositoryProtocol = ChapterRepository()
    ) {
        self.bookRepository = bookRepository
        self.chapterRepository = chapterRepository
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
        let ext = url.pathExtension.lowercased()
        guard ["txt", "epub", "pdf"].contains(ext) || ext.isEmpty else {
            error = .parseFailed
            return
        }

        // 重置导入状态
        importSuccess = false
        importedBookTitle = ""

        // 从文件名提取书籍名称（去掉扩展名）
        let bookName = url.deletingPathExtension().lastPathComponent
        importingBookTitle = bookName

        // 开始导入，显示进度
        isImporting = true
        importProgress = "正在检查..."

        // 启动安全作用域访问（.open 模式需要）
        let accessing = url.startAccessingSecurityScopedResource()

        // 检查是否已存在相同文件名的书籍
        let fileName = url.lastPathComponent
        bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard case .failure(let error) = completion else { return }
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                    self?.isImporting = false
                    self?.importingBookTitle = ""
                    self?.error = self?.userFacingError(from: error)
                },
                receiveValue: { [weak self] books in
                    guard let self = self else {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                        return
                    }

                    // 检查是否已存在相同文件名的书籍
                    let existingBook = books.first { book in
                        let bookFileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                        return bookFileName == fileName
                    }

                    if existingBook != nil {
                        // 书籍已存在，提示用户
                        self.isImporting = false
                        self.importingBookTitle = ""
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                        self.error = .bookAlreadyExists
                        return
                    }

                    // 继续导入流程（安全作用域由 continueImportBook 统一管理）
                    self.continueImportBook(from: url, accessing: accessing)
                }
            )
            .store(in: &cancellables)
    }

    /// 批量导入书籍
    func importBooks(from urls: [URL]) {
        guard !urls.isEmpty else { return }

        // 重置批量导入状态
        batchImportSuccess = false
        batchImportSuccessCount = 0
        batchImportFailCount = 0
        batchImportFailedTitles = []
        batchImportTotal = urls.count
        batchImportCurrent = 0
        isBatchImporting = true
        batchImportProgress = "正在检查 \(urls.count) 个文件..."

        // 启动所有文件的安全作用域访问
        var accessTokens: [(url: URL, accessing: Bool)] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            accessTokens.append((url: url, accessing: accessing))
        }

        // 先获取已有书籍列表用于去重
        bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] existingBooks in
                    guard let self = self else { return }

                    let existingFileNames = Set(existingBooks.map { book in
                        URL(fileURLWithPath: book.filePath).lastPathComponent
                    })

                    // 过滤掉已存在的文件
                    let urlsToImport = accessTokens.filter { token in
                        let fileName = token.url.lastPathComponent
                        return !existingFileNames.contains(fileName)
                    }.map { $0.url }

                    // 释放不需要导入的文件的安全作用域
                    for token in accessTokens {
                        if !urlsToImport.contains(token.url) && token.accessing {
                            token.url.stopAccessingSecurityScopedResource()
                        }
                    }

                    if urlsToImport.isEmpty {
                        self.isBatchImporting = false
                        self.batchImportProgress = ""
                        self.error = .bookAlreadyExists
                        return
                    }

                    self.batchImportTotal = urlsToImport.count
                    self.batchImportCurrent = 0
                    self.batchImportProgress = "准备导入 \(urlsToImport.count) 个文件..."

                    // 在后台线程逐个导入
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.processBatchImport(urls: urlsToImport)
                    }
                }
            )
            .store(in: &cancellables)
    }

    /// 处理批量导入（在后台线程执行）
    private func processBatchImport(urls: [URL]) {
        var successCount = 0
        var failCount = 0
        var failedTitles: [String] = []

        for (index, url) in urls.enumerated() {
            let bookName = url.deletingPathExtension().lastPathComponent

            DispatchQueue.main.async {
                self.batchImportCurrent = index + 1
                self.batchImportProgress = "正在导入 (\(index + 1)/\(urls.count)): \(bookName)"
                self.importingBookTitle = bookName
            }

            let result = importSingleBook(from: url)

            switch result {
            case .success:
                successCount += 1
            case .failure(let title):
                failCount += 1
                failedTitles.append(title)
            }
        }

        DispatchQueue.main.async {
            self.isBatchImporting = false
            self.batchImportProgress = ""
            self.importingBookTitle = ""
            self.batchImportSuccess = true
            self.batchImportSuccessCount = successCount
            self.batchImportFailCount = failCount
            self.batchImportFailedTitles = failedTitles
            self.loadBooks()
        }
    }

    /// 导入单个书籍（同步方法，用于批量导入）
    private enum ImportResult {
        case success
        case failure(String)
    }

    private func importSingleBook(from url: URL) -> ImportResult {
        let ext = url.pathExtension.lowercased()
        guard ["txt", "epub", "pdf"].contains(ext) || ext.isEmpty else {
            return .failure(url.lastPathComponent)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // 解析书籍
            let parsedBook: ParsedBook
            switch ext {
            case "epub":
                parsedBook = try epubParser.parse(fileURL: url)
            case "pdf":
                parsedBook = try pdfParser.parse(fileURL: url)
            default:
                parsedBook = try txtParser.parse(fileURL: url)
            }

            // 复制到 Documents 目录
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let booksDir = documentsDir.appendingPathComponent("Books")
            try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)

            let destinationURL = booksDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: url, to: destinationURL)

            // 创建书籍实体
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

            // 保存书籍和章节；批量导入在后台串行等待当前文件完成。
            let semaphore = DispatchSemaphore(value: 0)
            var saveError: Error?

            DispatchQueue.main.async {
                self.bookRepository.addBook(book)
                    .flatMap { _ in
                        self.chapterRepository.saveChapters(chapters, forBookId: book.id)
                            .map { book }
                            .eraseToAnyPublisher()
                    }
                    .receive(on: DispatchQueue.main)
                    .sink(
                        receiveCompletion: { completion in
                            if case .failure(let error) = completion {
                                saveError = error
                            }
                            semaphore.signal()
                        },
                        receiveValue: { _ in }
                    )
                    .store(in: &self.cancellables)
            }

            semaphore.wait()

            if let saveError = saveError {
                return .failure("\(url.lastPathComponent): \(saveError.localizedDescription)")
            }

            return .success
        } catch {
            return .failure("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// 继续导入书籍（去重检查通过后）
    private func continueImportBook(from url: URL, accessing: Bool) {
        // 在后台线程执行耗时操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }

            // 确保安全作用域访问被释放
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                // 更新进度：解析文件
                DispatchQueue.main.async {
                    self.importProgress = "正在解析文件..."
                }

                // 解析书籍（根据格式选择解析器）
                let parsedBook: ParsedBook
                let fileExt = url.pathExtension.lowercased()
                switch fileExt {
                case "epub":
                    parsedBook = try self.epubParser.parse(fileURL: url)
                case "pdf":
                    parsedBook = try self.pdfParser.parse(fileURL: url)
                default:
                    parsedBook = try self.txtParser.parse(fileURL: url)
                }

                // 更新进度：复制文件
                DispatchQueue.main.async {
                    self.importProgress = "正在复制文件..."
                }

                // 复制到Documents目录
                let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let booksDir = documentsDir.appendingPathComponent("Books")
                try FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)

                let destinationURL = booksDir.appendingPathComponent(url.lastPathComponent)

                // 防止覆盖孤立文件或并发导入生成的同名文件
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    throw BookError.bookAlreadyExists
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)

                // 更新进度：保存到数据库
                DispatchQueue.main.async {
                    self.importProgress = "正在保存..."
                }

                // 创建书籍实体
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

                let bookRepository = self.bookRepository
                let chapterRepository = self.chapterRepository

                // 串联保存书籍和章节；Repository 使用后台 context 执行 Core Data 操作
                DispatchQueue.main.async {
                    bookRepository.addBook(book)
                        .flatMap { _ in
                            chapterRepository.saveChapters(chapters, forBookId: book.id)
                                .map { book }
                                .eraseToAnyPublisher()
                        }
                        .receive(on: DispatchQueue.main)
                        .sink(
                            receiveCompletion: { [weak self] completion in
                                if case .failure(let error) = completion {
                                    guard let self = self else { return }
                                    var failureMessage = self.userFacingError(from: error).localizedDescription
                                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                                        do {
                                            try FileManager.default.removeItem(at: destinationURL)
                                        } catch {
                                            failureMessage += "；临时文件清理失败：\(error.localizedDescription)"
                                        }
                                    }
                                    self.isImporting = false
                                    self.importingBookTitle = ""
                                    self.error = .operationFailed(message: failureMessage)
                                    bookRepository.deleteBook(byId: book.id)
                                        .receive(on: DispatchQueue.main)
                                        .sink(
                                            receiveCompletion: { [weak self] rollbackCompletion in
                                                guard let self = self else { return }
                                                guard case .failure(let rollbackError) = rollbackCompletion,
                                                      !self.isMissingRollbackRecord(rollbackError) else {
                                                    return
                                                }
                                                self.error = .operationFailed(
                                                    message: "\(failureMessage)；数据库回滚失败：\(rollbackError.localizedDescription)"
                                                )
                                            },
                                            receiveValue: { _ in }
                                        )
                                        .store(in: &self.cancellables)
                                }
                            },
                            receiveValue: { [weak self] _ in
                                guard let self = self else { return }
                                self.isImporting = false
                                self.importingBookTitle = ""
                                self.importSuccess = true
                                self.importedBookTitle = book.title
                                self.loadBooks()
                            }
                        )
                        .store(in: &self.cancellables)
                }

            } catch {
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.importingBookTitle = ""
                    self.error = self.userFacingError(from: error)
                }
            }
        }
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

    private func isMissingRollbackRecord(_ error: Error) -> Bool {
        guard let bookError = error as? BookError else { return false }
        if case .notFound = bookError {
            return true
        }
        return false
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
