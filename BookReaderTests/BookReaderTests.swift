import Combine
import CoreData
import Foundation
import Testing
@testable import BookReader

struct BookReaderTests {
    @Test func libraryDefaultsToShowingAllBooks() {
        let viewModel = LibraryViewModel()

        #expect(viewModel.currentFilter == .all)
    }

    @Test func txtParserUsesUTF16Offsets() throws {
        let content = "序言😀\n第一章 开始\n正文😀\n第二章 继续\n结尾"
        let fileURL = temporaryFileURL(name: "offsets.txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let parsed = try TXTParser().parse(fileURL: fileURL)

        #expect(parsed.chapters.count == 3)
        #expect(parsed.chapters[0].length == "序言😀".utf16.count)
        #expect(parsed.chapters[1].startLocation == "序言😀".utf16.count)
        #expect(parsed.chapters[2].startLocation == "序言😀正文😀".utf16.count)
    }

    @Test func txtParserFallsBackAfterASCIIOnlyPrefix() throws {
        let content = String(repeating: "A", count: 5_000) + "\n第一章\n中文正文"
        let fileURL = temporaryFileURL(name: "gb18030.txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let data = try #require(content.data(using: .gb_18030_2000))
        try data.write(to: fileURL, options: .atomic)

        let parsed = try TXTParser().parse(fileURL: fileURL)

        #expect(parsed.chapters.last?.content == "中文正文")
    }

    @Test func pdfOutlineRangesIgnoreDuplicatesAndInvalidDestinations() {
        let ranges = PDFParser.normalizedPageRanges(
            pageIndices: [4, 2, 2, -1, 99, 1],
            pageCount: 6
        )

        #expect(ranges == [
            PDFParser.PageRange(startPage: 1, endPage: 1),
            PDFParser.PageRange(startPage: 2, endPage: 3),
            PDFParser.PageRange(startPage: 4, endPage: 5)
        ])
        #expect(PDFParser.normalizedPageRanges(pageIndices: [0], pageCount: 0).isEmpty)
    }

    @Test func epubParserReadsAStandardDeflatedArchive() throws {
        let base64Archive = """
        UEsDBBQAAAAAAK2EL11vYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAACACthC9dYaJ2fpYAAADPAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxNjsEOwiAQRH+l2atp0SsBmph41sQvQLpVIuwSoEb/XvRQvU0y82ZGjc8Yugfm4pk07IYtjEY5pmo9Ye6aS0XDkkmyLb5IshGLrE5yQprYLRGpym9MrhgYlZnr7AOWn+zmJYQ+2XrTcDzsT2fxARo+cJqhizh529dXQg02peCdre2UYLyk0jB3t1fctCUQRom/frHumjdQSwMEFAAAAAgArYQvXceBkkQHAQAAewEAABEAAABPRUJQUy9jb250ZW50Lm9wZlWQsU7DMBRFf8XyihonLKDIcTe+AD7Asl8SC9uxnAcpGwt0qMTGxsCExMTEgAR/Q0s/gzQNqRif7tG5epfPF86Sa4itaXxBsySlBLxqtPFVQS/Oz2andC54kOpSVkB62LcFrRFDzljXdYnRoUyaWLHjND1hTSjpHsq1mrhwFe3AaMXAggOPLcuSjFHBHaDUEqXgWuVo0ILYPC/Xy/v1w+rn83Xzvtq+PX5/vHA25TtSRZDYRDHmX0/b27sB+Qs4O5id9KaEFgU3CI4YXVBVy4AQM0rqCOXhThY1OkuJA23kDG8CFFSGYI2S2C/Ehvio/5CyXcUkboPxsPf3vr7in3WAR4SNW4pfUEsDBBQAAAAIAK2EL106Hr3/lwAAAKUAAAAUAAAAT0VCUFMvY2hhcHRlcjEueGh0bWyzySjJzVGoyM3JK7ZVyigpKbDS1y8vL9crN9bLL0rXN7S0tNSvAKlRsrPJSE1MsbMpySzJSbV7uqT9+ZQVzxa0v1w0w0YfImajD1GRlJ9SCVRtaPd8zZonOxqer14AlDG0symwA6p/2t6m4OLq5uMY4qrwbO3iZ9PaFdQScwusFZ6u63k2dcvjhiYb/QKgURBD9EFW2wEAUEsBAhQDFAAAAAAArYQvXW9hqywUAAAAFAAAAAgAAAAAAAAAAAAAAIABAAAAAG1pbWV0eXBlUEsBAhQDFAAAAAgArYQvXWGidn6WAAAAzwAAABYAAAAAAAAAAAAAAIABOgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxQSwECFAMUAAAACACthC9dx4GSRAcBAAB7AQAAEQAAAAAAAAAAAAAAgAEEAQAAT0VCUFMvY29udGVudC5vcGZQSwECFAMUAAAACACthC9dOh69/5cAAAClAAAAFAAAAAAAAAAAAAAAgAE6AgAAT0VCUFMvY2hhcHRlcjEueGh0bWxQSwUGAAAAAAQABAD7AAAAAwMAAAAA
        """
        let archiveData = try #require(
            Data(base64Encoded: base64Archive, options: .ignoreUnknownCharacters)
        )
        let fileURL = temporaryFileURL(name: "standard-deflated.epub")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try archiveData.write(to: fileURL, options: .atomic)

        let parsed = try EPUBParser().parse(fileURL: fileURL)

        #expect(parsed.title == "标准压缩测试书")
        #expect(parsed.author == "测试作者")
        #expect(parsed.chapters.map(\.title) == ["第一章"])
        #expect(parsed.chapters.first?.content.contains("标准 DEFLATE 正文 & 完整。") == true)
    }

    @Test func parserSizeErrorReportsTheFormatSpecificLimit() {
        let error = ParserError.fileTooLarge(
            actualSize: 201 * 1024 * 1024,
            maximumSize: 200 * 1024 * 1024
        )

        #expect(error.errorDescription?.contains("超过 200MB") == true)
    }

    @Test func pageCacheRequiresAnExactPaginationDescriptor() throws {
        let bookId = UUID()
        defer { PageCacheManager.shared.clearCache(for: bookId) }
        let descriptor = makeDescriptor(viewportWidth: 390)
        let pages = [
            Page(
                globalIndex: 0,
                content: "第一页",
                chapterIndex: 0,
                chapterTitle: "第一章",
                isChapterStart: true,
                contentOffset: 0
            )
        ]

        PageCacheManager.shared.saveCache(pages: pages, for: bookId, descriptor: descriptor)

        let cached = try #require(
            PageCacheManager.shared.loadCache(for: bookId, expectedDescriptor: descriptor)
        )
        #expect(cached.map(\.content) == ["第一页"])
        #expect(
            PageCacheManager.shared.loadCache(
                for: bookId,
                expectedDescriptor: makeDescriptor(viewportWidth: 430)
            ) == nil
        )
    }

    @Test func paginationDoesNotTruncateBooksOverFiveHundredPages() {
        let content = String(repeating: "长", count: 700)
            + String(repeating: "\n", count: 700)
            + "结尾"
        let chapter = Chapter(
            index: 0,
            title: "长篇",
            content: content,
            length: content.utf16.count
        )
        let pages = ReaderPaginationService().paginate(
            chapters: [chapter],
            descriptor: makeDescriptor(viewportWidth: 80, viewportHeight: 80)
        )

        #expect(pages.count > 500)
        #expect(pages.map(\.content).joined() == content)
        #expect(pages.last?.contentOffset != nil)
    }

    @Test func completedStatusSurvivesReadingAnEarlierPage() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = BookRepository(context: persistence.container.newBackgroundContext())
        let book = Book(
            title: "测试书籍",
            filePath: "/tmp/test-book.txt",
            format: .txt,
            readingStatus: .reading
        )

        _ = try await publisherValue(repository.addBook(book))
        _ = try await publisherValue(
            repository.updateReadingProgress(
                bookId: book.id,
                chapterIndex: 3,
                contentOffset: 120,
                isCompleted: true
            )
        )
        #expect(try await publisherValue(repository.getBook(byId: book.id))?.readingStatus == .completed)

        _ = try await publisherValue(
            repository.updateReadingProgress(
                bookId: book.id,
                chapterIndex: 1,
                contentOffset: 20,
                isCompleted: false
            )
        )
        #expect(try await publisherValue(repository.getBook(byId: book.id))?.readingStatus == .completed)
        #expect(try await publisherValue(repository.getRecentlyReadBooks(limit: 10)).isEmpty)

        let activeBook = Book(title: "在读书籍", filePath: "/tmp/active.txt", format: .txt)
        _ = try await publisherValue(repository.addBook(activeBook))
        _ = try await publisherValue(
            repository.updateReadingProgress(
                bookId: activeBook.id,
                chapterIndex: 0,
                contentOffset: 0,
                isCompleted: false
            )
        )
        let readingBooks = try await publisherValue(repository.getRecentlyReadBooks(limit: 10))
        #expect(readingBooks.map(\.id) == [activeBook.id])
    }

    @Test func loadBookUseCaseParsesAndPersistsMissingChapters() async throws {
        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let chapterRepository = ChapterRepository(context: persistence.container.newBackgroundContext())
        let book = Book(title: "旧数据", filePath: "/tmp/legacy.txt", format: .txt)
        let parsedChapters = [
            Chapter(index: 0, title: "正文", content: "补建的章节", length: 5)
        ]
        let useCase = LoadBookUseCase(
            bookRepository: bookRepository,
            chapterRepository: chapterRepository,
            parser: StubBookParser(chapters: parsedChapters)
        )

        _ = try await publisherValue(bookRepository.addBook(book))
        let loaded = try await publisherValue(
            useCase.execute(bookId: book.id, fileURL: URL(fileURLWithPath: book.filePath))
        )

        #expect(loaded.0.id == book.id)
        #expect(loaded.1.map(\.content) == ["补建的章节"])
        #expect(
            try await publisherValue(chapterRepository.getChapters(forBookId: book.id))
                .map(\.content) == ["补建的章节"]
        )
    }

    @Test func atomicImportPersistsChaptersAndRejectsDuplicateFilePath() async throws {
        let persistence = PersistenceController(inMemory: true)
        let bookRepository = BookRepository(context: persistence.container.newBackgroundContext())
        let chapterRepository = ChapterRepository(context: persistence.container.newBackgroundContext())
        let filePath = "/tmp/atomic-import-\(UUID().uuidString).txt"
        let book = Book(title: "原子导入", filePath: filePath, format: .txt)
        let chapters = [
            Chapter(index: 0, title: "第一章", content: "正文一", startLocation: 0, length: 3),
            Chapter(index: 1, title: "第二章", content: "正文二", startLocation: 3, length: 3)
        ]

        let savedBook = try await publisherValue(bookRepository.addBook(book, chapters: chapters))
        let savedChapters = try await publisherValue(chapterRepository.getChapters(forBookId: book.id))

        #expect(savedBook == book)
        #expect(savedChapters.map(\.title) == ["第一章", "第二章"])

        let duplicate = Book(title: "重复导入", filePath: filePath, format: .txt)
        var duplicateWasRejected = false
        do {
            _ = try await publisherValue(bookRepository.addBook(duplicate, chapters: chapters))
            Issue.record("相同文件路径应被拒绝")
        } catch BookError.bookAlreadyExists {
            duplicateWasRejected = true
        } catch {
            Issue.record("重复导入返回了错误类型：\(error)")
        }

        #expect(duplicateWasRejected)
        #expect(try await publisherValue(bookRepository.getAllBooks()).count == 1)
    }

    @Test func legacyStoreMigratesWithoutLosingBooks() throws {
        let modelDirectoryURL = try #require(
            [Bundle.main, Bundle(for: BookEntity.self)]
                .compactMap { $0.url(forResource: "BookReader", withExtension: "momd") }
                .first
        )
        let legacyModel = try #require(
            NSManagedObjectModel(
                contentsOf: modelDirectoryURL.appendingPathComponent("BookReader.mom")
            )
        )
        let currentModel = try #require(
            NSManagedObjectModel(
                contentsOf: modelDirectoryURL.appendingPathComponent("BookReaderV2.mom")
            )
        )
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("BookReader.sqlite")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let legacyCoordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
        let legacyStore = try legacyCoordinator.addPersistentStore(
            type: .sqlite,
            at: storeURL
        )
        let legacyContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        legacyContext.persistentStoreCoordinator = legacyCoordinator
        try legacyContext.performAndWait {
            let book = NSEntityDescription.insertNewObject(
                forEntityName: "BookEntity",
                into: legacyContext
            )
            book.setValue(UUID(), forKey: "id")
            book.setValue("迁移前的书", forKey: "title")
            book.setValue("/tmp/legacy-store.txt", forKey: "filePath")
            book.setValue("txt", forKey: "format")
            book.setValue(Date(), forKey: "createdAt")
            book.setValue(Date(), forKey: "updatedAt")
            book.setValue("unread", forKey: "readingStatus")
            try legacyContext.save()
        }
        try legacyCoordinator.remove(legacyStore)

        let currentCoordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        let migratedStore = try currentCoordinator.addPersistentStore(
            type: .sqlite,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let currentContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        currentContext.persistentStoreCoordinator = currentCoordinator
        try currentContext.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "BookEntity")
            let migratedBooks = try currentContext.fetch(request)
            #expect(migratedBooks.count == 1)
            #expect(migratedBooks.first?.value(forKey: "title") as? String == "迁移前的书")
            #expect((migratedBooks.first?.value(forKey: "readingSessions") as? NSSet)?.count == 0)
        }
        try currentCoordinator.remove(migratedStore)
    }

    @Test func dashboardStatsAggregateBooksAndSummaryFromSameSessions() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ReadingStatsRepository(context: persistence.container.newBackgroundContext())
        let firstBookId = UUID()
        let secondBookId = UUID()
        let now = Date()
        let sessions = [
            ReadingSession(
                bookId: firstBookId,
                bookTitle: "第一本",
                startTime: now.addingTimeInterval(-180),
                endTime: now.addingTimeInterval(-120)
            ),
            ReadingSession(
                bookId: firstBookId,
                bookTitle: "第一本",
                startTime: now.addingTimeInterval(-120),
                endTime: now
            ),
            ReadingSession(
                bookId: secondBookId,
                bookTitle: "第二本",
                startTime: now.addingTimeInterval(-30),
                endTime: now
            )
        ]

        for session in sessions {
            _ = try await publisherValue(repository.saveReadingSession(session))
        }

        let dashboard = try await publisherValue(repository.getDashboardStats())
        let statsByBook = Dictionary(uniqueKeysWithValues: dashboard.bookStats.map { ($0.bookId, $0) })

        #expect(dashboard.summary.totalReadingTime == 210)
        #expect(dashboard.summary.totalSessions == 3)
        #expect(dashboard.summary.totalBooksRead == 2)
        #expect(statsByBook[firstBookId]?.totalReadingTime == 180)
        #expect(statsByBook[firstBookId]?.sessionsCount == 2)
        #expect(statsByBook[secondBookId]?.totalReadingTime == 30)
    }

    @Test @MainActor func backgroundPauseExcludesTimeSpentAwayFromTheApp() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = ReadingStatsRepository(context: persistence.container.newBackgroundContext())
        var currentDate = Date()
        let tracker = ReadingTimeTracker(
            repository: repository,
            now: { currentDate },
            minimumSessionDuration: 5,
            notificationCenter: NotificationCenter()
        )

        tracker.startReading(bookId: UUID(), bookTitle: "计时测试")
        currentDate = currentDate.addingTimeInterval(2)
        tracker.pauseReading()
        currentDate = currentDate.addingTimeInterval(100)
        tracker.resumeReading()
        currentDate = currentDate.addingTimeInterval(6)
        tracker.stopReading()

        let sessions = try await publisherValue(repository.getAllSessions())
        #expect(sessions.count == 1)
        #expect(sessions.first?.duration == 6)
    }

    @Test @MainActor func successfulImportPublishesSavedBookWithoutReloading() async throws {
        let repository = RecordingBookRepository()
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceURL = temporaryFileURL(name: "visible-after-import.txt")
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURL = booksDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try "第一章\n导入完成后应立即显示".write(to: sourceURL, atomically: true, encoding: .utf8)

        viewModel.importBook(from: sourceURL)
        for _ in 0..<200 where !viewModel.importSuccess {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.importSuccess)
        #expect(!viewModel.isImporting)
        #expect(viewModel.books.count == 1)
        #expect(viewModel.books.first?.filePath == destinationURL.path)
    }

    @Test @MainActor func batchImportUsesAtomicBookAndChapterWrites() async throws {
        let repository = RecordingBookRepository()
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceURLs = [
            temporaryFileURL(name: "batch-first.txt"),
            temporaryFileURL(name: "batch-second.txt")
        ]
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURLs = sourceURLs.map {
            booksDirectory.appendingPathComponent($0.lastPathComponent)
        }
        defer {
            (sourceURLs + destinationURLs).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try "第一章\n第一本".write(to: sourceURLs[0], atomically: true, encoding: .utf8)
        try "第一章\n第二本".write(to: sourceURLs[1], atomically: true, encoding: .utf8)

        viewModel.importBooks(from: sourceURLs)
        for _ in 0..<300 where viewModel.isBatchImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isBatchImporting)
        #expect(viewModel.batchImportSuccessCount == 2)
        #expect(viewModel.batchImportFailCount == 0)
        #expect(repository.atomicAddBookCallCount == 2)
        #expect(repository.plainAddBookCallCount == 0)
        #expect(viewModel.books.count == 2)
    }

    @Test @MainActor func aSecondBatchWaitsForTheActiveImportInsteadOfBeingDropped() async throws {
        let repository = RecordingBookRepository()
        repository.shouldDelayNextAtomicImport = true
        let viewModel = LibraryViewModel(bookRepository: repository)
        let firstURL = temporaryFileURL(name: "queued-first.txt")
        let secondURL = temporaryFileURL(name: "queued-second.txt")
        let sourceURLs = [firstURL, secondURL]
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURLs = sourceURLs.map {
            booksDirectory.appendingPathComponent($0.lastPathComponent)
        }
        defer {
            (sourceURLs + destinationURLs).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try "第一章\n先导入".write(to: firstURL, atomically: true, encoding: .utf8)
        try "第一章\n排队导入".write(to: secondURL, atomically: true, encoding: .utf8)

        viewModel.importBooks(from: [firstURL])
        for _ in 0..<300 where repository.atomicAddBookCallCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(repository.atomicAddBookCallCount == 1)

        viewModel.importBooks(from: [secondURL])
        repository.completeDelayedAtomicImport()
        for _ in 0..<300 where viewModel.isBatchImporting || repository.atomicAddBookCallCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(repository.atomicAddBookCallCount == 2)
        #expect(viewModel.books.count == 2)
        #expect(viewModel.books.contains { $0.title.contains("queued-second") })
    }

    @Test @MainActor func importFinishingWithoutASavedBookDoesNotRemainStuck() async throws {
        let repository = RecordingBookRepository()
        repository.shouldFinishAtomicImportWithoutValue = true
        let viewModel = LibraryViewModel(bookRepository: repository)
        let sourceURL = temporaryFileURL(name: "empty-save-result.txt")
        let booksDirectory = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Books", isDirectory: true)
        let destinationURL = booksDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try "第一章\n保存链路异常".write(to: sourceURL, atomically: true, encoding: .utf8)

        viewModel.importBook(from: sourceURL)
        for _ in 0..<200 where viewModel.isImporting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isImporting)
        #expect(viewModel.error != nil)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test @MainActor func singlePageBookHasFiniteCompletedProgress() {
        let repository = RecordingBookRepository()
        let book = Book(title: "短篇", filePath: "/tmp/short.txt", format: .txt)
        let viewModel = ReaderViewModel(book: book, bookRepository: repository)
        viewModel.chapters = [Chapter(index: 0, title: "正文", content: "短篇")]
        viewModel.pages = [
            Page(
                globalIndex: 0,
                content: "短篇",
                chapterIndex: 0,
                chapterTitle: "正文",
                isChapterStart: true,
                contentOffset: 0
            )
        ]

        viewModel.jumpToProgress(0.5)

        #expect(viewModel.readingProgress == 1)
        #expect(viewModel.readingProgress.isFinite)
        #expect(repository.savedCompletionValues == [true])
    }

    private func temporaryFileURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BookReaderTests-\(UUID().uuidString)-\(name)")
    }

    private func makeDescriptor(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat = 844
    ) -> PageCacheDescriptor {
        PageCacheDescriptor(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            fontName: "System",
            fontSize: 18,
            lineSpacing: 8,
            paragraphSpacing: 0,
            horizontalPadding: 20,
            headerHeight: 28,
            contentTopPadding: 10,
            footerHeight: 30,
            sourceModificationTime: 1_000
        )
    }

    private func publisherValue<Output>(
        _ publisher: AnyPublisher<Output, Error>
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = publisher.first().sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        continuation.resume(throwing: error)
                    }
                    cancellable?.cancel()
                },
                receiveValue: { value in
                    continuation.resume(returning: value)
                    cancellable?.cancel()
                }
            )
        }
    }
}

private struct StubBookParser: BookChapterParsing {
    let chapters: [Chapter]

    func parseChapters(fileURL: URL) throws -> [Chapter] {
        chapters
    }
}

private final class RecordingBookRepository: BookRepositoryProtocol {
    var savedCompletionValues: [Bool] = []
    var shouldFinishAtomicImportWithoutValue = false
    var shouldDelayNextAtomicImport = false
    private(set) var plainAddBookCallCount = 0
    private(set) var atomicAddBookCallCount = 0
    private var delayedAtomicImport: (subject: PassthroughSubject<Book, Error>, book: Book)?

    func getAllBooks() -> AnyPublisher<[Book], Error> {
        success([])
    }

    func getBook(byId id: UUID) -> AnyPublisher<Book?, Error> {
        success(nil)
    }

    func addBook(_ book: Book) -> AnyPublisher<Book, Error> {
        plainAddBookCallCount += 1
        return success(book)
    }

    func addBook(_ book: Book, chapters: [Chapter]) -> AnyPublisher<Book, Error> {
        atomicAddBookCallCount += 1
        if shouldFinishAtomicImportWithoutValue {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }
        if shouldDelayNextAtomicImport {
            shouldDelayNextAtomicImport = false
            let subject = PassthroughSubject<Book, Error>()
            delayedAtomicImport = (subject, book)
            return subject.eraseToAnyPublisher()
        }
        return success(book)
    }

    func completeDelayedAtomicImport() {
        guard let delayedAtomicImport else { return }
        self.delayedAtomicImport = nil
        delayedAtomicImport.subject.send(delayedAtomicImport.book)
        delayedAtomicImport.subject.send(completion: .finished)
    }

    func updateBook(_ book: Book) -> AnyPublisher<Book, Error> {
        success(book)
    }

    func deleteBook(byId id: UUID) -> AnyPublisher<Void, Error> {
        success(())
    }

    func searchBooks(query: String) -> AnyPublisher<[Book], Error> {
        success([])
    }

    func getFavoriteBooks() -> AnyPublisher<[Book], Error> {
        success([])
    }

    func getRecentlyReadBooks(limit: Int) -> AnyPublisher<[Book], Error> {
        success([])
    }

    func updateReadingProgress(
        bookId: UUID,
        chapterIndex: Int,
        contentOffset: Int,
        isCompleted: Bool
    ) -> AnyPublisher<Void, Error> {
        savedCompletionValues.append(isCompleted)
        return success(())
    }

    func toggleFavorite(bookId: UUID) -> AnyPublisher<Bool, Error> {
        success(true)
    }

    private func success<Output>(_ output: Output) -> AnyPublisher<Output, Error> {
        Just(output)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}
