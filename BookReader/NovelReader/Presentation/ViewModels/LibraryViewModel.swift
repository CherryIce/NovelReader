import Foundation
import Combine

/// 书架视图模型
class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var error: BookError?
    @Published var selectedBook: Book?
    
    // 导入状态
    @Published var isImporting: Bool = false
    @Published var importProgress: String = ""
    @Published var importSuccess: Bool = false
    @Published var importedBookTitle: String = ""
    @Published var importingBookTitle: String = ""  // 正在导入的书籍名称，用于显示卡片
    
    private let bookRepository: BookRepositoryProtocol
    private let txtParser = TXTParser()
    private var cancellables = Set<AnyCancellable>()
    
    init(bookRepository: BookRepositoryProtocol = BookRepository()) {
        self.bookRepository = bookRepository
    }
    
    /// 加载书籍列表
    func loadBooks() {
        bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.error = error as? BookError ?? .parseFailed
                    }
                },
                receiveValue: { [weak self] books in
                    self?.books = books
                }
            )
            .store(in: &cancellables)
    }
    
    /// 选择书籍
    func selectBook(_ book: Book) {
        selectedBook = book
    }
    
    /// 导入书籍
    func importBook(from url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "txt" || ext.isEmpty else {
            error = .parseFailed
            return
        }
        
        // 重置导入状态
        importSuccess = false
        importedBookTitle = ""
        
        // 从文件名提取书籍名称（去掉扩展名）
        let bookName = url.deletingPathExtension().lastPathComponent
        importingBookTitle = bookName
        
        // 开始导入，显示进度
        isImporting = true
        importProgress = "正在检查..."
        
        // 启动安全作用域访问（.open 模式需要）
        let accessing = url.startAccessingSecurityScopedResource()
        
        // 检查是否已存在相同文件名的书籍
        let fileName = url.lastPathComponent
        bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] books in
                    guard let self = self else { return }
                    
                    // 检查是否已存在相同文件名的书籍
                    let existingBook = books.first { book in
                        let bookFileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                        return bookFileName == fileName
                    }
                    
                    if existingBook != nil {
                        // 书籍已存在，提示用户
                        self.isImporting = false
                        self.importingBookTitle = ""
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                        self.error = .bookAlreadyExists
                        return
                    }
                    
                    // 继续导入流程（安全作用域由 continueImportBook 统一管理）
                    self.continueImportBook(from: url, accessing: accessing)
                }
            )
            .store(in: &cancellables)
    }
    
    /// 继续导入书籍（去重检查通过后）
    private func continueImportBook(from url: URL, accessing: Bool) {
        // 在后台线程执行耗时操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 确保安全作用域访问被释放
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                // 更新进度：解析文件
                DispatchQueue.main.async {
                    self.importProgress = "正在解析文件..."
                }
                
                // 解析书籍
                let parsedBook = try self.txtParser.parse(fileURL: url)
                
                // 更新进度：复制文件
                DispatchQueue.main.async {
                    self.importProgress = "正在复制文件..."
                }
                
                // 复制到Documents目录
                let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let booksDir = documentsDir.appendingPathComponent("Books")
                try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
                
                let destinationURL = booksDir.appendingPathComponent(url.lastPathComponent)
                
                // 如果目标文件已存在，先删除
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
                
                // 更新进度：保存到数据库
                DispatchQueue.main.async {
                    self.importProgress = "正在保存..."
                }
                
                // 创建书籍实体
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                let book = Book(
                    title: parsedBook.title,
                    author: parsedBook.author,
                    filePath: destinationURL.path,
                    format: .txt,
                    fileSize: fileSize
                )
                
                // 保存到数据库（Core Data 操作需要在主线程）
                DispatchQueue.main.async {
                    self.bookRepository.addBook(book)
                        .receive(on: DispatchQueue.main)
                        .sink(
                            receiveCompletion: { [weak self] completion in
                                if case .failure(let error) = completion {
                                    self?.isImporting = false
                                    self?.error = error as? BookError ?? .parseFailed
                                }
                            },
                            receiveValue: { [weak self] _ in
                                guard let self = self else { return }
                                self.isImporting = false
                                self.importingBookTitle = ""
                                self.importSuccess = true
                                self.importedBookTitle = book.title
                                self.loadBooks()
                            }
                        )
                        .store(in: &self.cancellables)
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.importingBookTitle = ""
                    self.error = error as? BookError ?? .parseFailed
                }
            }
        }
    }
    
    /// 删除书籍（包括数据库记录、本地文件和缓存）
    func deleteBook(_ book: Book) {
        // 1. 删除本地文件
        let fileURL = URL(fileURLWithPath: book.filePath)
        try? FileManager.default.removeItem(at: fileURL)
        
        // 2. 清除分页缓存
        PageCacheManager.shared.clearCache(for: book.id)
        
        // 3. 删除数据库记录
        bookRepository.deleteBook(byId: book.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] _ in
                    self?.loadBooks()
                }
            )
            .store(in: &cancellables)
    }
    
    /// 切换收藏状态
    func toggleFavorite(_ book: Book) {
        bookRepository.toggleFavorite(bookId: book.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] _ in
                    self?.loadBooks()
                }
            )
            .store(in: &cancellables)
    }
}
