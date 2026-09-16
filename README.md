# BookReader - iOS 小说阅读器

一个基于 Swift + UIKit/SwiftUI 混编开发的 iOS 小说阅读器，支持 iOS 15+，采用 MVVM + Clean Architecture 架构。

## 📱 功能特性

### 已实现功能
- ✅ **书架管理** - 网格展示、独立搜索页、筛选（全部/在读/已读完/收藏），支持收藏和完成状态切换
- ✅ **TXT 解析** - 自动识别章节标题，支持 UTF-8/GBK/GB18030/Big5 编码自动检测
- ✅ **EPUB/PDF 解析** - 支持 EPUB 内容解包和 PDF 文本、目录提取；保留 PDF 首个目录章节之前的前言正文
- ✅ **阅读器** - 基于 UIPageViewController 翻页、Core Text 分页引擎、进度拖动和阅读进度自动保存
- ✅ **听书功能** - 支持系统语音朗读、暂停、语速和音调调节，并自动连续翻页
- ✅ **目录导航** - 章节列表、当前章节高亮、快速跳转
- ✅ **主题系统** - 4种主题（日间/夜间/羊皮纸/护眼）
- ✅ **阅读设置** - 字体大小（12-32pt）、行间距（0-20pt）自定义，设置带去抖动优化
- ✅ **字体管理** - 系统字体（PingFang SC/Heiti SC/Songti SC/Kaiti SC）+ 自定义字体导入（ttf/otf）
- ✅ **文件导入** - 支持 TXT/EPUB/PDF 单个或批量导入，以及局域网 WiFi 传书
- ✅ **书签功能** - 同章多书签、精确位置跳转、书签列表和滑动删除
- ✅ **划线与笔记** - 长按选择原文、跨页调整选区、添加划线/想法、笔记聚合与内容搜索
- ✅ **分页缓存** - 只缓存页面范围元数据，后台读取并按版本、文件时间、视图尺寸和排版设置完整校验
- ✅ **渐进式分页** - 无缓存时优先显示当前章节，随后预排相邻章节并在后台补齐全书
- ✅ **导入进度** - 导入中实时显示进度和加载动画
- ✅ **大文件传书保护** - WiFi 上传请求体流式写入临时文件，避免正文里的类分隔符截断文件；限制连接数并关闭空闲连接，停止时撤销令牌、取消在途连接，并清理异常退出遗留的请求体
- ✅ **阅读统计** - 记录阅读时长、页数、连续阅读天数和分书统计
- ✅ **数据迁移与恢复提示** - Core Data 自动迁移、常用查询索引和存储加载失败重试界面
- ✅ **基础无障碍** - 阅读正文向 VoiceOver 暴露为静态文本，主要操作提供可访问标签
- ✅ **iOS 15 基线** - 使用原生 fullScreenCover、ProgressView、UTType、dismiss 和 swipeActions

### 待实现功能
- 📝 全文搜索
- 📝 iCloud 同步
- 📝 完整本地化与系统动态字体适配
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
    │       └── PageCacheManager.swift   # 分页范围缓存（后台读取、原子写入、版本控制）
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
    │   │       ├── PersistenceController.swift        # Core Data 栈管理（自动迁移、失败重试）
    │   │       ├── BookEntity+Extension.swift         # BookEntity <-> Book 双向映射
    │   │       ├── ChapterEntity+Extension.swift      # ChapterEntity <-> Chapter 双向映射
    │   │       └── BookmarkEntity+Extension.swift     # BookmarkEntity <-> Bookmark 双向映射
    │   └── Parsers/
    │       └── TXTParser/
    │           └── TXTParser.swift      # TXT 解析器（编码检测、章节正则匹配、50MB限制）
    │
    └── Presentation/                    # 表现层（MVVM）
        ├── ViewModels/
        │   ├── LibraryViewModel.swift   # 书架 ViewModel（加载/搜索/筛选/导入/删除）
        │   ├── ReaderViewModel.swift    # 阅读器 ViewModel（分页协调/进度/书签/批注/听书）
        │   └── NotesViewModel.swift     # 全局笔记与单书批注聚合
        └── Views/
            ├── ContentView.swift        # 根视图（首次引导门控 + 主 TabView）
            ├── OnboardingView.swift     # 三页首次使用引导
            ├── Library/
            │   └── LibraryView.swift    # 书架视图（搜索栏/筛选栏/书籍网格/导入/删除）
            ├── Reader/
            │   ├── ReaderView.swift     # 阅读器视图（PageViewController/工具栏/状态管理）
            │   ├── ReaderAnnotationDetailView.swift # 批注详情与想法管理
            │   └── BookmarkListView.swift # 书签列表视图
            ├── Notes/
            │   └── NotesView.swift      # 笔记聚合、搜索和详情
            ├── Catalog/
            │   └── CatalogView.swift    # 章节目录视图
            └── Settings/
                └── ReaderSettingsView.swift # 阅读设置视图（主题/字号/行距/字体）
```

## 🚀 快速开始

### 环境要求
- iOS 15.0+
- Xcode 16.0+（单元测试使用 Swift Testing）
- Swift 5 语言模式

### 运行项目

1. **打开项目**
   ```bash
   open BookReader.xcodeproj
   ```

2. **选择模拟器或真机**，点击运行按钮 (⌘+R)

## 📖 使用指南

### 导入书籍

1. 点击书架右上角 **+** 按钮
2. 选择单本或批量导入 TXT、EPUB、PDF 文件，也可以启动 WiFi 传书
3. 系统按文件格式解析内容；TXT 会自动检测 UTF-8/GBK/GB18030/Big5 编码
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
    ↓  ReaderViewModel 依赖 UseCases；LibraryViewModel 依赖 Repository 协议
Domain Layer (Entities + UseCases + Repository Interfaces)
    ↓  Repository 实现依赖 Domain 层协议
Data Layer (Repository Implementations + Core Data + Parsers)
```

### 数据流

```
View → ViewModel → UseCase/Repository 协议 → Repository → Core Data
                ↘ TXTParser（文件导入时）
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
- **分页缓存**: `PageCacheManager` 只持久化页面范围元数据，读取时从章节正文重建页面，避免在磁盘重复保存整本正文
- **可取消排版**: 字体、尺寸连续变化时取消旧分页任务，旧结果不会覆盖最新页面
- **分阶段排版**: 按当前章节、相邻章节、其余章节的顺序计算；阶段结果始终按原章节顺序重组，最终结果才写入完整缓存
- **长书页面定位**: 翻页、章节进度和书签跳转按章节与 UTF-16 正文偏移二分查找；缓存乱序、缺页、重叠或章节内容不完整时自动失效并重新分页，避免漏字及阶段页号重排后跳错页
- **合并进度保存**: 连续翻页使用 0.35 秒去抖；翻页时立即记录待保存位置，离开阅读器或进入后台时提交最后位置
- **流式 WiFi 接收**: 上传请求体边接收边写临时文件，再按范围分块复制书籍，限制峰值堆内存
- **异常退出清理**: 传书服务首次创建时，仅清理专用临时目录内由本服务命名的遗留请求体，避免占满设备存储
- **连接资源上限**: 同时最多接入 8 个连接；每 5 秒检查一次，超过 30 秒无接收活动的连接会被关闭，已完整接收并正在处理的上传不计入空闲超时
- **multipart 边界校验**: 仅将独立行上带合法后缀的边界识别为文件分隔符，拒绝缺失结束边界的请求
- **停止传书**: 立即使当前会话令牌失效并取消已接入连接，清理未完成的上传请求体；停止后的上传结果不会再交付导入
- **批量导入判重**: 以已存在书籍和本批次成功导入的文件名判重；前一份同名文件失败时仍尝试后一份，进度总数包含所有选中文件
- **编码检测**: TXTParser 优先识别 BOM，再对整文件依次尝试 UTF-8、GB18030 和 Big5，避免仅抽样文件头造成误判
- **去抖动优化**: 字体大小和行间距设置带 0.15 秒去抖动，避免频繁触发 Core Text 重分页

## 🧪 测试

```bash
xcodebuild test \
  -project BookReader.xcodeproj \
  -scheme BookReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BookReaderTests
```

当前 45 个单元测试覆盖默认书架筛选、TXT 编码回退与 UTF-16 偏移、EPUB/PDF 解析及目录前言保留、分页缓存失效与重建、乱序及正文覆盖不完整的缓存拒绝、分页取消、渐进式分页顺序、页面偏移定位、未预排章节的书签跳转、单章分页入口、超过 500 页的完整分页、划线批注、导入原子性、批量同名失败重试与进度计数、WiFi 会话停止后的令牌失效、连接上限与空闲回收、multipart 边界校验、本机 HTTP 上传/中途停止与清理、异常退出遗留请求体清理回归、数据迁移、阅读统计、翻页后立即退出时的进度保存、单页进度及完成状态持久化；UI 测试包含主导航冒烟验证。

## 📁 文件清单

```
BookReader/
├── AppDelegate.swift                  # 应用入口
├── SceneDelegate.swift                # 场景管理
├── Info.plist                         # 应用配置与 UILaunchScreen 启动页
├── Assets.xcassets/                   # AppIcon、启动标记与引导插画
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

仓库当前尚未提供独立许可证文件。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

---

*Made with ❤️ by BookReader Team*
