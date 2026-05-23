import SwiftUI

/// 字体服务
class FontService: ObservableObject {
    static let shared = FontService()
    
    /// 可用字体列表
    private(set) var availableFonts: [String] = []
    
    /// 当前选中的字体
    @Published var currentFont: String = "System"
    
    private let userDefaults = UserDefaults.standard
    private let kCurrentFontKey = "reader.currentFont"
    
    private init() {}
    
    /// 初始化字体服务
    func initialize() {
        // 加载系统字体
        loadSystemFonts()
        
        // 加载自定义字体
        loadCustomFonts()
        
        // 恢复上次选择的字体
        if let savedFont = userDefaults.string(forKey: kCurrentFontKey) {
            currentFont = savedFont
        }
    }
    
    /// 加载系统字体
    private func loadSystemFonts() {
        let systemFonts = [
            "System",
            "PingFang SC",
            "Heiti SC",
            "Songti SC",
            "Kaiti SC"
        ]
        availableFonts.append(contentsOf: systemFonts)
    }
    
    /// 加载自定义字体
    private func loadCustomFonts() {
        // 从Fonts目录加载自定义字体文件
        let fontsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Fonts")
        
        guard let fontsDir = fontsDirectory else { return }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil)
            let fontFiles = files.filter { $0.pathExtension.lowercased() == "ttf" || $0.pathExtension.lowercased() == "otf" }
            
            for fontFile in fontFiles {
                let fontName = fontFile.deletingPathExtension().lastPathComponent
                if !availableFonts.contains(fontName) {
                    availableFonts.append(fontName)
                }
            }
        } catch {
            print("Failed to load custom fonts: \(error)")
        }
    }
    
    /// 设置当前字体
    func setFont(_ fontName: String) {
        currentFont = fontName
        userDefaults.set(fontName, forKey: kCurrentFontKey)
    }
    
    /// 获取UIFont
    func font(size: CGFloat) -> UIFont {
        if currentFont == "System" {
            return UIFont.systemFont(ofSize: size)
        }
        
        if let font = UIFont(name: currentFont, size: size) {
            return font
        }
        
        return UIFont.systemFont(ofSize: size)
    }
    
    /// 导入字体文件
    func importFont(from url: URL) -> Bool {
        guard let fontsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Fonts") else {
            return false
        }
        
        do {
            // 创建Fonts目录
            try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
            
            // 复制字体文件
            let destination = fontsDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            
            // 注册字体
            let fontName = destination.deletingPathExtension().lastPathComponent
            if !availableFonts.contains(fontName) {
                availableFonts.append(fontName)
            }
            
            return true
        } catch {
            print("Failed to import font: \(error)")
            return false
        }
    }
}
