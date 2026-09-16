import CoreText
import Foundation
import UIKit

/// 页面数据 - 流式排版，全局连续索引
struct Page: Identifiable {
    let id = UUID()
    let globalIndex: Int
    let content: String
    let chapterIndex: Int
    let chapterTitle: String
    let isChapterStart: Bool
    let contentOffset: Int
}

/// 分阶段分页计划：先处理当前章节，再处理相邻章节，最后向两侧扩展。
enum ReaderPaginationPlan {
    static func priorityOrder(chapterCount: Int, focusedChapterIndex: Int) -> [Int] {
        guard chapterCount > 0 else { return [] }
        let focusedIndex = min(max(0, focusedChapterIndex), chapterCount - 1)
        var result = [focusedIndex]

        for distance in 1..<chapterCount {
            let previousIndex = focusedIndex - distance
            if previousIndex >= 0 {
                result.append(previousIndex)
            }

            let nextIndex = focusedIndex + distance
            if nextIndex < chapterCount {
                result.append(nextIndex)
            }
        }

        return result
    }

    static func focusedAndAdjacentIndexes(
        chapterCount: Int,
        focusedChapterIndex: Int
    ) -> [Int] {
        guard chapterCount > 0 else { return [] }
        let focusedIndex = min(max(0, focusedChapterIndex), chapterCount - 1)
        return [focusedIndex - 1, focusedIndex, focusedIndex + 1]
            .filter { $0 >= 0 && $0 < chapterCount }
    }

    static func mergedPages(
        chapterIndexes: [Int],
        pagesByChapter: [Int: [Page]]
    ) -> [Page] {
        var merged: [Page] = []

        for chapterIndex in chapterIndexes.sorted() {
            guard let chapterPages = pagesByChapter[chapterIndex] else { continue }
            for page in chapterPages {
                merged.append(Page(
                    globalIndex: merged.count,
                    content: page.content,
                    chapterIndex: page.chapterIndex,
                    chapterTitle: page.chapterTitle,
                    isChapterStart: page.isChapterStart,
                    contentOffset: page.contentOffset
                ))
            }
        }

        return merged
    }
}

/// 在按章节和正文偏移排序的页面数组中二分定位，避免长书翻页时扫描全部页面。
enum ReaderPageLocator {
    static func chapterRange(_ chapterIndex: Int, in pages: [Page]) -> Range<Int>? {
        var lower = 0
        var upper = pages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].chapterIndex < chapterIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let first = lower
        guard first < pages.count, pages[first].chapterIndex == chapterIndex else { return nil }

        upper = pages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].chapterIndex <= chapterIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return first..<lower
    }

    static func pageIndex(
        containing contentOffset: Int,
        inChapter chapterIndex: Int,
        pages: [Page]
    ) -> Int? {
        guard let range = chapterRange(chapterIndex, in: pages) else { return nil }
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].contentOffset <= contentOffset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(range.lowerBound, lower - 1)
    }

    static func pageIndex(matching page: Page, in pages: [Page]) -> Int? {
        if pages.indices.contains(page.globalIndex) {
            let candidate = pages[page.globalIndex]
            if candidate.chapterIndex == page.chapterIndex,
               candidate.contentOffset == page.contentOffset,
               candidate.content == page.content {
                return page.globalIndex
            }
        }

        guard let index = pageIndex(
            containing: page.contentOffset,
            inChapter: page.chapterIndex,
            pages: pages
        ), pages[index].contentOffset == page.contentOffset,
           pages[index].content == page.content else {
            return nil
        }
        return index
    }

    static func nextContentOffset(after index: Int, in pages: [Page]) -> Int? {
        guard pages.indices.contains(index), pages.indices.contains(index + 1),
              pages[index + 1].chapterIndex == pages[index].chapterIndex else {
            return nil
        }
        return pages[index + 1].contentOffset
    }
}

/// 分页计算与页面视图共同使用的布局尺寸
enum ReaderLayoutMetrics {
    static let horizontalPadding: CGFloat = 20
    static let headerHeight: CGFloat = 28
    static let contentTopPadding: CGFloat = 10
    static let footerHeight: CGFloat = 30
}

/// 分页和页面绘制共用的 Core Text 配置，避免两套排版引擎产生行高与换行差异。
enum ReaderTextLayout {
    static func textContainerSize(for descriptor: PageCacheDescriptor) -> CGSize {
        CGSize(
            width: max(1, descriptor.viewportWidth - descriptor.horizontalPadding * 2),
            height: max(
                1,
                descriptor.viewportHeight
                    - descriptor.headerHeight
                    - descriptor.contentTopPadding
                    - descriptor.footerHeight
            )
        )
    }

    static func attributedString(
        _ text: String,
        descriptor: PageCacheDescriptor,
        foregroundColor: UIColor? = nil
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = descriptor.lineSpacing
        paragraphStyle.paragraphSpacing = descriptor.paragraphSpacing
        paragraphStyle.alignment = .left

        let font: UIFont
        if descriptor.fontName == "System" {
            font = UIFont.systemFont(ofSize: descriptor.fontSize)
        } else {
            font = UIFont(name: descriptor.fontName, size: descriptor.fontSize)
                ?? UIFont.systemFont(ofSize: descriptor.fontSize)
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        if let foregroundColor {
            attributes[.foregroundColor] = foregroundColor
        }

        return NSAttributedString(string: text, attributes: attributes)
    }

    static func frame(
        framesetter: CTFramesetter,
        range: CFRange,
        containerSize: CGSize
    ) -> CTFrame {
        let path = CGPath(
            rect: CGRect(origin: .zero, size: containerSize),
            transform: nil
        )
        return CTFramesetterCreateFrame(framesetter, range, path, nil)
    }
}

protocol ReaderPaginationServiceProtocol: Sendable {
    func paginate(
        chapters: [Chapter],
        descriptor: PageCacheDescriptor,
        cancellationToken: PaginationCancellationToken?
    ) -> [Page]

    func paginateChapter(
        _ chapter: Chapter,
        chapterIndex: Int,
        descriptor: PageCacheDescriptor,
        cancellationToken: PaginationCancellationToken?
    ) -> [Page]
}

extension ReaderPaginationServiceProtocol {
    func paginate(chapters: [Chapter], descriptor: PageCacheDescriptor) -> [Page] {
        paginate(chapters: chapters, descriptor: descriptor, cancellationToken: nil)
    }

    func paginateChapter(
        _ chapter: Chapter,
        chapterIndex: Int,
        descriptor: PageCacheDescriptor
    ) -> [Page] {
        paginateChapter(
            chapter,
            chapterIndex: chapterIndex,
            descriptor: descriptor,
            cancellationToken: nil
        )
    }
}

/// 轻量、线程安全的分页取消标记。新的排版请求开始时，可让旧任务尽快停止消耗 CPU。
final class PaginationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 纯分页服务：不读写 UI 状态、数据库或缓存，便于独立验证。
final class ReaderPaginationService: ReaderPaginationServiceProtocol {
    func paginate(
        chapters: [Chapter],
        descriptor: PageCacheDescriptor,
        cancellationToken: PaginationCancellationToken? = nil
    ) -> [Page] {
        let textContainerSize = ReaderTextLayout.textContainerSize(for: descriptor)
        var pages: [Page] = []

        for (chapterIndex, chapter) in chapters.enumerated() {
            guard cancellationToken?.isCancelled != true else { return [] }
            pages.append(contentsOf: paginateChapter(
                chapter,
                chapterIndex: chapterIndex,
                descriptor: descriptor,
                textContainerSize: textContainerSize,
                startingGlobalIndex: pages.count,
                cancellationToken: cancellationToken
            ))
        }

        return pages
    }

    func paginateChapter(
        _ chapter: Chapter,
        chapterIndex: Int,
        descriptor: PageCacheDescriptor,
        cancellationToken: PaginationCancellationToken? = nil
    ) -> [Page] {
        paginateChapter(
            chapter,
            chapterIndex: chapterIndex,
            descriptor: descriptor,
            textContainerSize: ReaderTextLayout.textContainerSize(for: descriptor),
            startingGlobalIndex: 0,
            cancellationToken: cancellationToken
        )
    }

    private func paginateChapter(
        _ chapter: Chapter,
        chapterIndex: Int,
        descriptor: PageCacheDescriptor,
        textContainerSize: CGSize,
        startingGlobalIndex: Int,
        cancellationToken: PaginationCancellationToken?
    ) -> [Page] {
        guard !chapter.content.isEmpty else { return [] }

        let content = chapter.content as NSString
        let attributedContent = ReaderTextLayout.attributedString(
            chapter.content,
            descriptor: descriptor
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedContent as CFAttributedString)
        var pages: [Page] = []
        var currentOffset = 0

        while currentOffset < content.length {
            guard cancellationToken?.isCancelled != true else { return [] }
            let remainingLength = content.length - currentOffset
            let frame = ReaderTextLayout.frame(
                framesetter: framesetter,
                range: CFRange(location: currentOffset, length: remainingLength),
                containerSize: textContainerSize
            )
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            let charsInPage = visibleCharacterCount(
                lines: lines,
                frame: frame,
                currentOffset: currentOffset,
                remainingLength: remainingLength,
                pageHeight: textContainerSize.height
            )
            let pageContent = content.substring(
                with: NSRange(location: currentOffset, length: charsInPage)
            )

            pages.append(Page(
                globalIndex: startingGlobalIndex + pages.count,
                content: pageContent,
                chapterIndex: chapterIndex,
                chapterTitle: chapter.title,
                isChapterStart: pages.isEmpty,
                contentOffset: currentOffset
            ))
            currentOffset += charsInPage
        }

        return pages
    }

    private func visibleCharacterCount(
        lines: [CTLine],
        frame: CTFrame,
        currentOffset: Int,
        remainingLength: Int,
        pageHeight: CGFloat
    ) -> Int {
        guard !lines.isEmpty else {
            // 极小页面或不可排版控制字符也必须前进并保留内容。
            return 1
        }

        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &lineOrigins)
        var lastFullyVisibleIndex: Int?

        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(lines[index], &ascent, &descent, &leading)
            let lineTop = lineOrigins[index].y + ascent
            let lineBottom = lineOrigins[index].y - descent
            if lineTop <= pageHeight, lineBottom >= 0 {
                lastFullyVisibleIndex = index
                break
            }
        }

        guard let lastFullyVisibleIndex = lastFullyVisibleIndex else {
            return 1
        }

        let lineRange = CTLineGetStringRange(lines[lastFullyVisibleIndex])
        let visibleLength = (lineRange.location + lineRange.length) - currentOffset
        return max(1, min(visibleLength, remainingLength))
    }
}
