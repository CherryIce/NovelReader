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

protocol ReaderPaginationServiceProtocol {
    func paginate(chapters: [Chapter], descriptor: PageCacheDescriptor) -> [Page]
}

/// 纯分页服务：不读写 UI 状态、数据库或缓存，便于独立验证。
final class ReaderPaginationService: ReaderPaginationServiceProtocol {
    func paginate(chapters: [Chapter], descriptor: PageCacheDescriptor) -> [Page] {
        let textContainerSize = ReaderTextLayout.textContainerSize(for: descriptor)
        var pages: [Page] = []

        for (chapterIndex, chapter) in chapters.enumerated() {
            pages.append(contentsOf: paginateChapter(
                chapter,
                chapterIndex: chapterIndex,
                descriptor: descriptor,
                textContainerSize: textContainerSize,
                startingGlobalIndex: pages.count
            ))
        }

        return pages
    }

    private func paginateChapter(
        _ chapter: Chapter,
        chapterIndex: Int,
        descriptor: PageCacheDescriptor,
        textContainerSize: CGSize,
        startingGlobalIndex: Int
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
