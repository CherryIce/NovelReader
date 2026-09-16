import Foundation

/// 页面缓存数据（用于序列化）
struct CachedPage: Codable {
    let globalIndex: Int
    let contentLength: Int
    let chapterIndex: Int
    let chapterTitle: String
    let isChapterStart: Bool
    let contentOffset: Int
}

/// 影响分页结果的全部输入，用于校验缓存是否仍然可用
struct PageCacheDescriptor: Codable, Equatable {
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let fontName: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let horizontalPadding: CGFloat
    let headerHeight: CGFloat
    let contentTopPadding: CGFloat
    let footerHeight: CGFloat
    let sourceModificationTime: TimeInterval
}

/// 缓存包装结构（包含版本号和完整分页配置）
struct CachedPageData: Codable {
    let version: Int
    let descriptor: PageCacheDescriptor
    let pages: [CachedPage]
}

/// 分页缓存管理器
class PageCacheManager {
    static let shared = PageCacheManager()
    
    /// 缓存版本号 - 当分页算法变更时递增，使旧缓存自动失效
    private let cacheVersion = 8
    
    private let fileManager = FileManager.default
    private let cacheDirectoryName = "PageCache"
    
    private init() {}
    
    /// 获取缓存目录
    private var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let cacheDir = caches.appendingPathComponent(cacheDirectoryName)
        
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
    ///   - expectedDescriptor: 当前分页配置，任一输入变化都会使缓存失效
    func loadCache(
        for bookId: UUID,
        expectedDescriptor: PageCacheDescriptor,
        chapters: [Chapter]
    ) -> [Page]? {
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
            // 分页输入不匹配，缓存失效
            if cachedData.descriptor != expectedDescriptor {
                try? fileManager.removeItem(at: path)
                return nil
            }
            var pages: [Page] = []
            pages.reserveCapacity(cachedData.pages.count)
            let chapterContents = chapters.map { $0.content as NSString }
            var nextContentOffsets = [Int](repeating: 0, count: chapters.count)
            var previousPage: CachedPage?
            for (expectedGlobalIndex, cached) in cachedData.pages.enumerated() {
                let followsReadingOrder = previousPage.map { previous in
                    cached.chapterIndex > previous.chapterIndex
                        || (cached.chapterIndex == previous.chapterIndex
                            && cached.contentOffset > previous.contentOffset)
                } ?? true
                guard cached.globalIndex == expectedGlobalIndex,
                      followsReadingOrder,
                      chapters.indices.contains(cached.chapterIndex) else {
                    try? fileManager.removeItem(at: path)
                    return nil
                }
                let chapterContent = chapterContents[cached.chapterIndex]
                let range = NSRange(location: cached.contentOffset, length: cached.contentLength)
                guard range.location == nextContentOffsets[cached.chapterIndex],
                      range.location <= chapterContent.length,
                      range.length > 0,
                      range.length <= chapterContent.length - range.location,
                      cached.chapterTitle == chapters[cached.chapterIndex].title,
                      cached.isChapterStart == (range.location == 0) else {
                    try? fileManager.removeItem(at: path)
                    return nil
                }
                pages.append(Page(
                    globalIndex: cached.globalIndex,
                    content: chapterContent.substring(with: range),
                    chapterIndex: cached.chapterIndex,
                    chapterTitle: cached.chapterTitle,
                    isChapterStart: cached.isChapterStart,
                    contentOffset: cached.contentOffset
                ))
                nextContentOffsets[cached.chapterIndex] += range.length
                previousPage = cached
            }
            guard zip(nextContentOffsets, chapterContents).allSatisfy({ $0.0 == $0.1.length }) else {
                try? fileManager.removeItem(at: path)
                return nil
            }
            return pages
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
    ///   - descriptor: 生成这些页面时使用的分页配置
    func saveCache(pages: [Page], for bookId: UUID, descriptor: PageCacheDescriptor) {
        let path = cacheFilePath(for: bookId)
        
        // 转换为可序列化的 CachedPage
        let cachedPages = pages.map { page in
            CachedPage(
                globalIndex: page.globalIndex,
                contentLength: (page.content as NSString).length,
                chapterIndex: page.chapterIndex,
                chapterTitle: page.chapterTitle,
                isChapterStart: page.isChapterStart,
                contentOffset: page.contentOffset
            )
        }
        
        let cachedData = CachedPageData(version: cacheVersion, descriptor: descriptor, pages: cachedPages)
        
        guard let data = try? JSONEncoder().encode(cachedData) else {
            print("Failed to encode pages for cache")
            return
        }
        
        do {
            try data.write(to: path, options: .atomic)
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
