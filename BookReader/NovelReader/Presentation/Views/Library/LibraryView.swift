import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var viewModel = LibraryViewModel()
    @State private var showingDocumentPicker = false
    @State private var selectedBook: Book?
    @State private var bookToDelete: Book?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            ZStack {
                backgroundLayer
                contentLayer
            }
            .navigationBarTitle("书架", displayMode: .automatic)
            .navigationBarItems(trailing: addButton)
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker(contentTypes: [.plainText]) { url in
                    viewModel.importBook(from: url)
                }
            }
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .alert(item: $viewModel.error, content: errorAlert)
            .actionSheet(isPresented: $showingDeleteConfirmation, content: deleteActionSheet)
            .onAppear {
                viewModel.loadBooks()
            }
            .overlay(successToast)
        }
    }
    
    // MARK: - Subviews
    
    private var backgroundLayer: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }
    
    private var contentLayer: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            bookGrid
        }
    }
    
    private var searchBar: some View {
        SearchBar(text: $viewModel.searchQuery)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }
    
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(LibraryFilter.allCases) { filter in
                    FilterButton(
                        title: filter.displayName,
                        isSelected: viewModel.currentFilter == filter
                    ) {
                        viewModel.setFilter(filter)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
    
    private var bookGrid: some View {
        Group {
            if viewModel.books.isEmpty && !viewModel.isImporting {
                EmptyLibraryView()
            } else {
                BooksGridView(
                    books: viewModel.books,
                    isImporting: viewModel.isImporting,
                    importingTitle: viewModel.importingBookTitle,
                    importingProgress: viewModel.importProgress,
                    onSelect: { book in
                        selectedBook = book
                    },
                    onToggleFavorite: { book in
                        viewModel.toggleFavorite(book)
                    },
                    onToggleCompleted: { book in
                        viewModel.toggleCompleted(book)
                    },
                    onDelete: { book in
                        bookToDelete = book
                        showingDeleteConfirmation = true
                    }
                )
            }
        }
    }
    
    private var addButton: some View {
        Button(action: { showingDocumentPicker = true }) {
            Image(systemName: "plus")
        }
    }
    
    private func errorAlert(error: BookError) -> Alert {
        Alert(
            title: Text("错误"),
            message: Text(error.localizedDescription),
            dismissButton: .default(Text("确定"))
        )
    }
    
    private func deleteActionSheet() -> ActionSheet {
        ActionSheet(
            title: Text("确认删除"),
            message: Text("确定要删除《\(bookToDelete?.title ?? "")》吗？此操作不可恢复。"),
            buttons: [
                .destructive(Text("删除")) {
                    if let book = bookToDelete {
                        viewModel.deleteBook(book)
                    }
                },
                .cancel(Text("取消"))
            ]
        )
    }
    
    private var successToast: some View {
        Group {
            if viewModel.importSuccess {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("《\(viewModel.importedBookTitle)》导入成功")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        viewModel.importSuccess = false
                    }
                }
            }
        }
    }
}

// MARK: - Books Grid View

struct BooksGridView: View {
    let books: [Book]
    let isImporting: Bool
    let importingTitle: String
    let importingProgress: String
    let onSelect: (Book) -> Void
    let onToggleFavorite: (Book) -> Void
    let onToggleCompleted: (Book) -> Void
    let onDelete: (Book) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            let columns: CGFloat = 3
            let spacing: CGFloat = 16
            let totalSpacing = (columns - 1) * spacing
            let itemWidth = (geometry.size.width - totalSpacing - 32) / columns
            let totalItems = books.count + (isImporting ? 1 : 0)
            let rowCount = Int(ceil(Double(totalItems) / Double(columns)))
            
            ScrollView {
                VStack(spacing: spacing) {
                    ForEach(0..<rowCount, id: \.self) { rowIndex in
                        BookRowView(
                            rowIndex: rowIndex,
                            columns: Int(columns),
                            books: books,
                            isImporting: isImporting,
                            importingTitle: importingTitle,
                            importingProgress: importingProgress,
                            itemWidth: itemWidth,
                            onSelect: onSelect,
                            onToggleFavorite: onToggleFavorite,
                            onToggleCompleted: onToggleCompleted,
                            onDelete: onDelete
                        )
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Book Row View

struct BookRowView: View {
    let rowIndex: Int
    let columns: Int
    let books: [Book]
    let isImporting: Bool
    let importingTitle: String
    let importingProgress: String
    let itemWidth: CGFloat
    let onSelect: (Book) -> Void
    let onToggleFavorite: (Book) -> Void
    let onToggleCompleted: (Book) -> Void
    let onDelete: (Book) -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<columns, id: \.self) { columnIndex in
                let index = rowIndex * columns + columnIndex
                BookGridItem(
                    index: index,
                    books: books,
                    isImporting: isImporting,
                    importingTitle: importingTitle,
                    importingProgress: importingProgress,
                    itemWidth: itemWidth,
                    onSelect: onSelect,
                    onToggleFavorite: onToggleFavorite,
                    onToggleCompleted: onToggleCompleted,
                    onDelete: onDelete
                )
            }
        }
    }
}

// MARK: - Book Grid Item

struct BookGridItem: View {
    let index: Int
    let books: [Book]
    let isImporting: Bool
    let importingTitle: String
    let importingProgress: String
    let itemWidth: CGFloat
    let onSelect: (Book) -> Void
    let onToggleFavorite: (Book) -> Void
    let onToggleCompleted: (Book) -> Void
    let onDelete: (Book) -> Void
    
    var body: some View {
        Group {
            if index < books.count {
                BookCell(book: books[index])
                    .frame(width: itemWidth)
                    .onTapGesture {
                        onSelect(books[index])
                    }
                    .contextMenu {
                        Button(action: { onToggleFavorite(books[index]) }) {
                            HStack {
                                Image(systemName: books[index].isFavorite ? "heart.slash" : "heart")
                                Text(books[index].isFavorite ? "取消收藏" : "收藏")
                            }
                        }
                        Button(action: { onToggleCompleted(books[index]) }) {
                            HStack {
                                Image(systemName: books[index].readingStatus == .completed ? "arrow.uturn.backward" : "checkmark.circle")
                                Text(books[index].readingStatus == .completed ? "标记为在读" : "标记为已读完")
                            }
                        }
                        Button(action: { onDelete(books[index]) }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("删除")
                            }
                        }
                    }
            } else if index == books.count && isImporting {
                ImportingBookCell(
                    title: importingTitle,
                    progress: importingProgress
                )
                .frame(width: itemWidth)
            } else {
                Color.clear.frame(width: itemWidth)
            }
        }
    }
}

// MARK: - 子视图

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            
            TextField("搜索书籍", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

struct FilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray6))
                .cornerRadius(16)
        }
    }
}

struct BookCell: View {
    let book: Book
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 封面
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .aspectRatio(3/4, contentMode: .fit)
                
                if let coverPath = book.coverImagePath,
                   let image = UIImage(contentsOfFile: coverPath) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .cornerRadius(8)
                } else {
                    VStack {
                        Image(systemName: "book.fill")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text(book.title.prefix(2))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .overlay(
                Group {
                    if book.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(6)
                    }
                },
                alignment: .topTrailing
            )
            
            // 书名
            Text(book.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.primary)

            if book.readingStatus == .completed {
                Text("已读完")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 导入中的书籍卡片

struct ImportingBookCell: View {
    let title: String
    let progress: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 封面占位
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .aspectRatio(3/4, contentMode: .fit)
                
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    
                    Text(progress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
            )
            
            // 书名
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.secondary)
        }
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("书架是空的")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("点击右上角 + 导入书籍")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 预览

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Previews

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
