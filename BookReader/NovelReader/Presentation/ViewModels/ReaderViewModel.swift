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
@MainActor
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
    @Published private(set) var isPreparingRemainingPages: Bool = false
    @Published var error: BookError?
    @Published var bookmarkAlert: BookmarkAlert?
    @Published var isCurrentPageBookmarked: Bool = false
    @Published var showBookmarkList: Bool = false
    @Published var bookmarkList: [Bookmark] = []
    @Published private(set) var readerAnnotations: [Bookmark] = []
    @Published private(set) var activeSelection: ReaderTextSelection?
    @Published var showSelectionActions: Bool = false
    @Published var showCommentComposer: Bool = false
    @Published var commentDraft: String = ""
    @Published private(set) var isSavingSelection: Bool = false
    @Published var presentedAnnotationKey: ReaderAnnotationKey?
    @Published private(set) var isSavingAnnotationThought: Bool = false
    @Published private(set) var isDeletingAnnotation: Bool = false

    /// pages 数组版本号，每次重分页时递增，用于通知 UIPageViewController 强制刷新
    @Published var pagesVersion: Int = 0

    /// 听书状态
    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false

    /// 实际可用的视图尺寸（由 ReaderView 通过 GeometryReader 传入）
    private var availableViewSize: CGSize?
    private var activePaginationDescriptor: PageCacheDescriptor?
    private var paginationGeneration = 0
    private var paginationCancellationToken: PaginationCancellationToken?

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
    private var progressSaveCancellable: AnyCancellable?
    private var progressSaveWorkItem: DispatchWorkItem?
    private var currentBookmarks: [Bookmark] = []
    private var pendingProgressSave: ProgressSnapshot?
    private var needsProgressRefreshWhenPaginationCompletes = false

    private struct ProgressSnapshot {
        let chapterIndex: Int
        let contentOffset: Int
        let isCompleted: Bool
    }

    private struct ReadingLocation {
        let chapterIndex: Int
        let contentOffset: Int
    }

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
        guard let page = currentPage,
              let range = ReaderPageLocator.chapterRange(page.chapterIndex, in: pages) else {
            return (0, 0)
        }
        return (currentPageIndex - range.lowerBound + 1, range.count)
    }

    /// 总页数
    var totalPages: Int {
        pages.count
    }

    /// 当前页面生成时使用的分页配置，显示端必须复用它以保证排版完全一致。
    var displayPaginationDescriptor: PageCacheDescriptor {
        activePaginationDescriptor ?? makePaginationDescriptor()
    }

    init(
        book: Book,
        bookRepository: BookRepositoryProtocol = BookRepository(),
        chapterRepository: ChapterRepositoryProtocol = ChapterRepository(),
        bookmarkRepository: BookmarkRepositoryProtocol = BookmarkRepository(),
        bookParser: BookChapterParsing = FormatAwareBookParser(),
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
        // 监听语音服务状态变化
        SpeechService.shared.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                self?.isSpeaking = speaking
            }
            .store(in: &cancellables)

        SpeechService.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                self?.isPaused = paused
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .readerFontDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repaginate()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.flushProgress()
            }
            .store(in: &cancellables)
    }

    deinit {
        paginationCancellationToken?.cancel()
        progressSaveWorkItem?.cancel()
        progressSaveCancellable?.cancel()
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
        // 缓存文件可能很大，读取和 JSON 解码不能占用主线程。
        paginationCancellationToken?.cancel()
        let descriptor = makePaginationDescriptor()
        let bookId = book.id
        paginationGeneration += 1
        let generation = paginationGeneration

        DispatchQueue.global(qos: .utility).async {
            let cachedPages = PageCacheManager.shared.loadCache(
                for: bookId,
                expectedDescriptor: descriptor,
                chapters: chapters
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.paginationGeneration else { return }
                self.loadBookmarks()

                if let cachedPages {
                    self.isPreparingRemainingPages = false
                    self.activePaginationDescriptor = descriptor
                    self.pages = cachedPages
                    self.pagesVersion += 1
                    self.jumpToSavedPosition()
                } else {
                    self.paginateChapters(
                        focusedAt: self.savedChapterIndex,
                        initialLocation: ReadingLocation(
                            chapterIndex: self.savedChapterIndex,
                            contentOffset: self.savedContentOffset
                        )
                    )
                }
            }
        }
    }

    /// 跳转到保存的阅读位置
    private func jumpToSavedPosition() {
        let targetChapter = savedChapterIndex
        let targetContentOffset = savedContentOffset

        guard let pageIndex = ReaderPageLocator.pageIndex(
            containing: targetContentOffset,
            inChapter: targetChapter,
            pages: pages
        ) else {
            currentPageIndex = 0
            currentChapterIndex = pages.first?.chapterIndex ?? 0
            updateProgress()
            isLoading = false
            checkCurrentPageBookmark()
            return
        }

        currentPageIndex = pageIndex
        currentChapterIndex = pages[pageIndex].chapterIndex

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
                    self?.refreshBookmarkState()
                    self?.checkCurrentPageBookmark()
                }
            )
            .store(in: &cancellables)
    }

    /// 先发布当前章节，再发布相邻章节，最后在后台补齐全书分页。
    private func paginateChapters(
        focusedAt requestedChapterIndex: Int,
        initialLocation: ReadingLocation,
        onInitialPagesReady: (() -> Void)? = nil
    ) {
        guard !chapters.isEmpty else {
            pages = []
            isPreparingRemainingPages = false
            isLoading = false
            onInitialPagesReady?()
            return
        }

        let descriptor = makePaginationDescriptor()
        let chaptersCopy = self.chapters
        let bookId = self.book.id
        let paginationService = self.paginationService
        let focusedChapterIndex = min(max(0, requestedChapterIndex), chaptersCopy.count - 1)
        let normalizedInitialLocation = ReadingLocation(
            chapterIndex: focusedChapterIndex,
            contentOffset: initialLocation.chapterIndex == focusedChapterIndex
                ? initialLocation.contentOffset
                : 0
        )
        let priorityOrder = ReaderPaginationPlan.priorityOrder(
            chapterCount: chaptersCopy.count,
            focusedChapterIndex: focusedChapterIndex
        )
        let adjacentIndexes = ReaderPaginationPlan.focusedAndAdjacentIndexes(
            chapterCount: chaptersCopy.count,
            focusedChapterIndex: focusedChapterIndex
        )
        let adjacentIndexSet = Set(adjacentIndexes)

        paginationCancellationToken?.cancel()
        let cancellationToken = PaginationCancellationToken()
        paginationCancellationToken = cancellationToken
        paginationGeneration += 1
        let generation = paginationGeneration
        isPreparingRemainingPages = chaptersCopy.count > 1

        DispatchQueue.global(qos: .userInitiated).async {
            var pagesByChapter: [Int: [Page]] = [:]
            var didPublishInitialPages = false
            var didPublishAdjacentPages = false

            for chapterIndex in priorityOrder {
                guard !cancellationToken.isCancelled else { return }
                pagesByChapter[chapterIndex] = paginationService.paginateChapter(
                    chaptersCopy[chapterIndex],
                    chapterIndex: chapterIndex,
                    descriptor: descriptor,
                    cancellationToken: cancellationToken
                )
                guard !cancellationToken.isCancelled else { return }

                let loadedIndexes = Set(pagesByChapter.keys)
                let adjacentPagesAreReady = adjacentIndexSet.isSubset(of: loadedIndexes)
                let isFinalStage = loadedIndexes.count == chaptersCopy.count
                let shouldPublish = !didPublishInitialPages
                    || (adjacentPagesAreReady && !didPublishAdjacentPages)
                    || isFinalStage
                guard shouldPublish else { continue }

                let stageIndexes: [Int]
                if isFinalStage {
                    stageIndexes = Array(chaptersCopy.indices)
                } else if !didPublishInitialPages, adjacentPagesAreReady {
                    // 保存位置所在章节及其相邻章节都为空时，继续向外寻找首个可显示章节。
                    stageIndexes = loadedIndexes.sorted()
                } else if adjacentPagesAreReady {
                    stageIndexes = adjacentIndexes
                } else {
                    stageIndexes = [focusedChapterIndex]
                }
                let stagePages = ReaderPaginationPlan.mergedPages(
                    chapterIndexes: stageIndexes,
                    pagesByChapter: pagesByChapter
                )
                guard !stagePages.isEmpty || isFinalStage else { continue }

                let isInitialStage = !didPublishInitialPages
                didPublishInitialPages = true
                if adjacentPagesAreReady {
                    didPublishAdjacentPages = true
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          generation == self.paginationGeneration,
                          !cancellationToken.isCancelled else { return }
                    let location = isInitialStage
                        ? normalizedInitialLocation
                        : self.currentReadingLocation ?? normalizedInitialLocation
                    self.applyPaginationStage(
                        stagePages,
                        descriptor: descriptor,
                        location: location,
                        isFinalStage: isFinalStage
                    )

                    if isInitialStage {
                        onInitialPagesReady?()
                    }

                    if isFinalStage {
                        DispatchQueue.global(qos: .utility).async {
                            PageCacheManager.shared.saveCache(
                                pages: stagePages,
                                for: bookId,
                                descriptor: descriptor
                            )
                        }
                    }
                }
            }
        }
    }

    private var currentReadingLocation: ReadingLocation? {
        guard let page = currentPage else { return nil }
        return ReadingLocation(
            chapterIndex: page.chapterIndex,
            contentOffset: page.contentOffset
        )
    }

    private func applyPaginationStage(
        _ newPages: [Page],
        descriptor: PageCacheDescriptor,
        location: ReadingLocation,
        isFinalStage: Bool
    ) {
        activePaginationDescriptor = descriptor
        isPreparingRemainingPages = !isFinalStage
        pages = newPages
        pagesVersion += 1

        if let pageIndex = ReaderPageLocator.pageIndex(
            containing: location.contentOffset,
            inChapter: location.chapterIndex,
            pages: pages
        ) {
            currentPageIndex = pageIndex
            currentChapterIndex = pages[pageIndex].chapterIndex
        } else {
            currentPageIndex = 0
            currentChapterIndex = pages.first?.chapterIndex ?? location.chapterIndex
        }

        updateProgress()
        isLoading = false
        checkCurrentPageBookmark()
        if isFinalStage, needsProgressRefreshWhenPaginationCompletes {
            needsProgressRefreshWhenPaginationCompletes = false
            saveProgress()
        }
    }

    /// 重新分页（字体设置变化时调用）
    func repaginate() {
        PageCacheManager.shared.clearCache(for: book.id)

        // 保存当前页面的 contentOffset 和章节索引，用于重分页后定位
        let location = currentReadingLocation ?? ReadingLocation(
            chapterIndex: currentChapterIndex,
            contentOffset: 0
        )
        paginateChapters(
            focusedAt: location.chapterIndex,
            initialLocation: location
        )
    }

    /// 上一章
    func previousChapter() {
        guard hasPreviousChapter else { return }
        let targetChapterIndex = currentChapterIndex - 1
        guard let chapterRange = ReaderPageLocator.chapterRange(targetChapterIndex, in: pages) else {
            currentChapterIndex = targetChapterIndex
            paginateChapters(
                focusedAt: targetChapterIndex,
                initialLocation: ReadingLocation(
                    chapterIndex: targetChapterIndex,
                    contentOffset: Int.max
                ),
                onInitialPagesReady: { [weak self] in self?.saveProgress() }
            )
            return
        }
        currentChapterIndex = targetChapterIndex

        // 跳转到上一章的最后一页（该章节中 contentOffset 最大的页面）
        currentPageIndex = chapterRange.upperBound - 1

        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }

    /// 下一章
    func nextChapter() {
        guard hasNextChapter else { return }
        let targetChapterIndex = currentChapterIndex + 1
        guard let chapterRange = ReaderPageLocator.chapterRange(targetChapterIndex, in: pages) else {
            currentChapterIndex = targetChapterIndex
            paginateChapters(
                focusedAt: targetChapterIndex,
                initialLocation: ReadingLocation(
                    chapterIndex: targetChapterIndex,
                    contentOffset: 0
                ),
                onInitialPagesReady: { [weak self] in self?.saveProgress() }
            )
            return
        }
        currentChapterIndex = targetChapterIndex

        // 跳转到下一章的第一页（该章节中 contentOffset 最小的页面）
        currentPageIndex = chapterRange.lowerBound

        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }

    /// 跳转到指定章节
    func jumpToChapter(_ index: Int) {
        guard index >= 0 && index < chapters.count else { return }
        currentChapterIndex = index

        // 跳转到该章节的第一页（contentOffset 最小的页面）
        guard let chapterRange = ReaderPageLocator.chapterRange(index, in: pages) else {
            paginateChapters(
                focusedAt: index,
                initialLocation: ReadingLocation(chapterIndex: index, contentOffset: 0),
                onInitialPagesReady: { [weak self] in self?.saveProgress() }
            )
            return
        }
        currentPageIndex = chapterRange.lowerBound

        updateProgress()
        saveProgress()
        checkCurrentPageBookmark()
    }

    /// 跳转到进度位置
    func jumpToProgress(_ progress: Double) {
        guard !pages.isEmpty, !isPreparingRemainingPages else { return }
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

        // 先记录待保存位置，避免退出或切后台时早于异步界面更新触发 flushProgress。
        saveProgress()

        // 使用 async 避免在视图更新期间发布状态变化。
        DispatchQueue.main.async { [weak self] in
            self?.updateProgress()
            self?.checkCurrentPageBookmark()
        }
    }

    /// 更新进度值
    private func updateProgress() {
        guard !pages.isEmpty else {
            readingProgress = 0
            return
        }
        if isPreparingRemainingPages,
           let page = currentPage,
           let chapter = chapters[safe: page.chapterIndex],
           !chapters.isEmpty {
            let chapterLength = max(1, (chapter.content as NSString).length)
            let chapterProgress = min(
                1,
                max(0, Double(page.contentOffset) / Double(chapterLength))
            )
            readingProgress = min(
                0.999,
                (Double(page.chapterIndex) + chapterProgress) / Double(chapters.count)
            )
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

    // MARK: - 听书功能

    /// 开始/停止听书
    func toggleSpeech() {
        if isSpeaking || isPaused {
            stopSpeech()
        } else {
            speakCurrentPage()
        }
    }

    /// 暂停/继续听书
    func togglePauseSpeech() {
        if isPaused {
            SpeechService.shared.resume()
        } else if isSpeaking {
            SpeechService.shared.pause()
        }
    }

    /// 朗读当前页内容
    private func speakCurrentPage() {
        guard let page = currentPage else { return }

        SpeechService.shared.speak(page.content) { [weak self] in
            guard let self = self else { return }

            // 如果还有下一页，自动翻页继续朗读
            let nextPageIndex = self.currentPageIndex + 1
            if nextPageIndex < self.pages.count {
                self.currentPageIndex = nextPageIndex
                self.updateProgressForPage(nextPageIndex)
                self.speakCurrentPage()
            } else {
                // 最后一页，停止朗读
                self.stopSpeech()
            }
        }
    }

    /// 停止听书
    func stopSpeech() {
        SpeechService.shared.stop()
        isSpeaking = false
        isPaused = false
    }

    // MARK: - 文本选择与批注

    var selectedText: String? {
        guard let selection = activeSelection,
              !selection.isEmpty,
              let chapter = chapters[safe: selection.chapterIndex] else {
            return nil
        }

        let content = chapter.content as NSString
        let range = NSIntersectionRange(
            selection.range,
            NSRange(location: 0, length: content.length)
        )
        guard range.length > 0 else { return nil }
        return content.substring(with: range)
    }

    var canHighlightSelection: Bool {
        guard let selection = activeSelection else { return false }
        return !uncoveredRanges(for: selection).isEmpty
    }

    var canAddThoughtToSelection: Bool {
        guard let selection = activeSelection else { return false }
        return annotationGroup(containing: selection)?.canAddThought ?? true
    }

    func beginSelection(chapterIndex: Int, contentOffset: Int) {
        guard let chapter = chapters[safe: chapterIndex] else { return }
        let contentLength = (chapter.content as NSString).length
        guard contentLength > 0 else { return }

        let initialRange = ReaderTextRangeMath.initialRange(
            in: chapter.content,
            utf16Offset: contentOffset
        )
        guard initialRange.length > 0 else { return }

        activeSelection = ReaderTextSelection(
            chapterIndex: chapterIndex,
            anchorOffset: initialRange.location,
            focusOffset: NSMaxRange(initialRange)
        )
        showToolbar = false
        showSelectionActions = false
    }

    func updateSelectionFocus(chapterIndex: Int, contentOffset: Int) {
        guard var selection = activeSelection,
              selection.chapterIndex == chapterIndex,
              let chapter = chapters[safe: chapterIndex] else {
            return
        }

        let contentLength = (chapter.content as NSString).length
        let clampedOffset = min(max(contentOffset, 0), contentLength)
        selection.focusOffset = ReaderTextRangeMath.composedCharacterBoundary(
            in: chapter.content,
            utf16Offset: clampedOffset,
            preferUpperBoundary: clampedOffset >= selection.anchorOffset
        )
        activeSelection = selection
    }

    func updateSelectionStart(chapterIndex: Int, contentOffset: Int) {
        guard let selection = activeSelection,
              selection.chapterIndex == chapterIndex,
              let chapter = chapters[safe: chapterIndex] else {
            return
        }

        let end = selection.upperBound
        let requestedStart = min(max(contentOffset, 0), max(0, end - 1))
        let start = ReaderTextRangeMath.composedCharacterBoundary(
            in: chapter.content,
            utf16Offset: requestedStart,
            preferUpperBoundary: false
        )
        activeSelection = ReaderTextSelection(
            chapterIndex: chapterIndex,
            anchorOffset: start,
            focusOffset: end
        )
    }

    func updateSelectionEnd(chapterIndex: Int, contentOffset: Int) {
        guard let selection = activeSelection,
              selection.chapterIndex == chapterIndex,
              let chapter = chapters[safe: chapterIndex] else {
            return
        }

        let contentLength = (chapter.content as NSString).length
        let start = selection.lowerBound
        let requestedEnd = max(min(contentOffset, contentLength), min(contentLength, start + 1))
        let end = ReaderTextRangeMath.composedCharacterBoundary(
            in: chapter.content,
            utf16Offset: requestedEnd,
            preferUpperBoundary: true
        )
        activeSelection = ReaderTextSelection(
            chapterIndex: chapterIndex,
            anchorOffset: start,
            focusOffset: end
        )
    }

    func finishSelection() {
        guard activeSelection?.isEmpty == false else {
            cancelSelection()
            return
        }
        showSelectionActions = true
    }

    func cancelSelection() {
        activeSelection = nil
        showSelectionActions = false
        showCommentComposer = false
        commentDraft = ""
        isSavingSelection = false
    }

    func beginWritingComment() {
        guard activeSelection?.isEmpty == false else { return }
        guard canAddThoughtToSelection else {
            bookmarkAlert = BookmarkAlert(
                title: "想法数量已达上限",
                message: "每段划线最多可以保存 \(ReaderAnnotationGroup.maximumThoughtCount) 条想法"
            )
            return
        }
        commentDraft = ""
        showSelectionActions = false
        showCommentComposer = true
    }

    func cancelWritingComment() {
        showCommentComposer = false
        showSelectionActions = activeSelection?.isEmpty == false
    }

    func copySelection() {
        guard let selectedText else { return }
        UIPasteboard.general.string = selectedText
        cancelSelection()
    }

    func saveSelectionAsHighlight() {
        guard let selection = activeSelection else { return }
        let ranges = uncoveredRanges(for: selection)
        guard !ranges.isEmpty else { return }
        persistActiveSelection(type: .highlight, note: nil, ranges: ranges)
    }

    func saveSelectionComment() {
        let note = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, let selection = activeSelection else { return }

        if let group = annotationGroup(containing: selection) {
            guard group.canAddThought else {
                bookmarkAlert = BookmarkAlert(
                    title: "想法数量已达上限",
                    message: "每段划线最多可以保存 \(ReaderAnnotationGroup.maximumThoughtCount) 条想法"
                )
                return
            }
            persistActiveSelection(type: .note, note: note, ranges: [group.key.range])
        } else {
            persistActiveSelection(type: .note, note: note)
        }
    }

    func selectionMarks(for page: Page) -> [ReaderTextMark] {
        let pageLength = (page.content as NSString).length
        let persistedMarks = readerAnnotations.compactMap { bookmark -> ReaderTextMark? in
            guard bookmark.chapterIndex == page.chapterIndex,
                  bookmark.length > 0,
                  let localRange = ReaderTextRangeMath.localIntersection(
                    selectionRange: NSRange(location: bookmark.location, length: bookmark.length),
                    pageOffset: page.contentOffset,
                    pageLength: pageLength
                  ) else {
                return nil
            }

            return ReaderTextMark(
                range: localRange,
                style: bookmark.type == .note ? .note : .highlight
            )
        }

        return ReaderTextRangeMath.resolvedMarks(
            pageLength: pageLength,
            persistedMarks: persistedMarks,
            activeRange: activeSelection?.localRange(in: page)
        )
    }

    private func uncoveredRanges(for selection: ReaderTextSelection) -> [NSRange] {
        guard let chapter = chapters[safe: selection.chapterIndex] else { return [] }
        let coveredRanges = readerAnnotations.compactMap { annotation -> NSRange? in
            guard annotation.chapterIndex == selection.chapterIndex,
                  annotation.length > 0 else {
                return nil
            }
            return NSRange(location: annotation.location, length: annotation.length)
        }
        return ReaderTextRangeMath.uncoveredRanges(
            in: selection.range,
            coveredRanges: coveredRanges
        )
        .compactMap {
            ReaderTextRangeMath.trimmingLineWhitespace(in: chapter.content, range: $0)
        }
    }

    private func persistActiveSelection(
        type: BookmarkType,
        note: String?,
        ranges: [NSRange]? = nil
    ) {
        guard let selection = activeSelection,
              !selection.isEmpty,
              let chapter = chapters[safe: selection.chapterIndex] else {
            return
        }

        let content = chapter.content as NSString
        let rangesToSave = ranges ?? [selection.range]
        let annotations = rangesToSave.compactMap { range -> Bookmark? in
            let validRange = NSIntersectionRange(
                range,
                NSRange(location: 0, length: content.length)
            )
            guard validRange.length > 0 else { return nil }
            return Bookmark(
                bookId: book.id,
                chapterIndex: selection.chapterIndex,
                location: validRange.location,
                length: validRange.length,
                type: type,
                note: note,
                selectedText: content.substring(with: validRange)
            )
        }
        guard !annotations.isEmpty else { return }

        isSavingSelection = true
        let savePublishers = annotations.map { bookmarkRepository.addBookmark($0) }
        Publishers.MergeMany(savePublishers)
            .collect()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    self.isSavingSelection = false
                    if case .failure(let error) = completion {
                        self.showCommentComposer = false
                        self.showSelectionActions = true
                        self.presentOperationError(title: "批注保存失败", error: error)
                        self.loadBookmarks()
                    }
                },
                receiveValue: { [weak self] savedAnnotations in
                    guard let self else { return }
                    self.currentBookmarks.append(contentsOf: savedAnnotations)
                    self.refreshBookmarkState()
                    self.cancelSelection()
                }
            )
            .store(in: &cancellables)
    }

    private func refreshBookmarkState() {
        readerAnnotations = currentBookmarks.filter {
            ($0.type == .highlight || $0.type == .note) && $0.length > 0
        }
        bookmarkList = currentBookmarks
            .filter { $0.type == .bookmark }
            .sorted { $0.createdAt > $1.createdAt }
        if let key = presentedAnnotationKey, annotationGroup(for: key) == nil {
            presentedAnnotationKey = nil
        }
    }

    // MARK: - 划线详情与想法

    var annotationGroups: [ReaderAnnotationGroup] {
        ReaderAnnotationGroup.groups(from: currentBookmarks)
    }

    func annotationGroup(for key: ReaderAnnotationKey) -> ReaderAnnotationGroup? {
        annotationGroups.first { $0.key == key }
    }

    @discardableResult
    func openAnnotation(chapterIndex: Int, contentOffset: Int) -> Bool {
        guard let group = annotationGroups
            .filter({
                $0.key.chapterIndex == chapterIndex
                    && $0.key.contains(utf16Offset: contentOffset)
            })
            .sorted(by: {
                if $0.key.length == $1.key.length {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.key.length < $1.key.length
            })
            .first else {
            return false
        }

        presentedAnnotationKey = group.key
        showToolbar = false
        return true
    }

    func closePresentedAnnotation() {
        presentedAnnotationKey = nil
    }

    func addThought(to key: ReaderAnnotationKey, text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSavingAnnotationThought,
              !note.isEmpty,
              let group = annotationGroup(for: key),
              group.canAddThought else {
            if annotationGroup(for: key)?.canAddThought == false {
                bookmarkAlert = BookmarkAlert(
                    title: "想法数量已达上限",
                    message: "每段划线最多可以保存 \(ReaderAnnotationGroup.maximumThoughtCount) 条想法"
                )
            }
            return
        }

        let thought = Bookmark(
            bookId: key.bookId,
            chapterIndex: key.chapterIndex,
            location: key.location,
            length: key.length,
            type: .note,
            note: note,
            selectedText: sourceText(for: group)
        )
        isSavingAnnotationThought = true
        bookmarkRepository.addBookmark(thought)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    self.isSavingAnnotationThought = false
                    if case .failure(let error) = completion {
                        self.presentOperationError(title: "想法保存失败", error: error)
                    }
                },
                receiveValue: { [weak self] savedThought in
                    self?.currentBookmarks.append(savedThought)
                    self?.refreshBookmarkState()
                }
            )
            .store(in: &cancellables)
    }

    func updateThought(_ thought: Bookmark, text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSavingAnnotationThought,
              !note.isEmpty,
              thought.type == .note,
              let index = currentBookmarks.firstIndex(where: { $0.id == thought.id }) else {
            return
        }

        var updatedThought = currentBookmarks[index]
        updatedThought.note = note
        updatedThought.updatedAt = Date()
        isSavingAnnotationThought = true
        bookmarkRepository.updateBookmark(updatedThought)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    self.isSavingAnnotationThought = false
                    if case .failure(let error) = completion {
                        self.presentOperationError(title: "想法更新失败", error: error)
                    }
                },
                receiveValue: { [weak self] savedThought in
                    guard let self,
                          let savedIndex = self.currentBookmarks.firstIndex(where: {
                              $0.id == savedThought.id
                          }) else {
                        return
                    }
                    self.currentBookmarks[savedIndex] = savedThought
                    self.refreshBookmarkState()
                }
            )
            .store(in: &cancellables)
    }

    func deleteThought(_ thought: Bookmark) {
        guard !isSavingAnnotationThought, thought.type == .note else { return }
        isSavingAnnotationThought = true
        bookmarkRepository.deleteBookmark(byId: thought.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    self.isSavingAnnotationThought = false
                    if case .failure(let error) = completion {
                        self.presentOperationError(title: "想法删除失败", error: error)
                    }
                },
                receiveValue: { [weak self] _ in
                    self?.currentBookmarks.removeAll { $0.id == thought.id }
                    self?.refreshBookmarkState()
                }
            )
            .store(in: &cancellables)
    }

    func deleteAnnotation(for key: ReaderAnnotationKey) {
        guard !isDeletingAnnotation,
              !isSavingAnnotationThought,
              let group = annotationGroup(for: key) else { return }

        let ids = group.records.map(\.id)
        let idSet = Set(ids)
        isDeletingAnnotation = true
        bookmarkRepository.deleteBookmarks(byIds: ids)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    self.isDeletingAnnotation = false
                    if case .failure(let error) = completion {
                        self.presentOperationError(title: "划线删除失败", error: error)
                    }
                },
                receiveValue: { [weak self] _ in
                    self?.currentBookmarks.removeAll { idSet.contains($0.id) }
                    self?.refreshBookmarkState()
                }
            )
            .store(in: &cancellables)
    }

    private func annotationGroup(containing selection: ReaderTextSelection) -> ReaderAnnotationGroup? {
        annotationGroups
            .filter {
                $0.key.chapterIndex == selection.chapterIndex
                    && $0.key.location <= selection.lowerBound
                    && NSMaxRange($0.key.range) >= selection.upperBound
            }
            .min { $0.key.length < $1.key.length }
    }

    private func sourceText(for group: ReaderAnnotationGroup) -> String {
        if !group.selectedText.isEmpty {
            return group.selectedText
        }
        guard let chapter = chapters[safe: group.key.chapterIndex] else { return "" }
        let content = chapter.content as NSString
        let range = NSIntersectionRange(
            group.key.range,
            NSRange(location: 0, length: content.length)
        )
        return range.length > 0 ? content.substring(with: range) : ""
    }

    /// 保存阅读进度
    private func saveProgress() {
        guard let page = currentPage else { return }
        if isPreparingRemainingPages {
            needsProgressRefreshWhenPaginationCompletes = true
        }

        pendingProgressSave = ProgressSnapshot(
            chapterIndex: currentChapterIndex,
            contentOffset: page.contentOffset,
            isCompleted: !isPreparingRemainingPages && currentPageIndex == pages.count - 1
        )
        progressSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushProgress()
        }
        progressSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    /// 退出阅读器或应用进入后台时立即提交最后一个阅读位置。
    func flushProgress() {
        progressSaveWorkItem?.cancel()
        progressSaveWorkItem = nil
        guard let snapshot = pendingProgressSave else { return }
        pendingProgressSave = nil

        progressSaveCancellable?.cancel()
        progressSaveCancellable = saveProgressUseCase.execute(
            bookId: book.id,
            chapterIndex: snapshot.chapterIndex,
            contentOffset: snapshot.contentOffset,
            isCompleted: snapshot.isCompleted
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { [weak self] completion in
                if case .failure(let error) = completion {
                    guard let self else { return }
                    if self.pendingProgressSave == nil {
                        self.pendingProgressSave = snapshot
                    }
                    self.presentOperationError(title: "进度保存失败", error: error)
                }
            },
            receiveValue: { _ in }
        )
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
                        self?.refreshBookmarkState()
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
        bookmarkList = currentBookmarks
            .filter { $0.type == .bookmark }
            .sorted { $0.createdAt > $1.createdAt }
        showBookmarkList = true
    }

    /// 跳转到书签所在章节
    func jumpToBookmark(_ bookmark: Bookmark) {
        guard bookmark.type == .bookmark else { return }
        if let pageIndex = ReaderPageLocator.pageIndex(
            containing: bookmark.location,
            inChapter: bookmark.chapterIndex,
            pages: pages
        ) {
            currentPageIndex = pageIndex
            currentChapterIndex = pages[pageIndex].chapterIndex
            updateProgress()
            saveProgress()
            checkCurrentPageBookmark()
        } else if chapters.indices.contains(bookmark.chapterIndex) {
            currentChapterIndex = bookmark.chapterIndex
            paginateChapters(
                focusedAt: bookmark.chapterIndex,
                initialLocation: ReadingLocation(
                    chapterIndex: bookmark.chapterIndex,
                    contentOffset: bookmark.location
                ),
                onInitialPagesReady: { [weak self] in self?.saveProgress() }
            )
        }
        showBookmarkList = false
    }

    /// 删除书签
    func deleteBookmark(_ bookmark: Bookmark) {
        guard bookmark.type == .bookmark else { return }
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
                    self?.refreshBookmarkState()
                    self?.checkCurrentPageBookmark()
                }
            )
            .store(in: &cancellables)
    }

    private func bookmarkOnCurrentPage() -> Bookmark? {
        guard let page = currentPage else { return nil }
        let nextOffset = ReaderPageLocator.nextContentOffset(
            after: currentPageIndex,
            in: pages
        ) ?? Int.max

        return currentBookmarks.first {
            $0.type == .bookmark
                && $0.chapterIndex == page.chapterIndex
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
