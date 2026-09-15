import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var wifiService = WiFiTransferService.shared
    @State private var showingBatchDocumentPicker = false
    @State private var showingWiFiTransfer = false
    @State private var selectedBook: Book?
    @State private var bookToDelete: Book?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationView {
            ZStack {
                backgroundLayer
                contentLayer
                importProgressOverlay
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isImporting)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isBatchImporting)
            .navigationBarTitle("书架", displayMode: .automatic)
            .navigationBarItems(trailing: addButton)
            .fileImporter(
                isPresented: $showingBatchDocumentPicker,
                allowedContentTypes: supportedBookTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    viewModel.importBooks(from: urls)
                case .failure(let error):
                    presentPickerError(error)
                }
            }
            .sheet(isPresented: $showingWiFiTransfer) {
                WiFiTransferView()
            }
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .alert(item: $viewModel.error, content: errorAlert)
            .actionSheet(isPresented: $showingDeleteConfirmation, content: deleteActionSheet)
            .onAppear {
                viewModel.loadBooks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wifiTransferDidReceiveFiles)) { notification in
                guard let urls = notification.userInfo?[WiFiTransferNotificationKey.fileURLs] as? [URL],
                      !urls.isEmpty else {
                    return
                }
                viewModel.importBooks(from: urls, removesSourceWhenFinished: true)
            }
            .overlay(successToast)
            .overlay(batchImportToast)
        }
    }

    // MARK: - Subviews

    private var supportedBookTypes: [UTType] {
        [.plainText, .pdf, UTType(filenameExtension: "epub") ?? .data]
    }

    private func presentPickerError(_ error: Error) {
        let cocoaError = error as NSError
        guard !(cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError) else {
            return
        }
        viewModel.error = .operationFailed(message: error.localizedDescription)
    }

    private var backgroundLayer: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var importProgressOverlay: some View {
        if viewModel.isImporting || viewModel.isBatchImporting {
            ZStack {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.2)

                    Text(viewModel.importingBookTitle.isEmpty ? "正在导入书籍" : viewModel.importingBookTitle)
                        .font(.headline)
                        .lineLimit(1)

                    Text(viewModel.isBatchImporting ? viewModel.batchImportProgress : viewModel.importProgress)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 280)
                .background(Color(.systemBackground))
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("library.importProgress")
            }
            .zIndex(1)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
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
            if viewModel.books.isEmpty && !viewModel.isImporting && !viewModel.isBatchImporting {
                EmptyLibraryView()
            } else {
                BooksGridView(
                    books: viewModel.books,
                    isImporting: viewModel.isImporting || viewModel.isBatchImporting,
                    importingTitle: viewModel.importingBookTitle,
                    importingProgress: viewModel.isBatchImporting
                        ? viewModel.batchImportProgress
                        : viewModel.importProgress,
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
        Menu {
            Button(action: {
                showingBatchDocumentPicker = true
            }) {
                Label("批量导入", systemImage: "doc.on.doc")
            }

            Button(action: {
                showingWiFiTransfer = true
            }) {
                Label("WiFi 传书", systemImage: "wifi")
            }
        } label: {
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

    private var batchImportToast: some View {
        Group {
            if viewModel.batchImportSuccess {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("批量导入完成")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        Text("成功 \(viewModel.batchImportSuccessCount) 个"
                            + (viewModel.batchImportFailCount > 0
                                ? "，失败 \(viewModel.batchImportFailCount) 个"
                                : ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        viewModel.batchImportSuccess = false
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

            Text("点击右上角 + 批量导入")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - WiFi 传书视图

struct WiFiTransferView: View {
    @ObservedObject var wifiService = WiFiTransferService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingHelp = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // 顶部状态图标
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(wifiService.isRunning ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                            .frame(width: 100, height: 100)

                        Image(systemName: wifiService.isRunning ? "wifi" : "wifi.slash")
                            .font(.system(size: 40))
                            .foregroundColor(wifiService.isRunning ? .green : .gray)
                    }

                    Text(wifiService.isRunning ? "传书服务已开启" : "传书服务未开启")
                        .font(.headline)
                        .foregroundColor(wifiService.isRunning ? .green : .secondary)
                }
                .padding(.top, 20)

                // 地址显示
                if wifiService.isRunning, let url = wifiService.serverURL {
                    VStack(spacing: 12) {
                        Text("在电脑浏览器中访问以下地址")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        // 地址卡片
                        HStack {
                            Image(systemName: "link")
                                .foregroundColor(.blue)
                            Text(url)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.blue)
                            Spacer()
                        }
                        .padding(16)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)

                        Button(action: {
                            UIPasteboard.general.string = url
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                Text("复制地址")
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // 上传统计
                if wifiService.isRunning && wifiService.uploadedCount > 0 {
                    HStack(spacing: 16) {
                        StatItem(title: "已上传", value: "\(wifiService.uploadedCount)", icon: "arrow.down.doc")
                        StatItem(title: "总计", value: "\(wifiService.totalUploadCount)", icon: "doc.text")
                    }
                    .padding(.horizontal, 24)
                }

                // 上传日志
                if wifiService.isRunning && !wifiService.uploadLog.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("传输记录")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(wifiService.uploadLog.reversed(), id: \.self) { log in
                                    Text(log)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                // 底部操作按钮
                VStack(spacing: 12) {
                    Button(action: {
                        if wifiService.isRunning {
                            wifiService.stop()
                        } else {
                            let _ = wifiService.start()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: wifiService.isRunning ? "stop.fill" : "play.fill")
                            Text(wifiService.isRunning ? "停止传书" : "开始传书")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(wifiService.isRunning ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    if !wifiService.isRunning {
                        Button(action: { showingHelp = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text("使用帮助")
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
            .navigationBarTitle("WiFi 传书", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") {
                wifiService.stop()
                dismiss()
            })
            .onDisappear {
                wifiService.stop()
            }
            .alert(isPresented: $showingHelp) {
                Alert(
                    title: Text("使用说明"),
                    message: Text("1. 确保手机和电脑连接同一 WiFi 网络\n2. 点击「开始传书」启动服务\n3. 在电脑浏览器中输入显示的完整地址\n4. 在网页中选择文件并上传\n5. 上传完成后 App 会自动导入书架"),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
    }
}

// MARK: - 统计项

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Shared Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let isPresented: Binding<Bool>
        private let onPick: (URL) -> Void

        init(isPresented: Binding<Bool>, onPick: @escaping (URL) -> Void) {
            self.isPresented = isPresented
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
            isPresented.wrappedValue = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            isPresented.wrappedValue = false
        }
    }
}

// MARK: - Previews

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
