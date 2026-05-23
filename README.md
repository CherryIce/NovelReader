# BookReader - iOS 小说阅读器

一个基于 Swift + UIKit/SwiftUI 混编开发的 iOS 小说阅读器，支持 iOS 13+，采用 MVVM + Clean Architecture 架构。

## 📱 功能特性

### 已实现功能
- ✅ **书架管理** - 网格展示、搜索、筛选（全部/在读/已读完/收藏）
- ✅ **TXT 解析** - 自动识别章节标题，支持 UTF-8/GBK/GB18030/Big5 编码自动检测
- ✅ **阅读器** - 基于 UIPageViewController 翻页、Core Text 分页引擎、阅读进度自动保存
- ✅ **目录导航** - 章节列表、当前章节高亮、快速跳转
- ✅ **主题系统** - 4种主题（日间/夜间/羊皮纸/护眼）
- ✅ **阅读设置** - 字体大小（12-32pt）、行间距（0-20pt）自定义，设置带去抖动优化
- ✅ **字体管理** - 系统字体（PingFang SC/Heiti SC/Songti SC/Kaiti SC）+ 自定义字体导入（ttf/otf）
- ✅ **文件导入** - 支持 iCloud Drive、本地文件、文件分享（`UIDocumentPickerViewController`）
- ✅ **书签功能** - 添加/删除书签、书签列表、点击跳转、滑动删除（iOS 15+ swipeActions）
- ✅ **分页缓存** - JSON 序列化缓存分页结果，版本控制，视图高度变化时自动失效
- ✅ **导入进度** - 导入中实时显示进度和加载动画
- ✅ **iOS 13 兼容** - FullScreenCover、ActivityIndicator、书签删除等均兼容 iOS 13

### 待实现功能
- 📝 EPUB 格式支持
- 📝 PDF 格式支持
- 📝 笔记/高亮功能（数据模型已就绪）
- 📝 全文搜索
- 📝 iCloud 同步
- 📝 翻页动画优化（仿真翻页等）

## 🏗️ 项目结构

```
BookReader/
├── AppDelegate.swift                    # 应用入口，初始化 ThemeService/FontService
├── SceneDelegate.swift                  # 场景管理，注入 Core Data 环境
├── Info.plist                           # 配置：纯文本文档类型、竖屏、文件共享
│
└── NovelReader/
    ├── Core/                            # 核心基础设施层
    │   └── Services/
    │       ├── ThemeService.swift       # 主题服务（4种主题、字体大小、行间距、去抖动）
    │       ├── FontService.swift        # 字体服务（系统字体+自定义字体导入）
    │       └── PageCacheManager.swift   # 分页缓存管理（JSON序列化、版本控制）
    │
    ├── Domain/                          # 领域层（Clean Architecture）
    │   ├── Entities/
    │   │   ├── Book.swift               # 书籍实体（含 BookFormat/ReadingStatus 枚举）
    │   │   ├── Chapter.swift            # 章节实体
    │   │   └── Bookmark.swift           # 书签实体（含 BookmarkType 枚举：书签/笔记/高亮）
    │   ├── RepositoryInterfaces/
    │   │   ├── BookRepositoryProtocol.swift       # 书籍仓库协议（10个方法）
    │   │   ├── ChapterRepositoryProtocol.swift    # 章节仓库协议（5个方法）
    │   │   └── BookmarkRepositoryProtocol.swift   # 书签仓库协议（7个方法）
    │   └── UseCases/
    │       ├── LoadBookUseCase.swift    # 加载书籍用例（含 BookError 错误定义）
    │       └── SaveProgressUseCase.swift # 保存阅读进度用例
    │
    ├── Data/                            # 数据层
    │   ├── Repositories/
    │   │   ├── BookRepository.swift     # 书籍仓库实现（Core Data + Combine）
    │   │   ├── ChapterRepository.swift  # 章节仓库实现
    │   │   └── BookmarkRepository.swift # 书签仓库实现
    │   ├── Local/
    │   │   └── CoreData/
    │   │       ├── PersistenceController.swift        # Core Data 栈管理（单例、自动迁移）
    │   │       ├── BookEntity+Extension.swift         # BookEntity <-> Book 双向映射
    │   │       ├── ChapterEntity+Extension.swift      # ChapterEntity <-> Chapter 双向映射
    │   │       └── BookmarkEntity+Extension.swift     # BookmarkEntity <-> Bookmark 双向映射
    │   └── Parsers/
    │       └── TXTParser/
    │           └── TXTParser.swift      # TXT 解析器（编码检测、章节正则匹配、50MB限制）
    │
    └── Presentation/                    # 表现层（MVVM）
        ├── Components/
        │   └── ActivityIndicator.swift  # iOS 13 兼容的加载指示器
        ├── ViewModels/
        │   ├── LibraryViewModel.swift   # 书架 ViewModel（加载/搜索/筛选/导入/删除）
        │   └── ReaderViewModel.swift    # 阅读器 ViewModel（Core Text 分页/翻页/进度/书签）
        └── Views/
            ├── ContentView.swift        # 根视图（TabView：书架/搜索/设置）
            ├── Library/
            │   └── LibraryView.swift    # 书架视图（搜索栏/筛选栏/书籍网格/导入/删除）
            ├── Reader/
            │   ├── ReaderView.swift     # 阅读器视图（PageViewController/工具栏/状态管理）
            │   └── BookmarkListView.swift # 书签列表视图
            ├── Catalog/
            │   └── CatalogView.swift    # 章节目录视图
            └── Settings/
                └── ReaderSettingsView.swift # 阅读设置视图（主题/字号/行距/字体）
```

## 🚀 快速开始

### 环境要求
- iOS 13.0+
- Xcode 13.0+
- Swift 5.9+

### 运行项目

1. **打开项目**
   ```bash
   open BookReader.xcodeproj
   ```

2. **选择模拟器或真机**，点击运行按钮 (⌘+R)

## 📖 使用指南

### 导入书籍

1. 点击书架右上角 **+** 按钮
2. 在文件选择器中选择 TXT 文件
3. 系统自动检测编码（UTF-8/GBK/GB18030/Big5）并解析章节
4. 导入完成后自动添加到书架

### 阅读书籍

1. 在书架点击书籍封面进入阅读器
2. 左右滑动翻页（基于 UIPageViewController）
3. 点击中间区域显示/隐藏工具栏
4. 工具栏功能：返回、添加书签、书签列表、目录、阅读设置

### 切换主题

在阅读器中点击设置按钮，选择主题：
- ☀️ 日间模式 - 白底黑字
- 🌙 夜间模式 - 黑底灰字
- 📜 羊皮纸模式 - 米黄底棕字
- 👁️ 护眼模式 - 浅绿底深字

### 调整阅读设置

- **字体大小**: 12-32pt 可调（带 0.15s 去抖动，避免频繁重分页）
- **行间距**: 0-20pt 可调（带去抖动）
- **字体**: 系统字体（System/PingFang SC/Heiti SC/Songti SC/Kaiti SC）+ 自定义字体导入

### 书签管理

- 在阅读器工具栏点击书签图标添加/取消书签
- 点击书签列表图标查看所有书签
- 点击书签条目跳转到对应位置
- iOS 15+ 支持滑动删除

## 🏛️ 架构说明

### Clean Architecture 分层

```
Presentation Layer (MVVM)
    ↓  ViewModels 依赖 UseCases
Domain Layer (Entities + UseCases + Repository Interfaces)
    ↓  Repository 实现依赖 Domain 层协议
Data Layer (Repository Implementations + Core Data + Parsers)
```

### 数据流

```
View → ViewModel → UseCase → Repository → Core Data
                ↘ TXTParser (文件导入时)
```

### 关键技术

| 技术 | 用途 |
|------|------|
| SwiftUI + UIKit 混编 | UI 构建（SwiftUI 为主，UIKit 处理翻页和文件选择） |
| Combine | 响应式编程（Repository 层异步操作、ViewModel 数据绑定） |
| Core Data | 数据持久化（书籍/章节/书签，自动迁移） |
| Core Text (CTFramesetter) | 文本分页引擎（精确计算每页文本内容） |
| UIPageViewController | 翻页交互 |
| MVVM + Clean Architecture | 架构模式，依赖注入，便于测试 |

### 核心设计

- **依赖注入**: ViewModel 通过协议接收 Repository，便于单元测试和替换实现
- **响应式数据流**: Repository 层全部使用 `AnyPublisher` 返回，ViewModel 通过 Combine 订阅
- **Core Data 线程安全**: 所有 CoreData 操作在 `context.perform` 块中执行
- **分页缓存**: `PageCacheManager` 将分页结果序列化为 JSON 缓存，带版本号和视图高度校验
- **编码检测**: TXTParser 支持 BOM → ASCII → 严格 UTF-8 → GB18030 → Big5 → UTF-8 兜底的检测链
- **去抖动优化**: 字体大小和行间距设置带 0.15 秒去抖动，避免频繁触发 Core Text 重分页

## 📁 文件清单

```
BookReader/
├── AppDelegate.swift                  # 应用入口
├── SceneDelegate.swift                # 场景管理
├── Info.plist                         # 应用配置
├── Assets.xcassets/                   # 资源目录
├── Base.lproj/LaunchScreen.storyboard # 启动画面
├── BookReader.xcdatamodeld/           # Core Data 模型
└── NovelReader/                       # 源代码（见上方项目结构）

BookReaderTests/                       # 单元测试
BookReaderUITests/                     # UI 测试
rules/                                 # 开发规范（通用 + Swift）
reader.md                              # 技术方案文档
README.md                              # 本文件
```

## 🔧 扩展开发

### 添加新的文件格式支持

1. 在 `Data/Parsers/` 下创建新的解析器目录（如 `EPUBParser/`）
2. 实现解析逻辑，返回 `ParsedBook` 结构体
3. 在 `LibraryViewModel.importBook(from:)` 中添加格式判断分支

### 添加新的主题

1. 在 `ThemeService.swift` 的 `ReaderTheme` 枚举中添加新 case
2. 配置 `backgroundColor`、`textColor`、`textColorUI`、`secondaryTextColor`、`displayName`
3. 设置页面会自动通过 `ForEach(ReaderTheme.allCases)` 展示新主题

### 添加新的阅读状态筛选

1. 在 `LibraryViewModel.swift` 的 `LibraryFilter` 枚举中添加新 case
2. 实现 `displayName` 和对应的筛选逻辑

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

---

*Made with ❤️ by BookReader Team*
