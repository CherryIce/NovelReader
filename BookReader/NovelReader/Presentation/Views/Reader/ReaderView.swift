import SwiftUI
import UIKit

struct ReaderView: View {
    @ObservedObject private var viewModel: ReaderViewModel
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject private var themeService = ThemeService.shared
    @ObservedObject private var speechService = SpeechService.shared
    
    init(book: Book) {
        self.viewModel = ReaderViewModel(book: book)
    }
    
    var body: some View {
        ZStack {
            // 背景层 - 延伸到安全区域
            themeService.currentTheme.backgroundColor
                .edgesIgnoringSafeArea(.all)
            
            // 内容层 - 始终占满全屏
            contentLayer
            
            // 工具栏层 - 覆盖在内容上方
            if viewModel.showToolbar {
                toolbarLayer
                    .transition(.opacity)
            }
        }
        .statusBar(hidden: !viewModel.showToolbar)
        .navigationBarHidden(true)
        .sheet(isPresented: $viewModel.showCatalog) {
            CatalogView(
                chapters: viewModel.chapters,
                currentIndex: viewModel.currentChapterIndex,
                onSelect: { index in
                    viewModel.jumpToChapter(index)
                    viewModel.showCatalog = false
                }
            )
        }
        .sheet(isPresented: $viewModel.showSettings) {
            ReaderSettingsView()
        }
        .alert(item: $viewModel.bookmarkAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("确定"))
            )
        }
        .sheet(isPresented: $viewModel.showBookmarkList) {
            BookmarkListView(
                bookmarks: viewModel.bookmarkList,
                chapters: viewModel.chapters,
                onSelect: { bookmark in
                    viewModel.jumpToBookmark(bookmark)
                },
                onDelete: { bookmark in
                    viewModel.deleteBookmark(bookmark)
                }
            )
        }
        .onAppear {
            viewModel.loadBook()
        }
    }
    
    // MARK: - 内容层
    
    @ViewBuilder
    private var contentLayer: some View {
        if viewModel.isLoading {
            loadingView
        } else if let error = viewModel.error {
            errorView(error: error)
        } else if viewModel.pages.isEmpty {
            emptyView
        } else {
            readerContent
        }
    }
    
    private var loadingView: some View {
        ZStack {
            themeService.currentTheme.backgroundColor
                .edgesIgnoringSafeArea(.all)
            VStack(spacing: 16) {
                ActivityIndicator(isAnimating: true, style: .large)
                    .scaleEffect(1.5)
                Text("正在加载书籍...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func errorView(error: BookError) -> some View {
        ZStack {
            themeService.currentTheme.backgroundColor
                .edgesIgnoringSafeArea(.all)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("加载失败")
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 16) {
                    Button("返回书架") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(themeService.currentTheme.textColor)
                    .cornerRadius(8)
                    
                    Button("重试") {
                        viewModel.loadBook()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            .padding()
        }
    }
    
    private var emptyView: some View {
        ZStack {
            themeService.currentTheme.backgroundColor
                .edgesIgnoringSafeArea(.all)
            VStack(spacing: 16) {
                Image(systemName: "doc.text")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
                Text("暂无内容")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var readerContent: some View {
        GeometryReader { geometry in
            PageViewController(
                viewModel: viewModel,
                size: geometry.size,
                currentPage: $viewModel.currentPageIndex,
                onPageChanged: { index in
                    viewModel.updateProgressForPage(index)
                },
                onTap: {
                    viewModel.toggleToolbar()
                }
            )
            .onAppear {
                // 将实际可用的视图高度传递给 ViewModel，用于精确分页
                viewModel.setAvailableViewHeight(geometry.size.height)
            }
        }
    }
    
    // MARK: - 工具栏层（覆盖在内容上方）
    
    private var toolbarLayer: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // 顶部工具栏
                ReaderTopToolbar(
                    title: viewModel.currentPage?.chapterTitle ?? viewModel.book.title,
                    onBack: { presentationMode.wrappedValue.dismiss() },
                    onSettings: { viewModel.showSettings = true }
                )
                .background(
                    // 轻微渐变遮罩
                    LinearGradient(
                        colors: [
                            themeService.currentTheme.backgroundColor,
                            themeService.currentTheme.backgroundColor.opacity(0.8),
                            themeService.currentTheme.backgroundColor.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)
                    .offset(y: 44)
                    .allowsHitTesting(false)
                )

                Spacer()

                // 听书控制面板
                if viewModel.isSpeaking {
                    SpeechControlPanel(
                        isPaused: viewModel.isPaused,
                        rate: speechService.rate,
                        pitch: speechService.pitch,
                        onPauseResume: { viewModel.togglePauseSpeech() },
                        onStop: { viewModel.toggleSpeech() },
                        onRateChange: { speechService.rate = $0 },
                        onPitchChange: { speechService.pitch = $0 }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // 底部工具栏
                if viewModel.error == nil {
                    ReaderBottomToolbar(
                        onBookmark: { viewModel.toggleBookmark() },
                        onBookmarkList: { viewModel.openBookmarkList() },
                        onCatalog: { viewModel.showCatalog = true },
                        isBookmarked: viewModel.isCurrentPageBookmarked
                    )
                    .background(
                        LinearGradient(
                            colors: [
                                themeService.currentTheme.backgroundColor.opacity(0.0),
                                themeService.currentTheme.backgroundColor.opacity(0.8),
                                themeService.currentTheme.backgroundColor
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 20)
                        .offset(y: -44)
                        .allowsHitTesting(false)
                    )
                }
            }

            // 听书悬浮按钮
            Button(action: {
                viewModel.toggleSpeech()
            }) {
                Image(systemName: viewModel.isSpeaking ? (viewModel.isPaused ? "play.fill" : "pause") : "headphones")
                    .font(.system(size: 20))
                    .foregroundColor(themeService.currentTheme.textColor)
                    .padding(12)
                    .background(themeService.currentTheme.backgroundColor)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .padding(.trailing, 10)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - 页面内容视图（实时读取主题）

struct PageContentView: View {
    let page: Page
    let size: CGSize
    let pageIndex: Int
    @ObservedObject var viewModel: ReaderViewModel
    @ObservedObject private var themeService = ThemeService.shared
    
    private var theme: ReaderTheme {
        themeService.currentTheme
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部章节标题 - 固定高度区域
            HStack {
                Text(page.chapterTitle)
                    .font(.caption)
                    .foregroundColor(theme.secondaryTextColor)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(height: 28, alignment: .top)
            
            // 中间阅读内容 - 占据剩余空间
            GeometryReader { geometry in
                Text(page.content)
                    .font(.system(size: themeService.fontSize))
                    .foregroundColor(theme.textColor)
                    .lineSpacing(themeService.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: geometry.size.height, alignment: .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .clipped()
            }
            
            // 底部页码 - 固定高度区域
            HStack {
                Spacer()
                Text("\(viewModel.currentPageIndex + 1)/\(viewModel.totalPages)")
                    .font(.caption)
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
            }
            .frame(height: 30, alignment: .bottom)
        }
        .background(theme.backgroundColor)
    }
}

// MARK: - UIKit 页面视图控制器包装

struct PageViewController: UIViewControllerRepresentable {
    @ObservedObject var viewModel: ReaderViewModel
    let size: CGSize
    @Binding var currentPage: Int
    let onPageChanged: (Int) -> Void
    let onTap: () -> Void
    
    /// 动态构建页面视图
    private func makePageView(at index: Int) -> PageContentView? {
        guard index >= 0 && index < viewModel.pages.count else { return nil }
        return PageContentView(
            page: viewModel.pages[index],
            size: size,
            pageIndex: index,
            viewModel: viewModel
        )
    }
    
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        tapGesture.delaysTouchesBegan = false
        tapGesture.delaysTouchesEnded = false
        pageViewController.view.addGestureRecognizer(tapGesture)
        context.coordinator.tapGesture = tapGesture
        
        if let firstPage = makePageView(at: 0) {
            let hostingController = UIHostingController(rootView: firstPage)
            pageViewController.setViewControllers([hostingController], direction: .forward, animated: false)
            context.coordinator.currentIndex = 0
        }
        
        return pageViewController
    }
    
    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        // 关键：同步更新 Coordinator 持有的 parent 引用
        // 因为 PageViewController 是 struct，Coordinator 持有的是值拷贝，不会自动更新
        context.coordinator.parent = self
        
        // 检测尺寸变化，触发重新分页（替代 iOS 14+ 的 .onChange）
        let currentSize = uiViewController.view.frame.size
        if context.coordinator.lastSize != nil,
           context.coordinator.lastSize != currentSize,
           !viewModel.pages.isEmpty {
            viewModel.setAvailableViewHeight(currentSize.height)
        }
        context.coordinator.lastSize = currentSize
        
        // pages 为空（正在重分页），不更新
        guard !viewModel.pages.isEmpty else { return }
        guard currentPage >= 0 && currentPage < viewModel.pages.count else { return }
        
        // 检测 pages 版本变化（重分页后强制刷新当前页面）
        let pagesVersionChanged = context.coordinator.lastPagesVersion != viewModel.pagesVersion
        if pagesVersionChanged {
            context.coordinator.lastPagesVersion = viewModel.pagesVersion
        }
        
        // 检查是否需要更新：currentPage 变化，pages 版本变化，或当前显示的页面不在新数组中
        let needsUpdate = pagesVersionChanged || context.coordinator.currentIndex != currentPage || {
            // 检查当前显示的页面是否与新数组中的页面对应
            if let currentVC = uiViewController.viewControllers?.first as? UIHostingController<PageContentView> {
                let currentGlobalIndex = currentVC.rootView.page.globalIndex
                let expectedGlobalIndex = viewModel.pages[currentPage].globalIndex
                return currentGlobalIndex != expectedGlobalIndex
            }
            return false
        }()
        
        if needsUpdate {
            let direction: UIPageViewController.NavigationDirection = currentPage > context.coordinator.currentIndex ? .forward : .reverse
            if let page = makePageView(at: currentPage) {
                let hostingController = UIHostingController(rootView: page)
                // 使用 animated: false 避免 UIPageViewController 在动画期间
                // 手势翻页状态不一致的问题（右滑返回可能跳到错误页面）
                uiViewController.setViewControllers([hostingController], direction: direction, animated: false)
                context.coordinator.currentIndex = currentPage
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PageViewController
        var currentIndex: Int = 0
        var tapGesture: UITapGestureRecognizer?
        var lastPagesVersion: Int = 0
        var lastSize: CGSize?
        
        init(_ parent: PageViewController) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            guard let view = gesture.view else { return }
            let screenWidth = view.bounds.width
            if location.x > screenWidth * 0.3 && location.x < screenWidth * 0.7 {
                parent.onTap()
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return false
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            // 基于传入的 viewController 确定前一页
            // 必须在 pages 数组中查找实际索引，不能依赖 globalIndex-1（因为 globalIndex 可能不连续）
            guard let hostingVC = viewController as? UIHostingController<PageContentView> else { return nil }
            let currentGlobalIndex = hostingVC.rootView.page.globalIndex
            guard let currentArrayIndex = parent.viewModel.pages.firstIndex(where: { $0.globalIndex == currentGlobalIndex }),
                  currentArrayIndex > 0 else { return nil }
            let previousArrayIndex = currentArrayIndex - 1
            guard let page = parent.makePageView(at: previousArrayIndex) else { return nil }
            return UIHostingController(rootView: page)
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            // 基于传入的 viewController 确定后一页
            guard let hostingVC = viewController as? UIHostingController<PageContentView> else { return nil }
            let currentGlobalIndex = hostingVC.rootView.page.globalIndex
            guard let currentArrayIndex = parent.viewModel.pages.firstIndex(where: { $0.globalIndex == currentGlobalIndex }),
                  currentArrayIndex < parent.viewModel.pages.count - 1 else { return nil }
            let nextArrayIndex = currentArrayIndex + 1
            guard let page = parent.makePageView(at: nextArrayIndex) else { return nil }
            return UIHostingController(rootView: page)
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed else { return }
            if let currentVC = pageViewController.viewControllers?.first {
                if let hostingVC = currentVC as? UIHostingController<PageContentView> {
                    let globalIndex = hostingVC.rootView.page.globalIndex
                    if let newIndex = parent.viewModel.pages.firstIndex(where: { $0.globalIndex == globalIndex }) {
                        currentIndex = newIndex
                        parent.currentPage = newIndex
                        parent.onPageChanged(newIndex)
                    } else {
                        // Fallback: 根据滑动方向推断
                        if let previousVC = previousViewControllers.first as? UIHostingController<PageContentView> {
                            let prevGlobalIndex = previousVC.rootView.page.globalIndex
                            if globalIndex < prevGlobalIndex {
                                currentIndex = max(0, currentIndex - 1)
                            } else {
                                currentIndex = min(parent.viewModel.pages.count - 1, currentIndex + 1)
                            }
                            parent.currentPage = currentIndex
                            parent.onPageChanged(currentIndex)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 顶部工具栏

struct ReaderTopToolbar: View {
    let title: String
    let onBack: () -> Void
    let onSettings: () -> Void
    @ObservedObject private var themeService = ThemeService.shared
    
    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .regular))
            }
            
            Spacer()
            
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            
            Spacer()
            
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
        }
        .padding()
        .background(themeService.currentTheme.backgroundColor)
        .foregroundColor(themeService.currentTheme.textColor)
    }
}

// MARK: - 底部工具栏

struct ReaderBottomToolbar: View {
    let onBookmark: () -> Void
    let onBookmarkList: () -> Void
    let onCatalog: () -> Void
    let isBookmarked: Bool
    @ObservedObject private var themeService = ThemeService.shared
    
    var body: some View {
        HStack(spacing: 40) {
            Button(action: onCatalog) {
                Image(systemName: "textformat.size")
            }

            Button(action: onBookmarkList) {
                Image(systemName: "list.bullet")
            }

            Button(action: onBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundColor(isBookmarked ? .yellow : themeService.currentTheme.textColor)
            }
        }
        .padding()
        .background(themeService.currentTheme.backgroundColor)
        .foregroundColor(themeService.currentTheme.textColor)
    }
}

// MARK: - 听书控制面板

struct SpeechControlPanel: View {
    let isPaused: Bool
    let rate: Float
    let pitch: Float
    let onPauseResume: () -> Void
    let onStop: () -> Void
    let onRateChange: (Float) -> Void
    let onPitchChange: (Float) -> Void
    @ObservedObject private var themeService = ThemeService.shared
    
    var body: some View {
        VStack(spacing: 8) {
            // 语速调节
            HStack(spacing: 12) {
                Image(systemName: "tortoise")
                    .font(.system(size: 12))
                Text("语速")
                    .font(.caption)
                Slider(value: .init(
                    get: { Double(rate) },
                    set: { onRateChange(Float($0)) }
                ), in: 0.3...0.8, step: 0.05)
                .frame(height: 20)
                Image(systemName: "hare")
                    .font(.system(size: 12))
            }
            
            // 音调调节
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                Text("音调")
                    .font(.caption)
                Slider(value: .init(
                    get: { Double(pitch) },
                    set: { onPitchChange(Float($0)) }
                ), in: 0.5...2.0, step: 0.1)
                .frame(height: 20)
            }
            
            // 控制按钮
            HStack(spacing: 30) {
                Button(action: onPauseResume) {
                    Image(systemName: isPaused ? "play.fill" : "pause")
                        .font(.system(size: 16))
                }
                
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(themeService.currentTheme.backgroundColor)
        .foregroundColor(themeService.currentTheme.textColor)
    }
}

// MARK: - 预览

struct ReaderView_Previews: PreviewProvider {
    static var previews: some View {
        ReaderView(book: .sample)
    }
}
