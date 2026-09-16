import Foundation

/// 阅读正文中的临时选区。偏移量统一使用 NSString/Core Text 的 UTF-16 坐标系。
struct ReaderTextSelection: Equatable {
    let chapterIndex: Int
    var anchorOffset: Int
    var focusOffset: Int

    var lowerBound: Int {
        min(anchorOffset, focusOffset)
    }

    var upperBound: Int {
        max(anchorOffset, focusOffset)
    }

    var range: NSRange {
        NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    var isEmpty: Bool {
        lowerBound == upperBound
    }

    func localRange(in page: Page) -> NSRange? {
        guard page.chapterIndex == chapterIndex else { return nil }
        return ReaderTextRangeMath.localIntersection(
            selectionRange: range,
            pageOffset: page.contentOffset,
            pageLength: (page.content as NSString).length
        )
    }
}

enum ReaderTextMarkStyle: Equatable {
    case active
    case highlight
    case note
}

struct ReaderTextMark: Equatable {
    let range: NSRange
    let style: ReaderTextMarkStyle
}

enum ReaderPageTapTarget: Equatable {
    case toolbar
    case annotation
    case none
}

enum ReaderPageTapRouting {
    /// 页边留白拥有独立的工具栏入口；正文内再区分划线与普通中部点击。
    static func target(
        isToolbarSafeArea: Bool,
        isAnnotationHit: Bool,
        isCenterTap: Bool
    ) -> ReaderPageTapTarget {
        if isToolbarSafeArea {
            return .toolbar
        }
        if isAnnotationHit {
            return .annotation
        }
        return isCenterTap ? .toolbar : .none
    }
}

enum ReaderTextRangeMath {
    static func localIntersection(
        selectionRange: NSRange,
        pageOffset: Int,
        pageLength: Int
    ) -> NSRange? {
        guard selectionRange.length > 0, pageLength > 0 else { return nil }

        let start = max(selectionRange.location, pageOffset)
        let end = min(NSMaxRange(selectionRange), pageOffset + pageLength)
        guard end > start else { return nil }

        return NSRange(location: start - pageOffset, length: end - start)
    }

    /// 长按时优先选择本地化词语；空白和标点退回到完整的 Unicode 字素。
    static func initialRange(in text: String, utf16Offset: Int) -> NSRange {
        let nsText = text as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }

        let location = min(max(utf16Offset, 0), nsText.length - 1)
        var matchedRange: NSRange?

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { _, substringRange, _, stop in
            let candidate = NSRange(substringRange, in: text)
            if NSLocationInRange(location, candidate) {
                matchedRange = candidate
                stop = true
            }
        }

        return matchedRange ?? nsText.rangeOfComposedCharacterSequence(at: location)
    }

    static func composedCharacterBoundary(
        in text: String,
        utf16Offset: Int,
        preferUpperBoundary: Bool
    ) -> Int {
        let nsText = text as NSString
        let offset = min(max(utf16Offset, 0), nsText.length)
        guard offset > 0, offset < nsText.length else { return offset }

        let composedRange = nsText.rangeOfComposedCharacterSequence(at: offset)
        if offset == composedRange.location || offset == NSMaxRange(composedRange) {
            return offset
        }
        return preferUpperBoundary ? NSMaxRange(composedRange) : composedRange.location
    }

    /// 从目标范围中扣除所有已覆盖区间，返回仍可新增划线的非重叠片段。
    static func uncoveredRanges(
        in targetRange: NSRange,
        coveredRanges: [NSRange]
    ) -> [NSRange] {
        guard targetRange.length > 0 else { return [] }

        let targetEnd = NSMaxRange(targetRange)
        let intersections = coveredRanges
            .map { NSIntersectionRange(targetRange, $0) }
            .filter { $0.length > 0 }
            .sorted {
                $0.location == $1.location
                    ? NSMaxRange($0) < NSMaxRange($1)
                    : $0.location < $1.location
            }

        var result: [NSRange] = []
        var cursor = targetRange.location

        for covered in intersections {
            if covered.location > cursor {
                result.append(NSRange(location: cursor, length: covered.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(covered))
            if cursor >= targetEnd { break }
        }

        if cursor < targetEnd {
            result.append(NSRange(location: cursor, length: targetEnd - cursor))
        }
        return result
    }

    /// 把同页批注解析为互不重叠的绘制片段：想法 > 普通划线 > 当前临时选择。
    static func resolvedMarks(
        pageLength: Int,
        persistedMarks: [ReaderTextMark],
        activeRange: NSRange?
    ) -> [ReaderTextMark] {
        guard pageLength > 0 else { return [] }
        var styles = [ReaderTextMarkStyle?](repeating: nil, count: pageLength)

        for mark in persistedMarks {
            let clipped = NSIntersectionRange(
                mark.range,
                NSRange(location: 0, length: pageLength)
            )
            guard clipped.length > 0 else { continue }

            for index in clipped.location..<NSMaxRange(clipped) {
                if stylePriority(mark.style) > stylePriority(styles[index]) {
                    styles[index] = mark.style
                }
            }
        }

        if let activeRange {
            let clipped = NSIntersectionRange(
                activeRange,
                NSRange(location: 0, length: pageLength)
            )
            if clipped.length > 0 {
                for index in clipped.location..<NSMaxRange(clipped) where styles[index] == nil {
                    styles[index] = .active
                }
            }
        }

        var result: [ReaderTextMark] = []
        var index = 0
        while index < styles.count {
            guard let style = styles[index] else {
                index += 1
                continue
            }

            let start = index
            index += 1
            while index < styles.count, styles[index] == style {
                index += 1
            }
            result.append(
                ReaderTextMark(
                    range: NSRange(location: start, length: index - start),
                    style: style
                )
            )
        }
        return result
    }

    /// 裁掉一个可视行片段首尾的排版空白，保留正文内部空格。
    static func trimmingLineWhitespace(in text: String, range: NSRange) -> NSRange? {
        let nsText = text as NSString
        let validRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: nsText.length)
        )
        guard validRange.length > 0 else { return nil }

        let whitespace = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\u{3000}")
        )
        var start = validRange.location
        var end = NSMaxRange(validRange)

        while start < end {
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: start)
            let value = nsText.substring(with: composedRange)
            guard value.unicodeScalars.allSatisfy({ whitespace.contains($0) }) else { break }
            start = min(NSMaxRange(composedRange), end)
        }

        while start < end {
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: end - 1)
            let value = nsText.substring(with: composedRange)
            guard value.unicodeScalars.allSatisfy({ whitespace.contains($0) }) else { break }
            end = max(composedRange.location, start)
        }

        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func stylePriority(_ style: ReaderTextMarkStyle?) -> Int {
        switch style {
        case .note:
            return 2
        case .highlight:
            return 1
        case .active, nil:
            return 0
        }
    }
}
