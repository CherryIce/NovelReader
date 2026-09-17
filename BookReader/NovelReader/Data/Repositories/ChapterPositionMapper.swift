import Foundation

struct ChapterPosition: Equatable {
    let chapterIndex: Int
    let contentOffset: Int
}

/// 旧目录的每段正文仍按原顺序存在于新目录中，以正文片段定位阅读位置。
struct ChapterPositionMapper {
    private let oldChapters: [Chapter]
    private let newChapters: [Chapter]
    private let contentStarts: [Int: ChapterPosition]

    init(oldChapters: [Chapter], newChapters: [Chapter]) {
        let orderedOldChapters = oldChapters.sorted { $0.index < $1.index }
        let orderedNewChapters = newChapters.sorted { $0.index < $1.index }
        self.oldChapters = orderedOldChapters
        self.newChapters = orderedNewChapters

        let newContents = orderedNewChapters.map { $0.content as NSString }
        var starts: [Int: ChapterPosition] = [:]
        var newIndex = 0
        var searchOffset = 0

        for oldChapter in orderedOldChapters {
            guard !newContents.isEmpty else { break }
            if oldChapter.content.isEmpty {
                if let matchingIndex = orderedNewChapters.indices.first(where: {
                    $0 >= newIndex && orderedNewChapters[$0].title == oldChapter.title
                }) {
                    newIndex = matchingIndex
                    searchOffset = 0
                }
                starts[oldChapter.index] = ChapterPosition(
                    chapterIndex: orderedNewChapters[newIndex].index,
                    contentOffset: searchOffset
                )
                continue
            }

            for candidateIndex in newIndex..<newContents.count {
                let newContent = newContents[candidateIndex]
                let start = candidateIndex == newIndex ? searchOffset : 0
                guard start <= newContent.length else { continue }
                let match = newContent.range(
                    of: oldChapter.content,
                    range: NSRange(location: start, length: newContent.length - start)
                )
                guard match.location != NSNotFound else { continue }
                starts[oldChapter.index] = ChapterPosition(
                    chapterIndex: orderedNewChapters[candidateIndex].index,
                    contentOffset: match.location
                )
                newIndex = candidateIndex
                searchOffset = match.location + match.length
                break
            }
        }
        contentStarts = starts
    }

    func map(chapterIndex: Int, contentOffset: Int) -> ChapterPosition? {
        guard let oldChapter = oldChapters.first(where: { $0.index == chapterIndex }),
              let start = contentStarts[chapterIndex],
              let newChapter = newChapters.first(where: { $0.index == start.chapterIndex }) else {
            return nil
        }
        let oldLength = (oldChapter.content as NSString).length
        let clampedOffset = min(max(0, contentOffset), oldLength)
        let newLength = (newChapter.content as NSString).length
        return ChapterPosition(
            chapterIndex: start.chapterIndex,
            contentOffset: min(start.contentOffset + clampedOffset, newLength)
        )
    }
}
