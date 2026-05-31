# 底部工具栏按钮顺序调整

## 概述
调整底部工具栏中三个按钮的排列顺序。

## 当前状态
`ReaderView.swift` 第498-510行，按钮顺序为：**书签 → 书签列表 → 目录**

## 修改方案

### 修改文件
`BookReader/NovelReader/Presentation/Views/Reader/ReaderView.swift`

### 变更内容
将 `ReaderBottomToolbar` 的 `body` 中三个按钮的顺序从：
```
书签 → 书签列表 → 目录
```
调整为：
```
目录 → 书签列表 → 书签
```

仅移动代码块顺序，不修改任何属性、样式或逻辑。

## 验证
确认按钮顺序为：目录（textformat.size）- 书签列表（list.bullet）- 书签（bookmark）
