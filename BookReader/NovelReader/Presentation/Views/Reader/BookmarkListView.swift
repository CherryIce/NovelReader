import SwiftUI

struct BookmarkListView: View {
    let bookmarks: [Bookmark]
    let chapters: [Chapter]
    let onSelect: (Bookmark) -> Void
    let onDelete: (Bookmark) -> Void
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            contentView
                .navigationBarTitle("书签列表", displayMode: .inline)
                .navigationBarItems(trailing: Button("完成") {
                    presentationMode.wrappedValue.dismiss()
                })
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if bookmarks.isEmpty {
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
            Text("阅读时点击书签图标可添加")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var bookmarkList: some View {
        List {
            ForEach(bookmarks, id: \.id) { bookmark in
                bookmarkRow(for: bookmark)
            }
        }
    }
    
    private func bookmarkRow(for bookmark: Bookmark) -> some View {
        if #available(iOS 15.0, *) {
            return Button(action: { onSelect(bookmark) }) {
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
        } else {
            // Fallback on earlier versions
            return HStack {
                BookmarkRowContent(
                    bookmark: bookmark,
                    chapterTitle: chapterTitle(for: bookmark.chapterIndex)
                )
                
                Spacer()
                
                Button(action: {
                    onDelete(bookmark)
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .padding(.leading, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(bookmark)
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(chapterTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let preview = bookmark.selectedText {
                    Text(String(preview.prefix(40)) + "...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Text(formatDate(bookmark.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
