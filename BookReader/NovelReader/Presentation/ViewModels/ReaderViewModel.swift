import Foundation
import Combine
import SwiftUI
import UIKit
import CoreText

/// 页面数据 - 流式排版，全局连续索引
struct Page: Identifiable {
    let id = UUID()
    let globalIndex: Int          // 全书唯一索引（0, 1, 2, ...）
    let content: String           // 页面文本内容
    let chapterIndex: Int         // 所属章节索引
    let chapterTitle: String      // 章节标题
    let isChapterStart: Bool      // 是否是章节第一页
    let contentOffset: Int        // 在章节内容中的字符偏移量（用于章节跳转定位）
}

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
    
    /// 实际可用的视图高度（由 ReaderView 通过 GeometryReader 传入）
    /// 这是安全区域内的高度，已扣除状态栏和底部安全区域
    private var availableViewHeight: CGFloat?
    
    /// 获取可用视图高度，如果尚未设置则回退到屏幕高度减去安全区域估算值
    private var effectiveViewHeight: CGFloat {
        if let height = availableViewHeight {
            return height
        }
        // 回退：使用屏幕高度减去安全区域的估算值
        // 顶部状态栏约 47pt（刘海屏）或 20pt（非刘海屏），底部 Home Indicator 约 34pt
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let topInset = windowScene?.windows.first?.safeAreaInsets.top ?? 47
        let bottomInset = windowScene?.windows.first?.safeAreaInsets.bottom ?? 34
        return UIScreen.main.bounds.height - topInset - bottomInset
    }
    
    private let bookRepository: BookRepositoryProtocol
    private let chapterRepository: ChapterRepositoryProtocol
    private let bookmarkRepository: BookmarkRepositoryProtocol
    private let txtParser = TXTParser()
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
        bookmarkRepository: BookmarkRepositoryProtocol = BookmarkRepository()
    ) {
        self.book = book
        self.bookRepository = bookRepository
        self.chapterRepository = chapterRepository
        self.bookmarkRepository = bookmarkRepository
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
    }
    
    /// 设置实际可用的视图高度（由 ReaderView 调用）
    func setAvailableViewHeight(_ height: CGFloat) {
        let oldHeight = availableViewHeight
        availableViewHeight = height
        // 如果高度发生了显著变化（>1pt），需要重新分页
        if let old = oldHeight, abs(old - height) > 1, !pages.isEmpty {
            // 保存当前阅读位置（章节索引和 contentOffset）
            let savedContentOffset = currentPage?.contentOffset ?? 0
            let savedChapterIndex = currentChapterIndex
            
            PageCacheManager.shared.clearCache(for: book.id)
            paginateAllChapters()
            
            // 重分页后，恢复到之前的阅读位置
            if !pages.isEmpty {
                let chapterPages = pages.filter { $0.chapterIndex == savedChapterIndex }
                if let targetPage = chapterPages.min(by: { abs($0.contentOffset - savedContentOffset) < abs($1.contentOffset - savedContentOffset) }),
                   let pageIndex = pages.firstIndex(where: { $0.globalIndex == targetPage.globalIndex }) {
                    currentPageIndex = pageIndex
                    currentChapterIndex = savedChapterIndex
                }
                updateProgress()
                objectWillChange.send()
            }
        }
    }
    
    /// 加载书籍内容
    func loadBook() {
        isLoading = true
        
        // 先从数据库获取最新的阅读进度（解决 book 对象快照过时问题）
        bookRepository.getBook(byId: book.id)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] latestBook in
                guard let self = self else { return }
                if let latestBook = latestBook {
                    self.savedChapterIndex = latestBook.lastReadChapterIndex
                    self.savedContentOffset = latestBook.lastReadContentOffset
                }
                self.continueLoadBook()
            }
            .store(in: &cancellables)
    }
    
    /// loadBook 的后续逻辑（获取最新进度后执行）
    private func continueLoadBook() {
        
        // 先检查页面缓存
        if let cachedPages = PageCacheManager.shared.loadCache(for: book.id, expectedViewHeight: effectiveViewHeight) {
            print("Loaded \(cachedPages.count) pages from cache")
            self.pages = cachedPages
            
            // 加载章节信息（用于目录）
            loadChaptersForCatalog()
            
            // 加载书签
            loadBookmarks()
            
            // 跳转到保存的位置（此时 isLoading 仍为 true，跳转完成后设为 false）
            jumpToSavedPosition()
            return
        }
        
        // 没有缓存，从数据库或文件加载
        chapterRepository.getChapters(forBookId: book.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = error as? BookError ?? .parseFailed
                        self?.isLoading = false
                    }
                },
                receiveValue: { [weak self] chapters in
                    if chapters.isEmpty {
                        self?.parseBookFile()
                    } else {
                        self?.chapters = chapters
                        self?.loadBookmarks()
                        // 等待分页完成后再跳转
                        self?.paginateAllChapters {
                            self?.jumpToSavedPosition()
                        }
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    /// 加载章节信息（用于目录显示）
    private func loadChaptersForCatalog() {
        chapterRepository.getChapters(forBookId: book.id)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] chapters in
                self?.chapters = chapters
            }
            .store(in: &cancellables)
    }
    
    /// 跳转到保存的阅读位置
    private func jumpToSavedPosition() {
        let targetChapter = savedChapterIndex
        let targetContentOffset = savedContentOffset
        
        // 找到对应章节的页面
        let chapterPages = pages.filter { $0.chapterIndex == targetChapter }
        guard !chapterPages.isEmpty else {
            currentPageIndex = 0
            isLoading = false
            checkCurrentPageBookmark()
            return
        }
        
        // 根据 contentOffset 找到最接近的页面
        if let targetPage = chapterPages.min(by: { page1, page2 in
            abs(page1.contentOffset - targetContentOffset) < abs(page2.contentOffset - targetContentOffset)
        }),
           let globalIndex = pages.firstIndex(where: { $0.globalIndex == targetPage.globalIndex }) {
            currentPageIndex = globalIndex
            currentChapterIndex = targetChapter
        } else {
            // 回退到章节第一页
            if let firstPage = chapterPages.min(by: { $0.contentOffset < $1.contentOffset }),
               let globalIndex = pages.firstIndex(where: { $0.globalIndex == firstPage.globalIndex }) {
                currentPageIndex = globalIndex
                currentChapterIndex = targetChapter
            } else {
                currentPageIndex = 0
            }
        }
        
        updateProgress()
        isLoading = false
        checkCurrentPageBookmark()
    }
    
    /// 加载书签
    private func loadBookmarks() {
        bookmarkRepository.getBookmarks(forBookId: book.id)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] bookmarks in
                self?.currentBookmarks = bookmarks
                self?.checkCurrentPageBookmark()
            }
            .store(in: &cancellables)
    }
    
    /// 解析书籍文件
    private func parseBookFile() {
        let fileURL = URL(fileURLWithPath: book.filePath)
        
        do {
            let parsedBook = try txtParser.parse(fileURL: fileURL)
            
            let chapters = parsedBook.chapters.map { parsedChapter in
                Chapter(
                    index: parsedChapter.index,
                    title: parsedChapter.title,
                    content: parsedChapter.content,
                    startLocation: parsedChapter.startLocation,
                    length: parsedChapter.length
                )
            }
            
            self.chapters = chapters
            
            chapterRepository.saveChapters(chapters, forBookId: book.id)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { [weak self] _ in
                        self?.loadBookmarks()
                        self?.paginateAllChapters()
                        self?.jumpToSavedPosition()
                    }
                )
                .store(in: &cancellables)
            
        } catch {
            self.error = error as? BookError ?? .parseFailed
            self.isLoading = false
        }
    }
    
    /// 对所有章节进行统一分页（在后台线程执行，避免阻塞UI）
    private func paginateAllChapters(completion: (() -> Void)? = nil) {
        guard !chapters.isEmpty else {
            pages = []
            completion?()
            return
        }
        
        // 获取实际可用的视图高度（安全区域内的高度）
        let viewHeight = effectiveViewHeight
        let screenWidth = UIScreen.main.bounds.width - 40 // 左右各20边距
        
        // 计算实际可用于文本内容的高度
        // PageContentView 布局（VStack spacing: 0）：
        //   章节标题: padding.top(8) + caption(~11pt) ≈ 19pt
        //   内容区域: 占据剩余空间
        //   页码: caption2(~10pt) + padding.bottom(12) ≈ 22pt
        let contentTopPadding: CGFloat = 10
        let pageBottomReserved: CGFloat = 22
        let chapterTitleHeight: CGFloat = 19
        
        let nonFirstPageHeight = viewHeight - contentTopPadding - pageBottomReserved
        let firstPageHeight = viewHeight - chapterTitleHeight - contentTopPadding - pageBottomReserved
        
        let chaptersCopy = self.chapters
        let bookId = self.book.id
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var allPages: [Page] = []
            var globalIndex = 0
            
            for (chapterIndex, chapter) in chaptersCopy.enumerated() {
                let chapterPages = self.paginateChapter(
                    chapter,
                    chapterIndex: chapterIndex,
                    pageWidth: screenWidth,
                    firstPageHeight: firstPageHeight,
                    normalPageHeight: nonFirstPageHeight,
                    startingGlobalIndex: globalIndex
                )
                allPages.append(contentsOf: chapterPages)
                globalIndex += chapterPages.count
            }
            
            DispatchQueue.main.async {
                self.pages = allPages
                
                // 保存到缓存
                PageCacheManager.shared.saveCache(pages: allPages, for: bookId, viewHeight: viewHeight)
                
                // 调用完成回调
                completion?()
            }
        }
    }
    
    /// 对单个章节分页 - 使用 Core Text CTFramesetter 逐页建议大小分页
    /// - Parameters:
    ///   - chapter: 章节数据
    ///   - chapterIndex: 章节索引
    ///   - pageWidth: 页面内容宽度（已扣除左右边距）
    ///   - firstPageHeight: 首页可用内容高度（已扣除章节标题、padding、页码）
    ///   - normalPageHeight: 非首页可用内容高度（已扣除padding、页码）
    ///   - startingGlobalIndex: 起始全局索引
    private func paginateChapter(_ chapter: Chapter, chapterIndex: Int, pageWidth: CGFloat, firstPageHeight: CGFloat, normalPageHeight: CGFloat, startingGlobalIndex: Int) -> [Page] {
        guard !chapter.content.isEmpty else { return [] }
        
        let contentNSString = chapter.content as NSString
        let contentLength = contentNSString.length
        
        // 构建 Core Text 属性字符串
        let font = UIFont.systemFont(ofSize: ThemeService.shared.fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = ThemeService.shared.lineSpacing
        paragraphStyle.paragraphSpacing = ThemeService.shared.paragraphSpacing
        paragraphStyle.alignment = .justified
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        
        let attrString = NSMutableAttributedString(string: chapter.content, attributes: attributes)
        let cfAttrString = attrString as CFAttributedString
        let framesetter = CTFramesetterCreateWithAttributedString(cfAttrString)
        
        var chapterPages: [Page] = []
        var globalIndex = startingGlobalIndex
        var isFirstPage = true
        let maxPages = 500
        
        var currentOffset = 0
        
        while currentOffset < contentLength && chapterPages.count < maxPages {
            // 首页和非首页使用不同的可用高度
            let availableHeight = isFirstPage ? firstPageHeight : normalPageHeight
            let pageSize = CGSize(width: pageWidth, height: availableHeight)
            let pagePath = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
            
            let remainingLength = contentLength - currentOffset
            
            // 创建一个 Frame，范围是"从当前位置到结尾"
            // Core Text 会根据 pagePath 自动截断，只渲染能放下的部分
            let frameRange = CFRange(location: currentOffset, length: remainingLength)
            let frame = CTFramesetterCreateFrame(framesetter, frameRange, pagePath, nil)
            
            let lines = CTFrameGetLines(frame) as! [CTLine]
            let lineCount = lines.count
            guard lineCount > 0 else {
                currentOffset += 1
                continue
            }
            
            // 获取所有行的 Y 坐标，找出哪些行完全在页面内
            var lineOrigins = [CGPoint](repeating: .zero, count: lineCount)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lineCount), &lineOrigins)
            
            // Core Text 坐标系：Y 从底部向上（Quartz 惯例）
            // 行从顶部到底部排列（Y 递减）：lineOrigins[0] 的 y 最大（顶部），lineOrigins[last] 的 y 最小（底部）
            var lastFullyVisibleIndex = lineCount - 1
            for i in stride(from: lineCount - 1, through: 0, by: -1) {
                let line = lines[i]
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let lineTop = lineOrigins[i].y + ascent
                let lineBottom = lineOrigins[i].y - descent
                // 行完全可见的条件：顶部在页面内 AND 底部在页面内
                // 使用很小的容差值（0.5）来避免浮点数精度问题
                if lineTop <= availableHeight + 0.5 && lineBottom >= -0.5 {
                    lastFullyVisibleIndex = i
                    break
                }
            }
            
            if lastFullyVisibleIndex < 0 {
                currentOffset += 1
                continue
            }
            
            // 获取最后完全可见行的字符范围
            let lastVisibleLine = lines[lastFullyVisibleIndex]
            let lastLineRange = CTLineGetStringRange(lastVisibleLine)
            let charsInPage = max(1, min((lastLineRange.location + lastLineRange.length) - currentOffset, remainingLength))
            
            let pageRange = NSRange(location: currentOffset, length: charsInPage)
            let pageContent = contentNSString.substring(with: pageRange)
            
            // 只有当页面内容非空时才添加页面
            if !pageContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapterPages.append(Page(
                    globalIndex: globalIndex,
                    content: pageContent,
                    chapterIndex: chapterIndex,
                    chapterTitle: chapter.title,
                    isChapterStart: isFirstPage,
                    contentOffset: currentOffset
                ))
                globalIndex += 1
                isFirstPage = false
            }
            
            // 更新偏移量
            currentOffset += charsInPage
            
            // 如果已经到达章节末尾，退出
            if currentOffset >= contentLength {
                break
            }
        }
        
        // 如果分页失败（例如一页都没生成），整章作为一页
        if chapterPages.isEmpty {
            chapterPages.append(Page(
                globalIndex: startingGlobalIndex,
                content: chapter.content,
                chapterIndex: chapterIndex,
                chapterTitle: chapter.title,
                isChapterStart: true,
                contentOffset: 0
            ))
        }
        
        return chapterPages
    }
    
    /// 重新分页（字体设置变化时调用）
    func repaginate() {
        PageCacheManager.shared.clearCache(for: book.id)
        
        // 保存当前页面的 contentOffset 和章节索引，用于重分页后定位
        let savedContentOffset = currentPage?.contentOffset ?? 0
        let savedChapterIndex = currentChapterIndex
        
        let chaptersCopy = self.chapters
        let bookId = self.book.id
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let computedPages = self.computeAllPages(chapters: chaptersCopy, bookId: bookId)
            
            DispatchQueue.main.async {
                self.pages = computedPages
                self.pagesVersion += 1
                
                // 重分页后，根据之前保存的 contentOffset 找到新分页中对应的页面
                if !computedPages.isEmpty {
                    // 首先尝试在相同章节中找到最接近的 contentOffset
                    let chapterPages = computedPages.filter { $0.chapterIndex == savedChapterIndex }
                    if let targetPage = chapterPages.min(by: { abs($0.contentOffset - savedContentOffset) < abs($1.contentOffset - savedContentOffset) }),
                       let pageIndex = computedPages.firstIndex(where: { $0.globalIndex == targetPage.globalIndex }) {
                        self.currentPageIndex = pageIndex
                        self.currentChapterIndex = savedChapterIndex
                    } else {
                        // 如果找不到，跳转到该章节的第一页
                        if let firstPageOfChapter = computedPages.first(where: { $0.chapterIndex == savedChapterIndex }),
                           let pageIndex = computedPages.firstIndex(where: { $0.globalIndex == firstPageOfChapter.globalIndex }) {
                            self.currentPageIndex = pageIndex
                            self.currentChapterIndex = savedChapterIndex
                        } else {
                            self.currentPageIndex = 0
                            self.currentChapterIndex = 0
                        }
                    }
                    self.updateProgress()
                    self.checkCurrentPageBookmark()
                }
                // 强制刷新，确保页码和页面内容更新
                self.objectWillChange.send()
            }
        }
    }
    
    /// 纯计算方法：对所有章节分页（可在后台线程调用）
    private func computeAllPages(chapters: [Chapter], bookId: UUID) -> [Page] {
        guard !chapters.isEmpty else { return [] }
        
        let viewHeight = effectiveViewHeight
        let screenWidth = UIScreen.main.bounds.width - 40
        
        // 与 paginateAllChapters 保持一致的高度计算
        let contentTopPadding: CGFloat = 10
        let pageBottomReserved: CGFloat = 18
        let chapterTitleHeight: CGFloat = 53
        
        let nonFirstPageHeight = viewHeight - contentTopPadding - pageBottomReserved
        let firstPageHeight = viewHeight - chapterTitleHeight - contentTopPadding - pageBottomReserved
        
        var allPages: [Page] = []
        var globalIndex = 0
        
        for (chapterIndex, chapter) in chapters.enumerated() {
            let chapterPages = paginateChapter(
                chapter,
                chapterIndex: chapterIndex,
                pageWidth: screenWidth,
                firstPageHeight: firstPageHeight,
                normalPageHeight: nonFirstPageHeight,
                startingGlobalIndex: globalIndex
            )
            allPages.append(contentsOf: chapterPages)
            globalIndex += chapterPages.count
        }
        
        // 保存到缓存
        PageCacheManager.shared.saveCache(pages: allPages, for: bookId, viewHeight: effectiveViewHeight)
        
        return allPages
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
        bookRepository.updateReadingProgress(
            bookId: book.id,
            chapterIndex: currentChapterIndex,
            contentOffset: page.contentOffset
        )
        .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        .store(in: &cancellables)
    }
    
    // MARK: - 书签功能
    
    private func checkCurrentPageBookmark() {
        guard let page = currentPage else {
            isCurrentPageBookmarked = false
            return
        }
        
        isCurrentPageBookmarked = currentBookmarks.contains { bookmark in
            bookmark.chapterIndex == page.chapterIndex
        }
    }
    
    func toggleBookmark() {
        guard let page = currentPage else { return }
        
        if let existingBookmark = currentBookmarks.first(where: { $0.chapterIndex == page.chapterIndex }) {
            bookmarkRepository.deleteBookmark(byId: existingBookmark.id)
                .receive(on: DispatchQueue.main)
                .sink { _ in } receiveValue: { [weak self] _ in
                    self?.loadBookmarks()
                    self?.bookmarkAlert = BookmarkAlert(
                        title: "书签已删除",
                        message: "\(page.chapterTitle) 的书签已删除"
                    )
                }
                .store(in: &cancellables)
        } else {
            let bookmark = Bookmark(
                bookId: book.id,
                chapterIndex: page.chapterIndex,
                location: 0,
                type: .bookmark,
                selectedText: String(page.content.prefix(50))
            )
            
            bookmarkRepository.addBookmark(bookmark)
                .receive(on: DispatchQueue.main)
                .sink { _ in } receiveValue: { [weak self] _ in
                    self?.loadBookmarks()
                    self?.bookmarkAlert = BookmarkAlert(
                        title: "书签已添加",
                        message: "\(page.chapterTitle) 已添加书签"
                    )
                }
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
        jumpToChapter(bookmark.chapterIndex)
        showBookmarkList = false
    }
    
    /// 删除书签
    func deleteBookmark(_ bookmark: Bookmark) {
        bookmarkRepository.deleteBookmark(byId: bookmark.id)
            .receive(on: DispatchQueue.main)
            .sink { _ in } receiveValue: { [weak self] _ in
                self?.loadBookmarks()
                self?.bookmarkList = self?.currentBookmarks.sorted { $0.createdAt > $1.createdAt } ?? []
            }
            .store(in: &cancellables)
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
