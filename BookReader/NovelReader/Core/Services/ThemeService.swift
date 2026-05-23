import SwiftUI
import Combine

/// 字体设置变化通知
extension Notification.Name {
    static let fontSizeDidChange = Notification.Name("fontSizeDidChange")
    static let lineSpacingDidChange = Notification.Name("lineSpacingDidChange")
}

/// 阅读主题
enum ReaderTheme: String, CaseIterable, Identifiable {
    case light = "light"
    case dark = "dark"
    case sepia = "sepia"
    case eyeCare = "eyeCare"
    
    var id: String { rawValue }
    
    /// 主题名称
    var displayName: String {
        switch self {
        case .light: return "日间"
        case .dark: return "夜间"
        case .sepia: return "羊皮纸"
        case .eyeCare: return "护眼"
        }
    }
    
    /// 背景颜色
    var backgroundColor: Color {
        switch self {
        case .light:
            return Color.white
        case .dark:
            return Color(red: 0.12, green: 0.12, blue: 0.12)
        case .sepia:
            return Color(red: 0.96, green: 0.94, blue: 0.89)
        case .eyeCare:
            return Color(red: 0.95, green: 0.93, blue: 0.88)
        }
    }
    
    /// 文字颜色
    var textColor: Color {
        switch self {
        case .light:
            return Color.black
        case .dark:
            return Color(red: 0.7, green: 0.7, blue: 0.7)
        case .sepia:
            return Color(red: 0.4, green: 0.3, blue: 0.2)
        case .eyeCare:
            return Color(red: 0.35, green: 0.3, blue: 0.25)
        }
    }
    
    /// 文字颜色 (UIColor 版本，用于 UIKit)
    var textColorUI: UIColor {
        switch self {
        case .light:
            return UIColor.black
        case .dark:
            return UIColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1.0)
        case .sepia:
            return UIColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1.0)
        case .eyeCare:
            return UIColor(red: 0.35, green: 0.3, blue: 0.25, alpha: 1.0)
        }
    }
    
    /// 次要文字颜色
    var secondaryTextColor: Color {
        switch self {
        case .light:
            return Color.gray
        case .dark:
            return Color(red: 0.5, green: 0.5, blue: 0.5)
        case .sepia:
            return Color(red: 0.6, green: 0.5, blue: 0.4)
        case .eyeCare:
            return Color(red: 0.55, green: 0.5, blue: 0.45)
        }
    }
}

/// 主题服务
class ThemeService: ObservableObject {
    static let shared = ThemeService()
    
    @Published var currentTheme: ReaderTheme = .light
    @Published var fontSize: CGFloat = 18
    @Published var lineSpacing: CGFloat = 8
    @Published var paragraphSpacing: CGFloat = 16
    @Published var pageMargins: EdgeInsets = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    
    private let userDefaults = UserDefaults.standard
    private let kThemeKey = "reader.theme"
    private let kFontSizeKey = "reader.fontSize"
    private let kLineSpacingKey = "reader.lineSpacing"
    
    // 去抖动：避免Slider拖动时频繁触发重分页
    private var fontSizeDebounceWork: DispatchWorkItem?
    private var lineSpacingDebounceWork: DispatchWorkItem?
    
    private init() {}
    
    /// 初始化主题设置
    func initialize() {
        // 加载保存的主题
        if let themeRaw = userDefaults.string(forKey: kThemeKey),
           let theme = ReaderTheme(rawValue: themeRaw) {
            currentTheme = theme
        }
        
        // 加载字体大小
        let savedFontSize = userDefaults.double(forKey: kFontSizeKey)
        if savedFontSize > 0 {
            fontSize = CGFloat(savedFontSize)
        }
        
        // 加载行间距
        let savedLineSpacing = userDefaults.double(forKey: kLineSpacingKey)
        if savedLineSpacing > 0 {
            lineSpacing = CGFloat(savedLineSpacing)
        }
    }
    
    /// 设置主题
    func setTheme(_ theme: ReaderTheme) {
        currentTheme = theme
        userDefaults.set(theme.rawValue, forKey: kThemeKey)
    }
    
    /// 设置字体大小（立即更新UI，延迟0.15秒触发重分页）
    func setFontSize(_ size: CGFloat) {
        fontSize = max(12, min(32, size))
        userDefaults.set(Double(fontSize), forKey: kFontSizeKey)
        // 去抖动：取消之前的任务，0.15秒后发送通知
        fontSizeDebounceWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .fontSizeDidChange, object: nil)
        }
        fontSizeDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    
    /// 设置行间距（立即更新UI，延迟0.15秒触发重分页）
    func setLineSpacing(_ spacing: CGFloat) {
        lineSpacing = max(0, min(20, spacing))
        userDefaults.set(Double(lineSpacing), forKey: kLineSpacingKey)
        // 去抖动：取消之前的任务，0.15秒后发送通知
        lineSpacingDebounceWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .lineSpacingDidChange, object: nil)
        }
        lineSpacingDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    
    /// 增加字体大小
    func increaseFontSize() {
        setFontSize(fontSize + 2)
    }
    
    /// 减小字体大小
    func decreaseFontSize() {
        setFontSize(fontSize - 2)
    }
    
    /// 获取阅读属性字符串样式
    func textAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = paragraphSpacing
        paragraphStyle.alignment = .justified
        
        return [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: currentTheme.textColorUI,
            .paragraphStyle: paragraphStyle
        ]
    }
}
