import SwiftUI
import MobileCoreServices

struct LibraryView: View {
    @ObservedObject private var viewModel = LibraryViewModel()
    @State private var showingDocumentPicker = false
    @State private var sheetId = UUID()
    @State private var selectedBook: Book?
    @State private var showingReader = false
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
                DocumentPicker { url in
                    viewModel.importBook(from: url)
                }
            }
            .id(sheetId)
            // 使用 UIKit 桥接实现全屏模态展示（iOS 13 兼容）
            .background(
                FullScreenCover(
                    isPresented: $showingReader,
                    selectedBook: $selectedBook
                )
            )
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
            .edgesIgnoringSafeArea(.all)
    }
    
    private var contentLayer: some View {
        VStack(spacing: 0) {
            bookGrid
        }
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
                        showingReader = true
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
        Button(action: {
            sheetId = UUID()
            showingDocumentPicker = true
        }) {
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

struct BookCell: View {
    let book: Book
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 封面
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.15))
                    .aspectRatio(3/4, contentMode: .fit)
                
                if let coverPath = book.coverImagePath,
                   let image = UIImage(contentsOfFile: coverPath) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .cornerRadius(8)
                }else {
                    Text(book.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center) // 建议：多行文本内部也居中
                        .padding(8) // 建议：增加内边距，防止文字贴边
                }
                
                // 已读完标识
                if book.readingStatus == .completed {
                    Text("已读完")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .cornerRadius(4)
                        .padding(6)
                    // 2. 核心修改：通过 frame 将该标签单独推到左上角
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
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
                    ActivityIndicator(isAnimating: true, style: .medium)
                    
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

// MARK: - Full Screen Cover (iOS 13 兼容)

struct FullScreenCover: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedBook: Book?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.update(uiViewController: uiViewController, isPresented: isPresented, selectedBook: selectedBook)
    }
    
    class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var parent: FullScreenCover
        var isDismissing = false
        
        init(_ parent: FullScreenCover) {
            self.parent = parent
            super.init()
        }
        
        func update(uiViewController: UIViewController, isPresented: Bool, selectedBook: Book?) {
            if isPresented {
                if uiViewController.presentedViewController == nil && !isDismissing {
                    guard let book = selectedBook else { return }
                    let readerView = ReaderView(book: book)
                    let hostingController = UIHostingController(rootView: readerView)
                    hostingController.modalPresentationStyle = .fullScreen
                    
                    // 监听 dismiss 事件
                    hostingController.presentationController?.delegate = self
                    
                    uiViewController.present(hostingController, animated: true)
                }
            } else {
                if let presented = uiViewController.presentedViewController, !isDismissing {
                    isDismissing = true
                    presented.dismiss(animated: true) { [weak self] in
                        self?.isDismissing = false
                    }
                }
            }
        }
        
        // MARK: - UIAdaptivePresentationControllerDelegate
        
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            // 当用户通过手势或点击背景关闭时，同步状态
            parent.isPresented = false
            parent.selectedBook = nil
            isDismissing = false
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 支持 TXT、EPUB、PDF 三种格式
        let supportedTypes: [String] = [
            kUTTypeText as String,           // public.plain-text (TXT)
            "org.idpf.epub-container",       // EPUB
            "com.adobe.pdf"                 // PDF
        ]
        let picker = UIDocumentPickerViewController(
            documentTypes: supportedTypes,
            in: .open
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        // 设置为全屏展示，铺满屏幕
        picker.modalPresentationStyle = .fullScreen
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

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 不需要手动 dismiss 或重置状态，.id() 机制确保下次弹出时 sheet 全新创建
        }
    }
}

// MARK: - Previews

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
