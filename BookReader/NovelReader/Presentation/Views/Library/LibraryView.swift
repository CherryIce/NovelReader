import SwiftUI
import MobileCoreServices

struct LibraryView: View {
    @ObservedObject private var viewModel = LibraryViewModel()
    @ObservedObject private var wifiService = WiFiTransferService.shared
    @State private var showingDocumentPicker = false
    @State private var showingBatchDocumentPicker = false
    @State private var showingWiFiTransfer = false
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
            .sheet(isPresented: $showingBatchDocumentPicker) {
                BatchDocumentPicker { urls in
                    viewModel.importBooks(from: urls)
                }
            }
            .sheet(isPresented: $showingWiFiTransfer) {
                WiFiTransferView()
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
            .overlay(batchImportToast)
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
        Menu {
            Button(action: {
                sheetId = UUID()
                showingDocumentPicker = true
            }) {
                Label("导入书籍", systemImage: "doc.badge.plus")
            }
            
            Button(action: {
                sheetId = UUID()
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

// MARK: - WiFi 传书视图

struct WiFiTransferView: View {
    @ObservedObject var wifiService = WiFiTransferService.shared
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
                            // WiFi 传书结束后刷新书架
                            NotificationCenter.default.post(name: .wifiTransferDidFinish, object: nil)
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
                if wifiService.isRunning {
                    wifiService.stop()
                    NotificationCenter.default.post(name: .wifiTransferDidFinish, object: nil)
                }
            })
            .alert(isPresented: $showingHelp) {
                Alert(
                    title: Text("使用说明"),
                    message: Text("1. 确保手机和电脑连接同一 WiFi 网络\n2. 点击「开始传书」启动服务\n3. 在电脑浏览器中输入显示的地址\n4. 在网页中选择文件并上传\n5. 上传完成后在 App 中刷新书架"),
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

// MARK: - WiFi 传书完成通知

extension Notification.Name {
    static let wifiTransferDidFinish = Notification.Name("wifiTransferDidFinish")
}

// MARK: - Previews

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

// MARK: - Batch Document Picker

struct BatchDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [String] = [
            kUTTypeText as String,
            "org.idpf.epub-container",
            "com.adobe.pdf"
        ]
        let picker = UIDocumentPickerViewController(
            documentTypes: supportedTypes,
            in: .open
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Previews

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
