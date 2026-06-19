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
    
    // 批量导入状态
    @Published var isBatchImporting: Bool = false
    @Published var batchImportProgress: String = ""
    @Published var batchImportTotal: Int = 0
    @Published var batchImportCurrent: Int = 0
    @Published var batchImportSuccess: Bool = false
    @Published var batchImportSuccessCount: Int = 0
    @Published var batchImportFailCount: Int = 0
    @Published var batchImportFailedTitles: [String] = []
    
    private let bookRepository: BookRepositoryProtocol
    private let txtParser = TXTParser()
    private let epubParser = EPUBParser()
    private let pdfParser = PDFParser()
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
        guard ["txt", "epub", "pdf"].contains(ext) || ext.isEmpty else {
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
    
    /// 批量导入书籍
    func importBooks(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        
        // 重置批量导入状态
        batchImportSuccess = false
        batchImportSuccessCount = 0
        batchImportFailCount = 0
        batchImportFailedTitles = []
        batchImportTotal = urls.count
        batchImportCurrent = 0
        isBatchImporting = true
        batchImportProgress = "正在检查 \(urls.count) 个文件..."
        
        // 启动所有文件的安全作用域访问
        var accessTokens: [(url: URL, accessing: Bool)] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            accessTokens.append((url: url, accessing: accessing))
        }
        
        // 先获取已有书籍列表用于去重
        bookRepository.getAllBooks()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] existingBooks in
                    guard let self = self else { return }
                    
                    let existingFileNames = Set(existingBooks.map { book in
                        URL(fileURLWithPath: book.filePath).lastPathComponent
                    })
                    
                    // 过滤掉已存在的文件
                    let urlsToImport = accessTokens.filter { token in
                        let fileName = token.url.lastPathComponent
                        return !existingFileNames.contains(fileName)
                    }.map { $0.url }
                    
                    // 释放不需要导入的文件的安全作用域
                    for token in accessTokens {
                        if !urlsToImport.contains(token.url) && token.accessing {
                            token.url.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    if urlsToImport.isEmpty {
                        self.isBatchImporting = false
                        self.batchImportProgress = ""
                        self.error = .bookAlreadyExists
                        return
                    }
                    
                    self.batchImportTotal = urlsToImport.count
                    self.batchImportCurrent = 0
                    self.batchImportProgress = "准备导入 \(urlsToImport.count) 个文件..."
                    
                    // 在后台线程逐个导入
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.processBatchImport(urls: urlsToImport)
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    /// 处理批量导入（在后台线程执行）
    private func processBatchImport(urls: [URL]) {
        var successCount = 0
        var failCount = 0
        var failedTitles: [String] = []
        
        for (index, url) in urls.enumerated() {
            let bookName = url.deletingPathExtension().lastPathComponent
            
            DispatchQueue.main.async {
                self.batchImportCurrent = index + 1
                self.batchImportProgress = "正在导入 (\(index + 1)/\(urls.count)): \(bookName)"
                self.importingBookTitle = bookName
            }
            
            let result = importSingleBook(from: url)
            
            switch result {
            case .success:
                successCount += 1
            case .failure(let title):
                failCount += 1
                failedTitles.append(title)
            }
        }
        
        DispatchQueue.main.async {
            self.isBatchImporting = false
            self.batchImportProgress = ""
            self.importingBookTitle = ""
            self.batchImportSuccess = true
            self.batchImportSuccessCount = successCount
            self.batchImportFailCount = failCount
            self.batchImportFailedTitles = failedTitles
            self.loadBooks()
        }
    }
    
    /// 导入单个书籍（同步方法，用于批量导入）
    private enum ImportResult {
        case success
        case failure(String)
    }
    
    private func importSingleBook(from url: URL) -> ImportResult {
        let ext = url.pathExtension.lowercased()
        guard ["txt", "epub", "pdf"].contains(ext) || ext.isEmpty else {
            return .failure(url.lastPathComponent)
        }
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            // 解析书籍
            let parsedBook: ParsedBook
            switch ext {
            case "epub":
                parsedBook = try epubParser.parse(fileURL: url)
            case "pdf":
                parsedBook = try pdfParser.parse(fileURL: url)
            default:
                parsedBook = try txtParser.parse(fileURL: url)
            }
            
            // 复制到 Documents 目录
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let booksDir = documentsDir.appendingPathComponent("Books")
            try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
            
            let destinationURL = booksDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: url, to: destinationURL)
            
            // 创建书籍实体
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
            let book = Book(
                title: parsedBook.title,
                author: parsedBook.author,
                filePath: destinationURL.path,
                format: parsedBook.format,
                fileSize: fileSize
            )
            
            // 保存到数据库（同步方式，使用 Core Data context）
            let semaphore = DispatchSemaphore(value: 0)
            var saveError: Error?
            
            DispatchQueue.main.async {
                self.bookRepository.addBook(book)
                    .receive(on: DispatchQueue.main)
                    .sink(
                        receiveCompletion: { completion in
                            if case .failure(let error) = completion {
                                saveError = error
                            }
                            semaphore.signal()
                        },
                        receiveValue: { _ in
                            semaphore.signal()
                        }
                    )
                    .store(in: &self.cancellables)
            }
            
            semaphore.wait()
            
            if let saveError = saveError {
                return .failure("\(url.lastPathComponent): \(saveError.localizedDescription)")
            }
            
            return .success
        } catch {
            return .failure("\(url.lastPathComponent): \(error.localizedDescription)")
        }
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
                
                // 解析书籍（根据格式选择解析器）
                let parsedBook: ParsedBook
                let fileExt = url.pathExtension.lowercased()
                switch fileExt {
                case "epub":
                    parsedBook = try self.epubParser.parse(fileURL: url)
                case "pdf":
                    parsedBook = try self.pdfParser.parse(fileURL: url)
                default:
                    parsedBook = try self.txtParser.parse(fileURL: url)
                }
                
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
                    format: parsedBook.format,
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
