import Foundation
import Combine
import SwiftUI
import UIKit

/// 书签提示
struct BookmarkAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 阅读器视图模型
class ReaderViewModel: ObservableObject {
    let book: Book
    
    @Published var chapters: [Chapter] = []
    @Published var currentChapterIndex: Int = 0
    @Published var pages: [Page] = []
    @Published var currentPageIndex: Int = 0
    @Published var readingProgress: Double = 0.0
    @Published var showToolbar: Bool = false
    @Published var showCatalog: Bool = false
    @Published var showSettings: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: BookError?
    @Published var bookmarkAlert: BookmarkAlert?
    @Published var isCurrentPageBookmarked: Bool = false
    @Published var showBookmarkList: Bool = false
    @Published var bookmarkList: [Bookmark] = []
    
    /// pages 数组版本号，每次重分页时递增，用于通知 UIPageViewController 强制刷新
    @Published var pagesVersion: Int = 0
    
    /// 实际可用的视图尺寸（由 ReaderView 通过 GeometryReader 传入）
    private var availableViewSize: CGSize?
    private var activePaginationDescriptor: PageCacheDescriptor?
    private var paginationGeneration = 0
    
    /// 获取可用视图尺寸，如果尚未设置则回退到屏幕尺寸减去安全区域估算值
    private var effectiveViewSize: CGSize {
        if let size = availableViewSize {
            return size
        }
        // 回退：使用屏幕高度减去安全区域的估算值
        // 顶部状态栏约 47pt（刘海屏）或 20pt（非刘海屏），底部 Home Indicator 约 34pt
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let topInset = windowScene?.windows.first?.safeAreaInsets.top ?? 47
        let bottomInset = windowScene?.windows.first?.safeAreaInsets.bottom ?? 34
        return CGSize(
            width: UIScreen.main.bounds.width,
            height: UIScreen.main.bounds.height - topInset - bottomInset
        )
    }
    
    private let bookmarkRepository: BookmarkRepositoryProtocol
    private let loadBookUseCase: LoadBookUseCaseProtocol
    private let saveProgressUseCase: SaveProgressUseCaseProtocol
    private let paginationService: ReaderPaginationServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    private var currentBookmarks: [Bookmark] = []
    
    /// 从数据库获取的最新阅读进度（解决 book 对象快照过时问题）
    private var savedChapterIndex: Int
    private var savedContentOffset: Int
    
    /// 当前章节
    var currentChapter: Chapter? {
        chapters[safe: currentChapterIndex]
    }
    
    /// 当前页面
    var currentPage: Page? {
        pages[safe: currentPageIndex]
    }
    
    /// 是否有上一章
    var hasPreviousChapter: Bool {
        currentChapterIndex > 0
    }
    
    /// 是否有下一章
    var hasNextChapter: Bool {
        currentChapterIndex < chapters.count - 1
    }
    
    /// 当前章节内的页面进度（章节内第几页/章节总页数）
    var chapterPageProgress: (current: Int, total: Int) {
        guard let page = currentPage else { return (0, 0) }
        let chapterPages = pages.filter { $0.chapterIndex == page.chapterIndex }
        let currentInChapter = chapterPages.firstIndex { $0.globalIndex == page.globalIndex }.map { $0 + 1 } ?? 0
        return (currentInChapter, chapterPages.count)
    }
    
    /// 总页数
    var totalPages: Int {
        pages.count
    }
    
    init(
        book: Book,
        bookRepository: BookRepositoryProtocol = BookRepository(),
        chapterRepository: ChapterRepositoryProtocol = ChapterRepository(),
        bookmarkRepository: BookmarkRepositoryProtocol = BookmarkRepository(),
        bookParser: BookChapterParsing = TXTParser(),
        paginationService: ReaderPaginationServiceProtocol = ReaderPaginationService()
    ) {
        self.book = book
        self.bookmarkRepository = bookmarkRepository
        self.loadBookUseCase = LoadBookUseCase(
            bookRepository: bookRepository,
            chapterRepository: chapterRepository,
            parser: bookParser
        )
        self.saveProgressUseCase = SaveProgressUseCase(bookRepository: bookRepository)
        self.paginationService = paginationService
        self.savedChapterIndex = book.lastReadChapterIndex
        self.savedContentOffset = book.lastReadContentOffset
        self.currentChapterIndex = book.lastReadChapterIndex
        
        // 监听字体设置变化，触发重新分页
        NotificationCenter.default.publisher(for: .fontSizeDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repaginate()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .lineSpacingDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repaginate()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .readerFontDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repaginate()
            }
            .store(in: &cancellables)
    }
    
    /// 设置实际可用的视图尺寸（由 ReaderView 调用）
    func setAvailableViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        availableViewSize = size

        if !pages.isEmpty, makePaginationDescriptor() != activePaginationDescriptor {
            repaginate()
        }
    }
    
    /// 加载书籍内容
    func loadBook() {
        error = nil
        isLoading = true
        
        loadBookUseCase.execute(
            bookId: book.id,
            fileURL: URL(fileURLWithPath: book.filePath)
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = self?.userFacingError(from: error)
                        self?.isLoading = false
                    }
                },
                receiveValue: { [weak self] latestBook, chapters in
                    guard let self = self else { return }
                    self.savedChapterIndex = latestBook.lastReadChapterIndex
                    self.savedContentOffset = latestBook.lastReadContentOffset
                    self.chapters = chapters
                    self.continueLoadBook(with: chapters)
                }
            )
            .store(in: &cancellables)
    }
    
    /// loadBook 的后续逻辑（获取最新进度和章节后执行）
    private func continueLoadBook(with chapters: [Chapter]) {
        
        // 先检查页面缓存
        let descriptor = makePaginationDescriptor()
        if let cachedPages = PageCacheManager.shared.loadCache(for: book.id, expectedDescriptor: descriptor) {
            print("Loaded \(cachedPages.count) pages from cache")
            self.pages = cachedPages
            self.activePaginationDescriptor = descriptor
            self.pagesVersion += 1
            
            // 加载书签
            loadBookmarks()
            
            // 跳转到保存的位置（此时 isLoading 仍为 true，跳转完成后设为 false）
            jumpToSavedPosition()
            return
        }
        
        loadBookmarks()
        paginateAllChapters { [weak self] in
            self?.jumpToSavedPosition()
        }
    }
    
    /// 跳转到保存的阅读位置
    private func jumpToSavedPosition() {
        let targetChapter = savedChapterIndex
        let targetContentOffset = savedContentOffset
        
        guard let targetPage = pageContaining(
            chapterIndex: targetChapter,
            contentOffset: targetContentOffset
        ), let globalIndex = pages.firstIndex(where: { $0.globalIndex == targetPage.globalIndex }) else {
            currentPageIndex = 0
            currentChapterIndex = pages.first?.chapterIndex ?? 0
            updateProgress()
            isLoading = false
            checkCurrentPageBookmark()
            return
        }

        currentPageIndex = globalIndex
        currentChapterIndex = targetPage.chapterIndex
        
        updateProgress()
        isLoading = false
        checkCurrentPageBookmark()
    }
    
    /// 加载书签
    private func loadBookmarks() {
        bookmarkRepository.getBookmarks(forBookId: book.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.presentOperationError(title: "书签加载失败", error: error)
                    }
                },
                receiveValue: { [weak self] bookmarks in
                    self?.currentBookmarks = bookmarks
                    self?.checkCurrentPageBookmark()
                }
            )
            .store(in: &cancellables)
    }
    
    /// 对所有章节进行统一分页（在后台线程执行，避免阻塞UI）
    private func paginateAllChapters(completion: (() -> Void)? = nil) {
        guard !chapters.isEmpty else {
            pages = []
            completion?()
            return
        }
        
        let descriptor = makePaginationDescriptor()
        let chaptersCopy = self.chapters
        let bookId = self.book.id
        let paginationService = self.paginationService
        paginationGeneration += 1
        let generation = paginationGeneration
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let allPages = paginationService.paginate(chapters: chaptersCopy, descriptor: descriptor)
            
            DispatchQueue.main.async {
                guard generation == self.paginationGeneration else { return }
                self.pages = allPages
                self.activePaginationDescriptor = descriptor
                self.pagesVersion += 1

                DispatchQueue.global(qos: .utility).async {
                    PageCacheManager.shared.saveCache(
                        pages: allPages,
                        for: bookId,
                        descriptor: descriptor
                    )
                }
                
                // 调用完成回调
                completion?()
            }
        }
    }
    
    /// 重新分页（字体设置变化时调用）
    func repaginate() {
        PageCacheManager.shared.clearCache(for: book.id)
        
        // 保存当前页面的 contentOffset 和章节索引，用于重分页后定位
        let savedContentOffset = currentPage?.contentOffset ?? 0
        let savedChapterIndex = currentChapterIndex
        
        paginateAllChapters { [weak self] in
            guard let self = self else { return }

            if let targetPage = self.pageContaining(
                chapterIndex: savedChapterIndex,
                contentOffset: savedContentOffset
            ), let pageIndex = self.pages.firstIndex(where: { $0.globalIndex == targetPage.globalIndex }) {
                self.currentPageIndex = pageIndex
                self.currentChapterIndex = targetPage.chapterIndex
            } else {
                self.currentPageIndex = 0
                self.currentChapterIndex = self.pages.first?.chapterIndex ?? 0
            }

            self.updateProgress()
            self.checkCurrentPageBookmark()
        }
    }
    
    /// 上一章
    func previousChapter() {
        guard hasPreviousChapter else { return }
        currentChapterIndex -= 1
        
        // 跳转到上一章的最后一页（该章节中 contentOffset 最大的页面）
        let chapterPages = pages.filter { $0.chapterIndex == currentChapterIndex }
        if let lastPageOfChapter = chapterPages.max(by: { $0.contentOffset < $1.contentOffset }),
           let pageIndex = pages.firstIndex(where: { $0.globalIndex == lastPageOfChapter.globalIndex }) {
            currentPageIndex = pageIndex
        }
        
        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }
    
    /// 下一章
    func nextChapter() {
        guard hasNextChapter else { return }
        currentChapterIndex += 1
        
        // 跳转到下一章的第一页（该章节中 contentOffset 最小的页面）
        let chapterPages = pages.filter { $0.chapterIndex == currentChapterIndex }
        if let firstPageOfChapter = chapterPages.min(by: { $0.contentOffset < $1.contentOffset }),
           let pageIndex = pages.firstIndex(where: { $0.globalIndex == firstPageOfChapter.globalIndex }) {
            currentPageIndex = pageIndex
        }
        
        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }
    
    /// 跳转到指定章节
    func jumpToChapter(_ index: Int) {
        guard index >= 0 && index < chapters.count else { return }
        currentChapterIndex = index
        
        // 跳转到该章节的第一页（contentOffset 最小的页面）
        let chapterPages = pages.filter { $0.chapterIndex == index }
        if let firstPageOfChapter = chapterPages.min(by: { $0.contentOffset < $1.contentOffset }),
           let pageIndex = pages.firstIndex(where: { $0.globalIndex == firstPageOfChapter.globalIndex }) {
            currentPageIndex = pageIndex
        }
        
        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }
    
    /// 跳转到进度位置
    func jumpToProgress(_ progress: Double) {
        guard !pages.isEmpty else { return }
        let targetPage = Int(Double(pages.count - 1) * progress)
        currentPageIndex = max(0, min(targetPage, pages.count - 1))
        
        // 更新当前章节
        if let page = currentPage {
            currentChapterIndex = page.chapterIndex
        }
        
        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }
    
    /// 更新页面进度（翻页时调用）
    func updateProgressForPage(_ pageIndex: Int) {
        guard pageIndex >= 0 && pageIndex < pages.count else { return }
        
        currentPageIndex = pageIndex
        
        // 更新当前章节
        if let page = currentPage {
            currentChapterIndex = page.chapterIndex
        }
        
        // 使用 async 避免在视图更新期间发布状态变化
        DispatchQueue.main.async {
            self.updateProgress()
            self.saveProgress()
            self.checkCurrentPageBookmark()
        }
    }
    
    /// 更新进度值
    private func updateProgress() {
        guard !pages.isEmpty else {
            readingProgress = 0
            return
        }
        guard pages.count > 1 else {
            readingProgress = 1
            return
        }
        readingProgress = Double(currentPageIndex) / Double(pages.count - 1)
    }
    
    /// 切换工具栏显示
    func toggleToolbar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showToolbar.toggle()
        }
    }
    
    /// 保存阅读进度
    private func saveProgress() {
        guard let page = currentPage else { return }
        
        // 保存章节索引和精确的 contentOffset
        saveProgressUseCase.execute(
            bookId: book.id,
            chapterIndex: currentChapterIndex,
            contentOffset: page.contentOffset,
            isCompleted: currentPageIndex == pages.count - 1
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { [weak self] completion in
                if case .failure(let error) = completion {
                    self?.presentOperationError(title: "进度保存失败", error: error)
                }
            },
            receiveValue: { _ in }
        )
        .store(in: &cancellables)
    }
    
    // MARK: - 书签功能
    
    private func checkCurrentPageBookmark() {
        isCurrentPageBookmarked = bookmarkOnCurrentPage() != nil
    }
    
    func toggleBookmark() {
        guard let page = currentPage else { return }
        
        if let existingBookmark = bookmarkOnCurrentPage() {
            bookmarkRepository.deleteBookmark(byId: existingBookmark.id)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { [weak self] completion in
                        if case .failure(let error) = completion {
                            self?.presentOperationError(title: "书签删除失败", error: error)
                        }
                    },
                    receiveValue: { [weak self] _ in
                        self?.currentBookmarks.removeAll { $0.id == existingBookmark.id }
                        self?.checkCurrentPageBookmark()
                        self?.bookmarkAlert = BookmarkAlert(
                            title: "书签已删除",
                            message: "\(page.chapterTitle) 的书签已删除"
                        )
                    }
                )
                .store(in: &cancellables)
        } else {
            let bookmark = Bookmark(
                bookId: book.id,
                chapterIndex: page.chapterIndex,
                location: page.contentOffset,
                type: .bookmark,
                selectedText: String(page.content.prefix(50))
            )
            
            bookmarkRepository.addBookmark(bookmark)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { [weak self] completion in
                        if case .failure(let error) = completion {
                            self?.presentOperationError(title: "书签添加失败", error: error)
                        }
                    },
                    receiveValue: { [weak self] savedBookmark in
                        self?.currentBookmarks.append(savedBookmark)
                        self?.checkCurrentPageBookmark()
                        self?.bookmarkAlert = BookmarkAlert(
                            title: "书签已添加",
                            message: "\(page.chapterTitle) 已添加书签"
                        )
                    }
                )
                .store(in: &cancellables)
        }
    }
    
    /// 打开书签列表
    func openBookmarkList() {
        bookmarkList = currentBookmarks.sorted { $0.createdAt > $1.createdAt }
        showBookmarkList = true
    }
    
    /// 跳转到书签所在章节
    func jumpToBookmark(_ bookmark: Bookmark) {
        if let targetPage = pageContaining(
            chapterIndex: bookmark.chapterIndex,
            contentOffset: bookmark.location
        ), let pageIndex = pages.firstIndex(where: { $0.globalIndex == targetPage.globalIndex }) {
            currentPageIndex = pageIndex
            currentChapterIndex = targetPage.chapterIndex
            updateProgress()
            saveProgress()
            checkCurrentPageBookmark()
        }
        showBookmarkList = false
    }
    
    /// 删除书签
    func deleteBookmark(_ bookmark: Bookmark) {
        bookmarkRepository.deleteBookmark(byId: bookmark.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.presentOperationError(title: "书签删除失败", error: error)
                    }
                },
                receiveValue: { [weak self] _ in
                    self?.currentBookmarks.removeAll { $0.id == bookmark.id }
                    self?.bookmarkList = self?.currentBookmarks.sorted { $0.createdAt > $1.createdAt } ?? []
                    self?.checkCurrentPageBookmark()
                }
            )
            .store(in: &cancellables)
    }

    private func pageContaining(chapterIndex: Int, contentOffset: Int) -> Page? {
        let chapterPages = pages.filter { $0.chapterIndex == chapterIndex }
        return chapterPages.last { $0.contentOffset <= contentOffset } ?? chapterPages.first
    }

    private func bookmarkOnCurrentPage() -> Bookmark? {
        guard let page = currentPage else { return nil }
        let nextOffset = pages
            .dropFirst(currentPageIndex + 1)
            .first { $0.chapterIndex == page.chapterIndex }?
            .contentOffset ?? Int.max

        return currentBookmarks.first {
            $0.chapterIndex == page.chapterIndex
                && $0.location >= page.contentOffset
                && $0.location < nextOffset
        }
    }

    private func makePaginationDescriptor() -> PageCacheDescriptor {
        let size = effectiveViewSize
        let attributes = try? FileManager.default.attributesOfItem(atPath: book.filePath)
        let modificationDate = attributes?[.modificationDate] as? Date

        return PageCacheDescriptor(
            viewportWidth: normalized(size.width),
            viewportHeight: normalized(size.height),
            fontName: FontService.shared.currentFont,
            fontSize: normalized(ThemeService.shared.fontSize),
            lineSpacing: normalized(ThemeService.shared.lineSpacing),
            paragraphSpacing: normalized(ThemeService.shared.paragraphSpacing),
            horizontalPadding: ReaderLayoutMetrics.horizontalPadding,
            headerHeight: ReaderLayoutMetrics.headerHeight,
            contentTopPadding: ReaderLayoutMetrics.contentTopPadding,
            footerHeight: ReaderLayoutMetrics.footerHeight,
            sourceModificationTime: modificationDate?.timeIntervalSince1970 ?? book.updatedAt.timeIntervalSince1970
        )
    }

    private func normalized(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    private func userFacingError(from error: Error) -> BookError {
        if let bookError = error as? BookError {
            return bookError
        }
        return .operationFailed(message: error.localizedDescription)
    }

    private func presentOperationError(title: String, error: Error) {
        bookmarkAlert = BookmarkAlert(title: title, message: error.localizedDescription)
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
