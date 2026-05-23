# iOS 小说阅读器技术方案

## 项目概述
- **项目名称**: NovelReader
- **开发语言**: Swift 5.9+
- **最低版本**: iOS 13.0+
- **UI框架**: SwiftUI + UIKit 混编
- **架构模式**: MVVM + Clean Architecture

---

## 一、技术栈选型

| 层级 | 技术选择 | 说明 |
|------|----------|------|
| **开发语言** | Swift 5.9+ | 现代Swift特性，性能优秀 |
| **UI框架** | SwiftUI + UIKit 混编 | SwiftUI主导，UIKit处理复杂文本渲染 |
| **最低版本** | iOS 13.0+ | 支持SwiftUI基础功能 |
| **架构模式** | MVVM + Clean Architecture | 清晰分层，便于测试维护 |
| **数据存储** | Core Data + UserDefaults | 书籍数据+用户配置 |
| **依赖管理** | Swift Package Manager | Apple原生支持 |
| **网络层** | URLSession + Combine | 原生框架，响应式编程 |
| **文本渲染** | TextKit 2 (iOS 15+) / TextKit 1 | 专业文本排版引擎 |

---

## 二、项目结构

```
NovelReader/
├── App/
│   ├── NovelReaderApp.swift          # App入口
│   ├── AppDelegate.swift             # 生命周期处理
│   └── SceneDelegate.swift           # 场景管理
│
├── Presentation/                      # 表现层 (MVVM)
│   ├── Views/                         # SwiftUI视图
│   │   ├── Library/                   # 书架模块
│   │   ├── Reader/                    # 阅读器模块
│   │   ├── Catalog/                   # 目录模块
│   │   ├── Search/                    # 搜索模块
│   │   └── Settings/                  # 设置模块
│   └── ViewModels/                    # 视图模型
│       ├── LibraryViewModel.swift
│       ├── ReaderViewModel.swift
│       └── ...
│
├── Domain/                            # 领域层 (Clean Architecture)
│   ├── Entities/                      # 实体模型
│   │   ├── Book.swift
│   │   ├── Chapter.swift
│   │   └── Bookmark.swift
│   ├── UseCases/                      # 业务用例
│   │   ├── LoadBookUseCase.swift
│   │   ├── SaveProgressUseCase.swift
│   │   └── ...
│   └── RepositoryInterfaces/          # 仓库协议
│       ├── BookRepositoryProtocol.swift
│       └── ...
│
├── Data/                              # 数据层
│   ├── Repositories/                  # 仓库实现
│   ├── Local/                         # 本地数据源
│   │   ├── CoreData/                  # Core Data模型
│   │   ├── FileStorage/               # 文件存储
│   │   └── UserDefaults/              # 偏好设置
│   ├── Remote/                        # 远程数据源
│   │   ├── API/                       # 网络接口
│   │   └── Models/                    # DTO模型
│   └── Parsers/                       # 格式解析器
│       ├── EPUBParser/
│       ├── TXTParser/
│       └── ...
│
├── Core/                              # 核心基础设施
│   ├── Extensions/                    # 扩展
│   ├── Utilities/                     # 工具类
│   ├── UIComponents/                  # 通用UI组件
│   └── Services/                      # 系统服务
│       ├── ThemeService.swift
│       ├── FontService.swift
│       └── ...
│
└── Resources/                         # 资源文件
    ├── Assets.xcassets
    ├── Localizable.strings
    └── Fonts/
```

---

## 三、核心技术开发点

### 1. 文本渲染引擎

| 技术点 | 方案 | 难度 |
|--------|------|------|
| 分页算法 | 基于TextKit的`NSLayoutManager`计算文本分页 | ⭐⭐⭐⭐ |
| 富文本支持 | `NSAttributedString` + 自定义属性 | ⭐⭐⭐ |
| 图文混排 | `NSTextAttachment` 处理插图 | ⭐⭐⭐⭐ |
| 竖排支持 | CoreText自定义排版 | ⭐⭐⭐⭐⭐ |
| 字体渲染 | 动态字体加载 + 缓存 | ⭐⭐⭐ |

### 2. 格式解析支持

| 格式 | 技术方案 | 优先级 |
|------|----------|--------|
| **TXT** | 自定义解析器，处理编码检测、章节识别 | P0 |
| **EPUB** | 基于ZIP解压 + XML解析 | P0 |
| **PDF** | PDFKit框架 | P1 |
| **MOBI/AZW3** | 第三方库或暂不实现 | P2 |

### 3. 阅读器核心功能

- **翻页效果**: `UIPageViewController` 或自定义手势翻页动画
- **阅读进度**: 章节内百分比 + 全局百分比双维度
- **书签/笔记**: Core Data持久化，支持导出
- **全文搜索**: 建立倒排索引，支持正则
- **夜间模式**: 动态主题切换，护眼模式
- **字体设置**: 系统字体 + 自定义字体导入

### 4. 数据管理

- **书籍导入**: 文件分享 + iTunes文件共享 + 网络下载
- **书架管理**: 封面缓存、阅读历史、排序筛选
- **阅读记录**: 自动保存进度，多设备同步(iCloud)

### 5. 性能优化

- **大文件处理**: 分块读取，内存映射
- **预加载**: 前后章节预渲染
- **图片缓存**: NSCache + 磁盘缓存
- **流畅度**: 60fps翻页，离屏渲染优化

---

## 四、推荐第三方依赖

```swift
// Package.swift 依赖示例
dependencies: [
    // 网络图片加载
    .package(url: "https://github.com/onevcat/Kingfisher.git", from: "7.0.0"),
    
    // ZIP解压 (EPUB需要)
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    
    // XML解析
    .package(url: "https://github.com/CoreOffice/XMLCoder.git", from: "0.15.0"),
    
    // 编码检测 (TXT文件)
    .package(url: "https://github.com/MaxDesiatov/UniversalDetector.git", from: "1.0.0"),
]
```

---

## 五、开发阶段规划

| 阶段 | 内容 | 周期 |
|------|------|------|
| **Phase 1** | 基础框架 + TXT阅读器 | 2周 |
| **Phase 2** | EPUB支持 + 书架管理 | 2周 |
| **Phase 3** | 阅读设置 + 主题系统 | 1周 |
| **Phase 4** | 搜索 + 书签笔记 | 1周 |
| **Phase 5** | 性能优化 + 细节打磨 | 1周 |

---

## 六、关键实现说明

### 6.1 文本分页算法

使用TextKit的`NSLayoutManager`进行分页计算：

1. 创建`NSTextStorage`存储文本内容
2. 配置`NSLayoutManager`和`NSTextContainer`
3. 通过`enumerateLineFragments`计算每页可容纳的行数
4. 根据页面高度计算分页点，生成`[NSRange]`数组

### 6.2 阅读进度管理

采用双维度进度系统：

- **章节内进度**: 当前页码 / 章节总页数
- **全局进度**: 已读字符数 / 全书总字符数

进度自动保存到Core Data，支持断点续读。

### 6.3 主题系统

定义`ReaderTheme`协议，实现多种主题：

- 日间模式: 白底黑字
- 夜间模式: 黑底灰字
- 护眼模式: 米黄底棕字
- 自定义: 用户可调字体、字号、行距、段距

### 6.4 书籍导入流程

1. 接收文件URL（文件分享/下载）
2. 复制到App沙盒的Documents/Books目录
3. 根据扩展名选择对应解析器
4. 提取元数据（标题、作者、封面、章节）
5. 保存到Core Data书架
6. 生成缩略图缓存

---

## 七、文件组织规范

### 7.1 命名规范

- **文件**: PascalCase，如`BookRepository.swift`
- **类/结构体**: PascalCase，如`BookViewModel`
- **方法/属性**: camelCase，如`loadBook()`
- **常量**: camelCase前缀k，如`kDefaultFontSize`
- **协议**: PascalCase后缀Protocol，如`BookRepositoryProtocol`

### 7.2 代码组织

每个文件遵循以下顺序：

1. import语句
2. 协议定义（如有）
3. 主类/结构体定义
4. 嵌套类型
5. 属性
6. 初始化方法
7. 公共方法
8. 私有方法
9. 扩展

### 7.3 注释规范

```swift
/// 书籍实体类
/// 包含书籍的基本信息和阅读进度
struct Book: Identifiable {
    /// 唯一标识符
    let id: UUID
    
    /// 书籍标题
    var title: String
    
    /// 当前阅读进度 (0.0 - 1.0)
    /// - Note: 自动保存到本地存储
    var progress: Double
}
```

---

## 八、参考资料

- [TextKit官方文档](https://developer.apple.com/documentation/uikit/textkit)
- [EPUB 3.2规范](https://www.w3.org/publishing/epub32/)
- [SwiftUI教程](https://developer.apple.com/documentation/swiftui/app-essentials)
- [Core Data指南](https://developer.apple.com/documentation/coredata)

---

*文档版本: 1.0*
*创建日期: 2025-05-21*
