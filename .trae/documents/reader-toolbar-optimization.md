# 阅读页工具栏优化方案

## 概述
优化阅读页面的顶部和底部工具栏布局，简化顶部工具栏，将部分功能按钮迁移到底部工具栏。

## 当前状态分析

### 顶部工具栏 (`ReaderTopToolbar`, 第465-513行)
- 左侧：返回按钮 (`chevron.left`)
- 中间：章节标题文本
- 右侧：书签按钮 (`bookmark`)、书签列表按钮 (`list.bullet`)、目录按钮 (`textformat.size`)、设置按钮 (`gearshape`)

### 底部工具栏 (`ReaderBottomToolbar`, 第517-550行)
- 左侧：上一章按钮 (`backward.end.fill` + "上一章")
- 右侧：下一章按钮 ("下一章" + `forward.end.fill`)
- 接口还定义了 `progress` 和 `onSliderChange` 参数，但当前未渲染

### 工具栏调用位置 (`toolbarLayer`, 第172-230行)
- 顶部工具栏传入参数：`title`, `onBack`, `onCatalog`, `onSettings`, `onBookmark`, `onBookmarkList`, `isBookmarked`
- 底部工具栏传入参数：`progress`, `hasPreviousChapter`, `hasNextChapter`, `onPreviousChapter`, `onNextChapter`, `onSliderChange`

## 修改方案

### 修改文件
`BookReader/NovelReader/Presentation/Views/Reader/ReaderView.swift`

### 步骤 1：修改 `ReaderTopToolbar`（第465-513行）

**变更内容：**
- 移除 `onCatalog`、`onBookmark`、`onBookmarkList`、`isBookmarked` 属性
- 保留 `title`、`onBack`、`onSettings` 属性
- 右侧 `HStack` 中只保留设置按钮 (`gearshape`)，移除书签、书签列表、目录按钮

**修改后结构：**
```
HStack {
    返回按钮
    Spacer()
    章节标题
    Spacer()
    设置按钮
}
```

### 步骤 2：修改 `ReaderBottomToolbar`（第517-550行）

**变更内容：**
- 移除 `progress`、`hasPreviousChapter`、`hasNextChapter`、`onPreviousChapter`、`onNextChapter`、`onSliderChange` 属性
- 新增属性：`onBookmark: () -> Void`、`onBookmarkList: () -> Void`、`onCatalog: () -> Void`、`isBookmarked: Bool`
- 移除上一章/下一章按钮
- 新增三个按钮：书签按钮、书签列表按钮、目录按钮，居中均匀分布

**修改后结构：**
```
HStack {
    书签按钮 (bookmark / bookmark.fill)
    书签列表按钮 (list.bullet)
    目录按钮 (textformat.size)
}
```

### 步骤 3：更新 `toolbarLayer` 调用处（第172-230行）

**变更内容：**
- `ReaderTopToolbar` 调用：移除 `onCatalog`、`onBookmark`、`onBookmarkList`、`isBookmarked` 参数
- `ReaderBottomToolbar` 调用：移除 `progress`、`hasPreviousChapter`、`hasNextChapter`、`onPreviousChapter`、`onNextChapter`、`onSliderChange` 参数；新增 `onBookmark`、`onBookmarkList`、`onCatalog`、`isBookmarked` 参数

## 验证步骤
1. 确认代码编译通过（`xcodebuild` 或 Xcode 预览）
2. 确认顶部工具栏只显示：返回按钮、章节标题、设置按钮
3. 确认底部工具栏显示：书签按钮、书签列表按钮、目录按钮
4. 确认所有按钮功能正常（返回、设置、书签切换、书签列表、目录）
