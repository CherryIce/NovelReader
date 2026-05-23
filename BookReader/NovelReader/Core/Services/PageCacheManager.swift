import Foundation

/// 页面缓存数据（用于序列化）
struct CachedPage: Codable {
    let globalIndex: Int
    let content: String
    let chapterIndex: Int
    let chapterTitle: String
    let isChapterStart: Bool
    let contentOffset: Int
}

/// 缓存包装结构（包含版本号和视图高度）
struct CachedPageData: Codable {
    let version: Int
    let viewHeight: CGFloat
    let pages: [CachedPage]
}

/// 分页缓存管理器
class PageCacheManager {
    static let shared = PageCacheManager()
    
    /// 缓存版本号 - 当分页算法变更时递增，使旧缓存自动失效
    private let cacheVersion = 5
    
    private let fileManager = FileManager.default
    private let cacheDirectoryName = "PageCache"
    
    private init() {}
    
    /// 获取缓存目录
    private var cacheDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let cacheDir = documents.appendingPathComponent(cacheDirectoryName)
        
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        
        return cacheDir
    }
    
    /// 获取书籍的缓存文件路径
    private func cacheFilePath(for bookId: UUID) -> URL {
        return cacheDirectory.appendingPathComponent("\(bookId.uuidString).json")
    }
    
    /// 检查是否有缓存
    func hasCache(for bookId: UUID) -> Bool {
        let path = cacheFilePath(for: bookId)
        return fileManager.fileExists(atPath: path.path)
    }
    
    /// 读取缓存
    /// - Parameters:
    ///   - bookId: 书籍ID
    ///   - expectedViewHeight: 期望的视图高度，如果与缓存中的高度差异超过1pt则缓存失效
    func loadCache(for bookId: UUID, expectedViewHeight: CGFloat? = nil) -> [Page]? {
        let path = cacheFilePath(for: bookId)
        
        guard let data = try? Data(contentsOf: path) else {
            return nil
        }
        
        // 尝试解码带版本号的缓存格式
        if let cachedData = try? JSONDecoder().decode(CachedPageData.self, from: data) {
            // 版本号不匹配，缓存失效
            guard cachedData.version == cacheVersion else {
                print("Cache version mismatch (cached: \(cachedData.version), current: \(cacheVersion)), invalidating cache")
                try? fileManager.removeItem(at: path)
                return nil
            }
            // 视图高度不匹配，缓存失效
            if let expected = expectedViewHeight, abs(cachedData.viewHeight - expected) > 1 {
                print("Cache view height mismatch (cached: \(cachedData.viewHeight), expected: \(expected)), invalidating cache")
                try? fileManager.removeItem(at: path)
                return nil
            }
            return cachedData.pages.map { cached in
                Page(
                    globalIndex: cached.globalIndex,
                    content: cached.content,
                    chapterIndex: cached.chapterIndex,
                    chapterTitle: cached.chapterTitle,
                    isChapterStart: cached.isChapterStart,
                    contentOffset: cached.contentOffset
                )
            }
        }
        
        // 兼容旧版缓存格式（无版本号），直接失效
        print("Old cache format detected, invalidating cache")
        try? fileManager.removeItem(at: path)
        return nil
    }
    
    /// 保存缓存
    /// - Parameters:
    ///   - pages: 页面数据
    ///   - bookId: 书籍ID
    ///   - viewHeight: 当时的视图高度
    func saveCache(pages: [Page], for bookId: UUID, viewHeight: CGFloat = 0) {
        let path = cacheFilePath(for: bookId)
        
        // 转换为可序列化的 CachedPage
        let cachedPages = pages.map { page in
            CachedPage(
                globalIndex: page.globalIndex,
                content: page.content,
                chapterIndex: page.chapterIndex,
                chapterTitle: page.chapterTitle,
                isChapterStart: page.isChapterStart,
                contentOffset: page.contentOffset
            )
        }
        
        // 使用带版本号和视图高度的包装结构
        let cachedData = CachedPageData(version: cacheVersion, viewHeight: viewHeight, pages: cachedPages)
        
        guard let data = try? JSONEncoder().encode(cachedData) else {
            print("Failed to encode pages for cache")
            return
        }
        
        do {
            try data.write(to: path)
            print("Saved \(pages.count) pages to cache for book \(bookId)")
        } catch {
            print("Failed to save cache: \(error)")
        }
    }
    
    /// 清除指定书籍的缓存
    func clearCache(for bookId: UUID) {
        let path = cacheFilePath(for: bookId)
        try? fileManager.removeItem(at: path)
    }
    
    /// 清除所有缓存
    func clearAllCache() {
        try? fileManager.removeItem(at: cacheDirectory)
    }
}
