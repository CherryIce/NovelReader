import SwiftUI

struct BookmarkListView: View {
    let bookmarks: [Bookmark]
    let chapters: [Chapter]
    let onSelect: (Bookmark) -> Void
    let onDelete: (Bookmark) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            contentView
                .navigationBarTitle("书签", displayMode: .inline)
                .navigationBarItems(trailing: Button("完成") {
                    dismiss()
                })
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if regularBookmarks.isEmpty {
            emptyView
        } else {
            bookmarkList
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("暂无书签")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("阅读时点击书签按钮，可记录当前阅读位置")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var bookmarkList: some View {
        List {
            ForEach(regularBookmarks, id: \.id) { bookmark in
                bookmarkRow(for: bookmark)
            }
        }
    }

    private var regularBookmarks: [Bookmark] {
        bookmarks.filter { $0.type == .bookmark }
    }

    private func bookmarkRow(for bookmark: Bookmark) -> some View {
        Button(action: { onSelect(bookmark) }) {
            BookmarkRowContent(
                bookmark: bookmark,
                chapterTitle: chapterTitle(for: bookmark.chapterIndex)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDelete(bookmark)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func chapterTitle(for index: Int) -> String {
        guard index >= 0 && index < chapters.count else {
            return "未知章节"
        }
        return chapters[index].title
    }
}

// MARK: - 书签行内容

struct BookmarkRowContent: View {
    let bookmark: Bookmark
    let chapterTitle: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chapterTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(typeTitle)
                        .font(.caption2)
                        .foregroundColor(iconColor)
                }

                if let preview = bookmark.selectedText, !preview.isEmpty {
                    Text(preview.count > 40 ? String(preview.prefix(40)) + "…" : preview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Text(formatDate(bookmark.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.top, 4)
        }
    }

    private var iconName: String {
        "bookmark.fill"
    }

    private var iconColor: Color {
        .accentColor
    }

    private var typeTitle: String {
        "书签"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
