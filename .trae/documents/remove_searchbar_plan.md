# 移除书架搜索框实施计划

## 任务概述
移除书架（LibraryView）中的搜索框组件。

## 当前状态分析

### 涉及文件
1. **LibraryView.swift** - 书架视图，包含搜索框UI
2. **LibraryViewModel.swift** - 书架视图模型，包含搜索逻辑

### 当前搜索框实现
- **UI位置**: `LibraryView.swift` 第56-60行，`searchBar` 视图
- **搜索组件**: 第275-297行的 `SearchBar` 结构体
- **数据绑定**: 绑定到 `viewModel.searchQuery`
- **视图层级**: 在 `contentLayer` 中，位于 `filterBar` 和 `bookGrid` 之间

### 搜索相关逻辑
- **LibraryViewModel** 第26-30行: `searchQuery` 属性，带 `didSet` 监听
- **LibraryViewModel** 第87-102行: `performSearch()` 方法
- 搜索会触发 `bookRepository.searchBooks(query:)` 查询

## 实施步骤

### 步骤1: 修改 LibraryView.swift
- **操作**: 从 `contentLayer` 中移除 `searchBar` 引用
- **具体修改**:
  - 删除第50行 `searchBar` 调用
  - 可选择删除第56-60行的 `searchBar` 属性定义（或保留但不使用）
  - 可选择删除第275-297行的 `SearchBar` 结构体（如确认无其他用途）

### 步骤2: 修改 LibraryViewModel.swift
- **操作**: 移除搜索相关属性和方法
- **具体修改**:
  - 删除第26-30行的 `searchQuery` 属性
  - 删除第87-102行的 `performSearch()` 方法

## 验证步骤
1. 编译项目，确保无编译错误
2. 运行应用，进入书架页面
3. 确认搜索框已不再显示
4. 确认筛选栏（filterBar）正常显示在顶部
5. 确认书籍列表正常显示
6. 确认其他功能（导入、删除、筛选等）正常工作

## 回滚方案
如需恢复搜索功能，可从git历史恢复被删除的代码。
