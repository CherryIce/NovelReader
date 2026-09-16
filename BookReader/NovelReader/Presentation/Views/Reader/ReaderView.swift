import CoreText
import SwiftUI
import UIKit

struct ReaderView: View {
    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeService = ThemeService.shared
    @ObservedObject private var speechService = SpeechService.shared
    
    init(book: Book) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(book: book))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景层 - 延伸到安全区域
                themeService.currentTheme.backgroundColor
                    .ignoresSafeArea()

                // 内容层 - 始终占满全屏
                contentLayer

                // 工具栏层 - 覆盖在内容上方
                if viewModel.showToolbar {
                    toolbarLayer
                        .transition(.opacity)
                }

                if viewModel.showSelectionActions {
                    selectionActionLayer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                // 首次加载前先提供真实尺寸，避免先按屏幕估算分页后再重排。
                viewModel.setAvailableViewSize(geometry.size)
                viewModel.loadBook()
                ReadingTimeTracker.shared.startReading(
                    bookId: viewModel.book.id,
                    bookTitle: viewModel.book.title
                )
            }
        }
        .onDisappear {
            ReadingTimeTracker.shared.stopReading()
            viewModel.stopSpeech()
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
        .sheet(
            isPresented: $viewModel.showCommentComposer,
            onDismiss: {
                if viewModel.activeSelection != nil {
                    viewModel.cancelWritingComment()
                }
            }
        ) {
            ReaderCommentComposer(
                selectedText: viewModel.selectedText ?? "",
                comment: $viewModel.commentDraft,
                isSaving: viewModel.isSavingSelection,
                onCancel: { viewModel.cancelWritingComment() },
                onSave: { viewModel.saveSelectionComment() }
            )
        }
        .sheet(
            item: $viewModel.presentedAnnotationKey,
            onDismiss: { viewModel.closePresentedAnnotation() }
        ) { key in
            NavigationView {
                ReaderAnnotationDetailView(
                    viewModel: viewModel,
                    annotationKey: key
                )
            }
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
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
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
                .ignoresSafeArea()
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
                        dismiss()
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
                .ignoresSafeArea()
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
                // 将实际可用的视图尺寸传递给 ViewModel，用于精确分页
                viewModel.setAvailableViewSize(geometry.size)
            }
        }
    }
    
    // MARK: - 工具栏层（覆盖在内容上方）
    
    private var toolbarLayer: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            ReaderTopToolbar(
                title: viewModel.currentPage?.chapterTitle ?? viewModel.book.title,
                onBack: { dismiss() },
                onBookmark: { viewModel.toggleBookmark() },
                isBookmarked: viewModel.isCurrentPageBookmarked
            )

            Spacer()

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
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 底部工具栏
            if viewModel.error == nil {
                ReaderBottomToolbar(
                    progress: viewModel.readingProgress,
                    hasPreviousChapter: viewModel.hasPreviousChapter,
                    hasNextChapter: viewModel.hasNextChapter,
                    onPreviousChapter: { viewModel.previousChapter() },
                    onNextChapter: { viewModel.nextChapter() },
                    onSliderChange: { value in
                        viewModel.jumpToProgress(value)
                    },
                    onCatalog: { viewModel.showCatalog = true },
                    onBookmarkList: { viewModel.openBookmarkList() },
                    onSpeech: { viewModel.toggleSpeech() },
                    onSettings: { viewModel.showSettings = true },
                    isSpeaking: viewModel.isSpeaking
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private var selectionActionLayer: some View {
        VStack {
            Spacer()
            HStack(spacing: 22) {
                selectionActionButton(
                    title: viewModel.canHighlightSelection ? "划线" : "已划线",
                    systemImage: viewModel.canHighlightSelection ? "scribble" : "checkmark"
                ) {
                    viewModel.saveSelectionAsHighlight()
                }
                .disabled(!viewModel.canHighlightSelection)
                selectionActionButton(
                    title: viewModel.canAddThoughtToSelection ? "写想法" : "想法已满",
                    systemImage: viewModel.canAddThoughtToSelection
                        ? "square.and.pencil"
                        : "checkmark.circle"
                ) {
                    viewModel.beginWritingComment()
                }
                .disabled(!viewModel.canAddThoughtToSelection)
                selectionActionButton(title: "复制", systemImage: "doc.on.doc") {
                    viewModel.copySelection()
                }
                selectionActionButton(title: "取消", systemImage: "xmark") {
                    viewModel.cancelSelection()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .padding(.bottom, 44)
        }
        .padding(.horizontal, 16)
    }

    private func selectionActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.caption2)
            }
            .foregroundColor(themeService.currentTheme.textColor)
        }
        .disabled(viewModel.isSavingSelection)
    }
}

private struct ReaderCommentComposer: View {
    let selectedText: String
    @Binding var comment: String
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(selectedText)
                        .font(.subheadline)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                TextEditor(text: $comment)
                    .frame(maxHeight: .infinity)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .accessibilityLabel("评论内容")
            }
            .padding()
            .navigationTitle("写想法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
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
            .frame(height: ReaderLayoutMetrics.headerHeight, alignment: .top)
            
            // 中间阅读内容 - 占据剩余空间
            GeometryReader { geometry in
                let descriptor = viewModel.displayPaginationDescriptor
                let textSize = ReaderTextLayout.textContainerSize(for: descriptor)

                CoreTextPageView(
                    text: page.content,
                    descriptor: descriptor,
                    textColor: theme.textColorUI,
                    selectionMarks: viewModel.selectionMarks(for: page)
                )
                .frame(width: textSize.width, height: textSize.height)
                .padding(.leading, descriptor.horizontalPadding)
                .padding(.top, descriptor.contentTopPadding)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
                .clipped()
            }
            
            // 底部页码 - 固定高度区域
            HStack {
                Spacer()
                Text("\(pageIndex + 1)/\(viewModel.totalPages)")
                    .font(.caption)
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
            }
            .frame(height: ReaderLayoutMetrics.footerHeight, alignment: .bottom)
        }
        .background(theme.backgroundColor)
    }
}

/// 使用与分页器相同的 Core Text frame 绘制正文。
private struct CoreTextPageView: UIViewRepresentable {
    let text: String
    let descriptor: PageCacheDescriptor
    let textColor: UIColor
    let selectionMarks: [ReaderTextMark]

    func makeUIView(context: Context) -> CoreTextPageUIView {
        let view = CoreTextPageUIView()
        update(view)
        return view
    }

    func updateUIView(_ uiView: CoreTextPageUIView, context: Context) {
        update(uiView)
    }

    private func update(_ view: CoreTextPageUIView) {
        view.attributedText = ReaderTextLayout.attributedString(
            text,
            descriptor: descriptor,
            foregroundColor: textColor
        )
        view.selectionMarks = selectionMarks
    }
}

private final class CoreTextPageUIView: UIView {
    var attributedText = NSAttributedString() {
        didSet {
            guard !oldValue.isEqual(to: attributedText) else { return }
            invalidateTextLayout()
            setNeedsDisplay()
        }
    }

    var selectionMarks: [ReaderTextMark] = [] {
        didSet {
            if oldValue != selectionMarks {
                setNeedsDisplay()
            }
        }
    }

    private var textFrame: CTFrame?
    private var textLines: [CTLine] = []
    private var lineOrigins: [CGPoint] = []
    private var layoutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        contentMode = .redraw
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if layoutSize != bounds.size {
            invalidateTextLayout()
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard ensureTextLayout(),
              let frame = textFrame,
              let context = UIGraphicsGetCurrentContext() else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        CTFrameDraw(frame, context)
        drawSelectionMarks(in: context)
    }

    func characterIndex(at point: CGPoint, clampingToBounds: Bool) -> Int? {
        textPosition(at: point, clampingToBounds: clampingToBounds)?.characterIndex
    }

    /// 仅命中实际绘制出来的持久波浪线，避免段首空白也能打开详情。
    func persistedMarkCharacterIndex(at point: CGPoint) -> Int? {
        guard let position = textPosition(at: point, clampingToBounds: false) else { return nil }
        let line = textLines[position.lineIndex]
        let lineRange = CTLineGetStringRange(line)
        guard lineRange.location != kCFNotFound else { return nil }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let lineOriginY = lineOrigins[position.lineIndex].y
        let verticalHitSlop: CGFloat = 4
        let lowerY = lineOriginY - descent - leading / 2 - verticalHitSlop
        let upperY = lineOriginY + ascent + leading / 2 + verticalHitSlop
        guard position.coreTextY >= lowerY, position.coreTextY <= upperY else { return nil }

        for mark in selectionMarks where mark.style != .active {
            let intersection = NSIntersectionRange(
                mark.range,
                NSRange(location: lineRange.location, length: lineRange.length)
            )
            guard let drawableRange = ReaderTextRangeMath.trimmingLineWhitespace(
                in: attributedText.string,
                range: intersection
            ) else {
                continue
            }

            let startOffset = CTLineGetOffsetForStringIndex(line, drawableRange.location, nil)
            let endOffset = CTLineGetOffsetForStringIndex(line, NSMaxRange(drawableRange), nil)
            let minimumX = min(startOffset, endOffset)
            let maximumX = max(startOffset, endOffset)
            guard position.relativeX >= minimumX, position.relativeX <= maximumX else { continue }

            return min(
                max(position.characterIndex, drawableRange.location),
                NSMaxRange(drawableRange) - 1
            )
        }
        return nil
    }

    private func textPosition(
        at point: CGPoint,
        clampingToBounds: Bool
    ) -> (lineIndex: Int, characterIndex: Int, relativeX: CGFloat, coreTextY: CGFloat)? {
        guard ensureTextLayout(), !textLines.isEmpty else { return nil }

        let permittedBounds = bounds.insetBy(dx: -12, dy: -12)
        guard clampingToBounds || permittedBounds.contains(point) else { return nil }

        let clampedPoint = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        let coreTextPoint = CGPoint(x: clampedPoint.x, y: bounds.height - clampedPoint.y)

        var selectedLineIndex = 0
        var shortestDistance = CGFloat.greatestFiniteMagnitude

        for (index, line) in textLines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let lowerY = lineOrigins[index].y - descent - leading / 2
            let upperY = lineOrigins[index].y + ascent + leading / 2

            if coreTextPoint.y >= lowerY, coreTextPoint.y <= upperY {
                selectedLineIndex = index
                shortestDistance = 0
                break
            }

            let distance = min(abs(coreTextPoint.y - lowerY), abs(coreTextPoint.y - upperY))
            if distance < shortestDistance {
                shortestDistance = distance
                selectedLineIndex = index
            }
        }

        let line = textLines[selectedLineIndex]
        let origin = lineOrigins[selectedLineIndex]
        let lineRange = CTLineGetStringRange(line)
        let relativePoint = CGPoint(x: coreTextPoint.x - origin.x, y: 0)
        let index = CTLineGetStringIndexForPosition(line, relativePoint)

        if index == kCFNotFound {
            let characterIndex = relativePoint.x <= 0
                ? lineRange.location
                : lineRange.location + lineRange.length
            return (selectedLineIndex, characterIndex, relativePoint.x, coreTextPoint.y)
        }
        return (
            selectedLineIndex,
            min(max(index, 0), attributedText.length),
            relativePoint.x,
            coreTextPoint.y
        )
    }

    func caretPoint(for index: Int, preferPreviousLine: Bool) -> CGPoint? {
        guard ensureTextLayout(), !textLines.isEmpty else { return nil }

        let clampedIndex = min(max(index, 0), attributedText.length)
        var selectedLineIndex: Int?

        for (lineIndex, line) in textLines.enumerated() {
            let range = CTLineGetStringRange(line)
            let start = range.location
            let end = range.location + range.length
            if clampedIndex >= start,
               clampedIndex < end || (preferPreviousLine && clampedIndex == end) {
                selectedLineIndex = lineIndex
                break
            }
        }

        let lineIndex = selectedLineIndex ?? (preferPreviousLine ? textLines.count - 1 : 0)
        let line = textLines[lineIndex]
        let origin = lineOrigins[lineIndex]
        let xOffset = CTLineGetOffsetForStringIndex(line, clampedIndex, nil)
        let coreTextY = origin.y - 2

        return CGPoint(
            x: origin.x + xOffset,
            y: bounds.height - coreTextY
        )
    }

    private func ensureTextLayout() -> Bool {
        guard !attributedText.string.isEmpty,
              bounds.width > 0,
              bounds.height > 0 else {
            return false
        }
        if textFrame != nil, layoutSize == bounds.size {
            return true
        }

        let framesetter = CTFramesetterCreateWithAttributedString(
            attributedText as CFAttributedString
        )
        let frame = ReaderTextLayout.frame(
            framesetter: framesetter,
            range: CFRange(location: 0, length: attributedText.length),
            containerSize: bounds.size
        )
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        }

        textFrame = frame
        textLines = lines
        lineOrigins = origins
        layoutSize = bounds.size
        return true
    }

    private func invalidateTextLayout() {
        textFrame = nil
        textLines = []
        lineOrigins = []
        layoutSize = .zero
    }

    private func drawSelectionMarks(in context: CGContext) {
        for mark in selectionMarks {
            let color: UIColor
            switch mark.style {
            case .active:
                color = .systemBlue
            case .highlight:
                color = .systemOrange
            case .note:
                color = .systemPurple
            }
            drawWave(range: mark.range, color: color, in: context)
        }
    }

    private func drawWave(range: NSRange, color: UIColor, in context: CGContext) {
        guard range.length > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.25)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for (index, line) in textLines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.location != kCFNotFound else { continue }
            let intersection = NSIntersectionRange(
                range,
                NSRange(location: lineRange.location, length: lineRange.length)
            )
            guard let drawableRange = ReaderTextRangeMath.trimmingLineWhitespace(
                in: attributedText.string,
                range: intersection
            ) else { continue }

            let origin = lineOrigins[index]
            let startOffset = CTLineGetOffsetForStringIndex(line, drawableRange.location, nil)
            let endOffset = CTLineGetOffsetForStringIndex(line, NSMaxRange(drawableRange), nil)
            let startX = origin.x + min(startOffset, endOffset)
            let endX = origin.x + max(startOffset, endOffset)
            guard endX > startX else { continue }

            let baselineY = origin.y - 2.5
            let amplitude: CGFloat = 1.2
            let halfWave: CGFloat = 2.2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: startX, y: baselineY))

            var x = startX
            var rising = true
            while x < endX {
                x = min(x + halfWave, endX)
                path.addLine(
                    to: CGPoint(
                        x: x,
                        y: baselineY + (rising ? amplitude : -amplitude)
                    )
                )
                rising.toggle()
            }

            context.addPath(path)
            context.strokePath()
        }
    }

}

private final class ReaderSelectionHandleView: UIView {
    enum Endpoint {
        case start
        case end
    }

    let endpoint: Endpoint

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: 28, height: 34)))
        backgroundColor = .clear
        isOpaque = false
        isHidden = true
        accessibilityLabel = endpoint == .start ? "选区起点" : "选区终点"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let color = UIColor.systemBlue
        let centerX = bounds.midX

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        if endpoint == .start {
            context.move(to: CGPoint(x: centerX, y: 8))
            context.addLine(to: CGPoint(x: centerX, y: 30))
            context.strokePath()
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: centerX - 6, y: 2, width: 12, height: 12))
        } else {
            context.move(to: CGPoint(x: centerX, y: 4))
            context.addLine(to: CGPoint(x: centerX, y: 26))
            context.strokePath()
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: centerX - 6, y: 20, width: 12, height: 12))
        }
    }

    func position(caretAt point: CGPoint) {
        let caretY: CGFloat = endpoint == .start ? 30 : 4
        frame.origin = CGPoint(x: point.x - bounds.width / 2, y: point.y - caretY)
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
        context.coordinator.installSelectionInteraction(on: pageViewController)
        if let selectionLongPress = context.coordinator.selectionLongPress {
            tapGesture.require(toFail: selectionLongPress)
        }
        
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
        context.coordinator.pageViewController = uiViewController
        
        // 检测尺寸变化，触发重新分页
        let currentSize = uiViewController.view.frame.size
        if context.coordinator.lastSize != nil,
           context.coordinator.lastSize != currentSize,
           !viewModel.pages.isEmpty {
            viewModel.setAvailableViewSize(currentSize)
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

        DispatchQueue.main.async {
            context.coordinator.refreshSelectionChrome()
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
        weak var pageViewController: UIPageViewController?
        var selectionLongPress: UILongPressGestureRecognizer?

        private let startHandle = ReaderSelectionHandleView(endpoint: .start)
        private let endHandle = ReaderSelectionHandleView(endpoint: .end)
        private var edgeTimer: Timer?
        private var edgeDirection = 0
        private var lastInteractionPoint: CGPoint?
        private var selectionOriginPoint: CGPoint?
        private var selectionDragHasMoved = false
        private var activeHandle: ReaderSelectionHandleView.Endpoint?
        
        init(_ parent: PageViewController) {
            self.parent = parent
        }

        deinit {
            edgeTimer?.invalidate()
        }

        func installSelectionInteraction(on pageViewController: UIPageViewController) {
            self.pageViewController = pageViewController

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleSelectionLongPress(_:))
            )
            longPress.minimumPressDuration = 0.35
            longPress.allowableMovement = 18
            longPress.cancelsTouchesInView = true
            longPress.delegate = self
            pageViewController.view.addGestureRecognizer(longPress)
            selectionLongPress = longPress

            for handle in [startHandle, endHandle] {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
                pan.delegate = self
                handle.addGestureRecognizer(pan)
                pageViewController.view.addSubview(handle)
            }
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            if parent.viewModel.activeSelection != nil {
                parent.viewModel.cancelSelection()
                refreshSelectionChrome()
                return
            }
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let screenWidth = view.bounds.width
            let isToolbarSafeArea = isToolbarSafeArea(at: location)
            let annotation = isToolbarSafeArea ? nil : annotationHit(at: location)
            let target = ReaderPageTapRouting.target(
                isToolbarSafeArea: isToolbarSafeArea,
                isAnnotationHit: annotation != nil,
                isCenterTap: location.x > screenWidth * 0.3 && location.x < screenWidth * 0.7
            )

            switch target {
            case .toolbar:
                parent.onTap()
            case .annotation:
                guard let annotation else { return }
                _ = parent.viewModel.openAnnotation(
                    chapterIndex: annotation.page.chapterIndex,
                    contentOffset: annotation.contentOffset
                )
            case .none:
                break
            }
        }

        @objc private func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let pageViewController else { return }
            let location = gesture.location(in: pageViewController.view)

            switch gesture.state {
            case .began:
                guard let hit = textHit(at: location, clampingToBounds: false) else { return }
                selectionOriginPoint = location
                selectionDragHasMoved = false
                activeHandle = nil
                parent.viewModel.beginSelection(
                    chapterIndex: hit.page.chapterIndex,
                    contentOffset: hit.contentOffset
                )
                setPagingEnabled(false)
                refreshSelectionChrome()

            case .changed:
                guard parent.viewModel.activeSelection != nil else { return }
                lastInteractionPoint = location
                if let origin = selectionOriginPoint,
                   hypot(location.x - origin.x, location.y - origin.y) > 6 {
                    selectionDragHasMoved = true
                }
                if selectionDragHasMoved {
                    updateSelectionFocus(at: location)
                }
                updateEdgeTracking(at: location, allowedDirection: nil)

            case .ended:
                if selectionDragHasMoved {
                    updateSelectionFocus(at: location)
                }
                finishSelectionInteraction()

            case .cancelled, .failed:
                finishSelectionInteraction()

            default:
                break
            }
        }

        @objc private func handleSelectionHandlePan(_ gesture: UIPanGestureRecognizer) {
            guard let handle = gesture.view as? ReaderSelectionHandleView,
                  let pageViewController else {
                return
            }
            let location = gesture.location(in: pageViewController.view)

            switch gesture.state {
            case .began:
                activeHandle = handle.endpoint
                lastInteractionPoint = location
                parent.viewModel.showSelectionActions = false
                setPagingEnabled(false)

            case .changed:
                lastInteractionPoint = location
                updateSelectionEndpoint(handle.endpoint, at: location)
                updateEdgeTracking(
                    at: location,
                    allowedDirection: handle.endpoint == .start ? -1 : 1
                )

            case .ended, .cancelled, .failed:
                updateSelectionEndpoint(handle.endpoint, at: location)
                activeHandle = nil
                finishSelectionInteraction()

            default:
                break
            }
        }

        func refreshSelectionChrome() {
            guard let pageViewController,
                  let selection = parent.viewModel.activeSelection,
                  let page = parent.viewModel.pages[safe: currentIndex],
                  page.chapterIndex == selection.chapterIndex,
                  let textView = currentTextView() else {
                startHandle.isHidden = true
                endHandle.isHidden = true
                return
            }

            pageViewController.view.bringSubviewToFront(startHandle)
            pageViewController.view.bringSubviewToFront(endHandle)

            let pageStart = page.contentOffset
            let pageEnd = pageStart + (page.content as NSString).length

            if selection.lowerBound >= pageStart,
               selection.lowerBound < pageEnd,
               let point = textView.caretPoint(
                for: selection.lowerBound - pageStart,
                preferPreviousLine: false
               ) {
                startHandle.isHidden = false
                startHandle.position(caretAt: textView.convert(point, to: pageViewController.view))
            } else {
                startHandle.isHidden = true
            }

            if selection.upperBound > pageStart,
               selection.upperBound <= pageEnd,
               let point = textView.caretPoint(
                for: selection.upperBound - pageStart,
                preferPreviousLine: true
               ) {
                endHandle.isHidden = false
                endHandle.position(caretAt: textView.convert(point, to: pageViewController.view))
            } else {
                endHandle.isHidden = true
            }
        }

        private func updateSelectionFocus(at point: CGPoint) {
            guard let hit = textHit(at: point, clampingToBounds: true) else { return }
            parent.viewModel.updateSelectionFocus(
                chapterIndex: hit.page.chapterIndex,
                contentOffset: hit.contentOffset
            )
            refreshSelectionChrome()
        }

        private func updateSelectionEndpoint(
            _ endpoint: ReaderSelectionHandleView.Endpoint,
            at point: CGPoint
        ) {
            guard let hit = textHit(at: point, clampingToBounds: true) else { return }
            switch endpoint {
            case .start:
                parent.viewModel.updateSelectionStart(
                    chapterIndex: hit.page.chapterIndex,
                    contentOffset: hit.contentOffset
                )
            case .end:
                parent.viewModel.updateSelectionEnd(
                    chapterIndex: hit.page.chapterIndex,
                    contentOffset: hit.contentOffset
                )
            }
            refreshSelectionChrome()
        }

        private func textHit(
            at point: CGPoint,
            clampingToBounds: Bool
        ) -> (page: Page, contentOffset: Int)? {
            guard let pageViewController,
                  let page = parent.viewModel.pages[safe: currentIndex],
                  let textView = currentTextView() else {
                return nil
            }

            let pointInTextView = textView.convert(point, from: pageViewController.view)
            guard let localOffset = textView.characterIndex(
                at: pointInTextView,
                clampingToBounds: clampingToBounds
            ) else {
                return nil
            }
            return (page, page.contentOffset + localOffset)
        }

        private func annotationHit(at point: CGPoint) -> (page: Page, contentOffset: Int)? {
            guard let pageViewController,
                  let page = parent.viewModel.pages[safe: currentIndex],
                  let textView = currentTextView() else {
                return nil
            }

            let pointInTextView = textView.convert(point, from: pageViewController.view)
            guard let localOffset = textView.persistedMarkCharacterIndex(at: pointInTextView) else {
                return nil
            }
            return (page, page.contentOffset + localOffset)
        }

        /// 正文排版框之外永远作为工具栏安全区，避免整页划线后失去工具栏入口。
        private func isToolbarSafeArea(at point: CGPoint) -> Bool {
            guard let pageViewController,
                  let textView = currentTextView() else {
                return false
            }

            let textFrame = textView.convert(textView.bounds, to: pageViewController.view)
            return !textFrame.contains(point)
        }

        private func currentTextView() -> CoreTextPageUIView? {
            guard let hostingView = pageViewController?.viewControllers?.first?.view else {
                return nil
            }
            hostingView.layoutIfNeeded()
            return findTextView(in: hostingView)
        }

        private func findTextView(in view: UIView) -> CoreTextPageUIView? {
            if let textView = view as? CoreTextPageUIView {
                return textView
            }
            for subview in view.subviews {
                if let match = findTextView(in: subview) {
                    return match
                }
            }
            return nil
        }

        private func updateEdgeTracking(at location: CGPoint, allowedDirection: Int?) {
            guard let pageViewController else { return }
            let edgeWidth: CGFloat = 32
            let proposedDirection: Int
            if location.x <= edgeWidth {
                proposedDirection = -1
            } else if location.x >= pageViewController.view.bounds.width - edgeWidth {
                proposedDirection = 1
            } else {
                proposedDirection = 0
            }

            let direction = allowedDirection.map {
                proposedDirection == $0 ? proposedDirection : 0
            } ?? proposedDirection
            guard direction != 0, canTurnSelectionPage(direction: direction) else {
                stopEdgeTracking()
                return
            }
            guard direction != edgeDirection || edgeTimer == nil else { return }

            stopEdgeTracking()
            edgeDirection = direction
            let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
                self?.turnSelectionPage(direction: direction)
            }
            edgeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func canTurnSelectionPage(direction: Int) -> Bool {
            guard let selection = parent.viewModel.activeSelection,
                  let targetPage = parent.viewModel.pages[safe: currentIndex + direction] else {
                return false
            }
            return targetPage.chapterIndex == selection.chapterIndex
        }

        private func turnSelectionPage(direction: Int) {
            guard let pageViewController,
                  canTurnSelectionPage(direction: direction) else {
                stopEdgeTracking()
                return
            }

            let targetIndex = currentIndex + direction
            guard let page = parent.makePageView(at: targetIndex) else {
                stopEdgeTracking()
                return
            }

            let hostingController = UIHostingController(rootView: page)
            pageViewController.setViewControllers(
                [hostingController],
                direction: direction > 0 ? .forward : .reverse,
                animated: false
            )
            currentIndex = targetIndex
            parent.currentPage = targetIndex
            parent.onPageChanged(targetIndex)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pageViewController.view.layoutIfNeeded()
                if let point = self.lastInteractionPoint {
                    if let activeHandle = self.activeHandle {
                        self.updateSelectionEndpoint(activeHandle, at: point)
                    } else {
                        self.updateSelectionFocus(at: point)
                    }
                }
                self.refreshSelectionChrome()
            }
        }

        private func stopEdgeTracking() {
            edgeTimer?.invalidate()
            edgeTimer = nil
            edgeDirection = 0
        }

        private func finishSelectionInteraction() {
            stopEdgeTracking()
            setPagingEnabled(true)
            selectionOriginPoint = nil
            lastInteractionPoint = nil
            parent.viewModel.finishSelection()
            refreshSelectionChrome()
        }

        private func setPagingEnabled(_ enabled: Bool) {
            pageViewController?.view.subviews
                .compactMap { $0 as? UIScrollView }
                .forEach { $0.isScrollEnabled = enabled }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === selectionLongPress || otherGestureRecognizer === selectionLongPress {
                return false
            }
            if gestureRecognizer.view is ReaderSelectionHandleView
                || otherGestureRecognizer.view is ReaderSelectionHandleView {
                return false
            }
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
    let onBookmark: () -> Void
    let isBookmarked: Bool
    @ObservedObject private var themeService = ThemeService.shared
    
    var body: some View {
        HStack(spacing: 12) {
            ReaderToolbarIconButton(
                systemName: "chevron.left",
                accessibilityLabel: "返回书架",
                action: onBack
            )

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            ReaderToolbarIconButton(
                systemName: isBookmarked ? "bookmark.fill" : "bookmark",
                accessibilityLabel: isBookmarked ? "移除当前页书签" : "添加当前页书签",
                tint: isBookmarked ? .accentColor : themeService.currentTheme.textColor,
                action: onBookmark
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(themeService.currentTheme.backgroundColor.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(themeService.currentTheme.secondaryTextColor.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .foregroundColor(themeService.currentTheme.textColor)
    }
}

private struct ReaderToolbarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var tint: Color? = nil
    let action: () -> Void
    @ObservedObject private var themeService = ThemeService.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(tint ?? themeService.currentTheme.textColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - 底部工具栏

struct ReaderBottomToolbar: View {
    let progress: Double
    let hasPreviousChapter: Bool
    let hasNextChapter: Bool
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onSliderChange: (Double) -> Void
    let onCatalog: () -> Void
    let onBookmarkList: () -> Void
    let onSpeech: () -> Void
    let onSettings: () -> Void
    let isSpeaking: Bool
    @ObservedObject private var themeService = ThemeService.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ReaderChapterButton(
                    title: "上一章",
                    systemName: "chevron.left",
                    isEnabled: hasPreviousChapter,
                    action: onPreviousChapter
                )

                VStack(spacing: 5) {
                    Slider(
                        value: Binding(
                            get: { progress },
                            set: { onSliderChange($0) }
                        ),
                        in: 0...1
                    )
                    .tint(.accentColor)

                    HStack {
                        Text("阅读进度")
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeService.currentTheme.secondaryTextColor)
                }

                ReaderChapterButton(
                    title: "下一章",
                    systemName: "chevron.right",
                    isEnabled: hasNextChapter,
                    action: onNextChapter
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .overlay(themeService.currentTheme.secondaryTextColor.opacity(0.12))

            HStack(spacing: 4) {
                ReaderPrimaryToolButton(
                    title: "目录",
                    systemName: "list.bullet",
                    action: onCatalog
                )
                ReaderPrimaryToolButton(
                    title: "书签",
                    systemName: "bookmark.square",
                    action: onBookmarkList
                )
                ReaderPrimaryToolButton(
                    title: isSpeaking ? "结束听书" : "听书",
                    systemName: isSpeaking ? "stop.circle.fill" : "headphones",
                    isActive: isSpeaking,
                    action: onSpeech
                )
                ReaderPrimaryToolButton(
                    title: "排版",
                    systemName: "textformat",
                    action: onSettings
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(themeService.currentTheme.backgroundColor.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(themeService.currentTheme.secondaryTextColor.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 16, x: 0, y: 6)
        )
        .foregroundColor(themeService.currentTheme.textColor)
    }
}

private struct ReaderChapterButton: View {
    let title: String
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.32)
    }
}

private struct ReaderPrimaryToolButton: View {
    let title: String
    let systemName: String
    var isActive = false
    let action: () -> Void
    @ObservedObject private var themeService = ThemeService.shared

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(isActive ? .accentColor : themeService.currentTheme.textColor)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(themeService.currentTheme.backgroundColor.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(themeService.currentTheme.secondaryTextColor.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        )
        .foregroundColor(themeService.currentTheme.textColor)
    }
}

// MARK: - 预览

struct ReaderView_Previews: PreviewProvider {
    static var previews: some View {
        ReaderView(book: .sample)
    }
}
