import Foundation

/// 一段划线内容的稳定标识。相同书籍、章节和 UTF-16 范围共享同一个详情页。
struct ReaderAnnotationKey: Hashable, Identifiable {
    let bookId: UUID
    let chapterIndex: Int
    let location: Int
    let length: Int

    var id: ReaderAnnotationKey { self }

    var range: NSRange {
        NSRange(location: location, length: length)
    }

    init(bookmark: Bookmark) {
        bookId = bookmark.bookId
        chapterIndex = bookmark.chapterIndex
        location = bookmark.location
        length = bookmark.length
    }

    func contains(utf16Offset: Int) -> Bool {
        NSLocationInRange(utf16Offset, range)
    }
}

/// 将同一段原文的普通划线和多条想法组合成一个阅读批注。
struct ReaderAnnotationGroup: Identifiable, Equatable {
    static let maximumThoughtCount = 5

    let key: ReaderAnnotationKey
    let records: [Bookmark]

    var id: ReaderAnnotationKey { key }

    var thoughts: [Bookmark] {
        records
            .filter { $0.type == .note && $0.note?.isEmpty == false }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var canAddThought: Bool {
        thoughts.count < Self.maximumThoughtCount
    }

    var selectedText: String {
        records
            .lazy
            .compactMap(\.selectedText)
            .first { !$0.isEmpty } ?? ""
    }

    var updatedAt: Date {
        records.map(\.updatedAt).max() ?? .distantPast
    }

    static func groups(from bookmarks: [Bookmark]) -> [ReaderAnnotationGroup] {
        let annotations = bookmarks.filter {
            ($0.type == .highlight || $0.type == .note) && $0.length > 0
        }
        return Dictionary(grouping: annotations, by: ReaderAnnotationKey.init(bookmark:))
            .map { ReaderAnnotationGroup(key: $0.key, records: $0.value) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
