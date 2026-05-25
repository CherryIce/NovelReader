# 修复书架导入书籍两个交互 Bug（第二轮）

## 任务理解

**目标**：修复书架右上角 "+" 按钮导入本地书籍时的两个交互 bug：
1. 首次添加导入书籍打开正常，再次点击添加之时无反应
2. 点击添加→文件展示→取消之后，再次点击添加之时无反应

**关键新线索**：切换 TabBar 再切回来后功能恢复正常。

**预期输出**：修复代码 + 代码审查确认无遗漏

## 当前状态分析

### 第一轮修复回顾
上一轮修复在 `DocumentPicker` 中添加了 `@Binding var isPresented`，在 Coordinator 的 `didPickDocumentsAt` 和 `documentPickerWasCancelled` 中通过 `DispatchQueue.main.async` 重置 `isPresented = false`。

### 第一轮修复为何不够

**根因**：SwiftUI 的 `.sheet(isPresented:)` 修饰符内部维护了一个**独立于 `@Binding` 的展示状态机**（`_PresentationState`）。`UIDocumentPickerViewController` 在用户选择/取消时会**自行 dismiss**（UIKit 层面），这个 dismiss 不经过 SwiftUI 的状态机。虽然 `@Binding` 的值被正确重置为 `false`，但 SwiftUI 的**内部展示状态可能没有正确清理**。

**时序问题**：
1. 用户选择文件 → `UIDocumentPickerViewController` 自行 dismiss（UIKit 层面）
2. Coordinator 的 `didPickDocumentsAt` 被调用
3. `DispatchQueue.main.async { isPresented = false }` 推迟到下一个 run loop
4. 在这个窗口期内，SwiftUI 内部状态与实际 UI 状态不一致
5. 再次点击按钮时，SwiftUI 可能忽略 `false→true` 的变化

**切换 Tab 为何有效**：切换 Tab 导致 `LibraryView` 被销毁重建，`.sheet` 修饰符的内部状态被完全重置，`@State` 也重新初始化为 `false`。

### 当前代码结构
- `LibraryView.swift` 第 6 行：`@State private var showingDocumentPicker = false`
- 第 20-24 行：`.sheet(isPresented: $showingDocumentPicker)` + `DocumentPicker(isPresented: $showingDocumentPicker)`
- 第 78 行：按钮设置 `showingDocumentPicker = true`
- 第 423-465 行：`DocumentPicker`，Coordinator 中通过 `DispatchQueue.main.async` 重置 `isPresented = false`

## 实施方案

### 修改文件：`LibraryView.swift`

**方案：使用 `.id()` 修饰符强制重建 sheet，同时移除 Coordinator 中的手动状态重置**

#### 改动 1：添加 `sheetId` 状态变量（第 6 行附近）

```swift
// 修改前：
@State private var showingDocumentPicker = false

// 修改后：
@State private var showingDocumentPicker = false
@State private var sheetId = UUID()
```

#### 改动 2：修改按钮 action，每次点击时生成新 UUID（第 77-81 行）

```swift
// 修改前：
private var addButton: some View {
    Button(action: { showingDocumentPicker = true }) {
        Image(systemName: "plus")
    }
}

// 修改后：
private var addButton: some View {
    Button(action: {
        sheetId = UUID()
        showingDocumentPicker = true
    }) {
        Image(systemName: "plus")
    }
}
```

#### 改动 3：在 `.sheet` 修饰符上添加 `.id(sheetId)`（第 20-24 行）

```swift
// 修改前：
.sheet(isPresented: $showingDocumentPicker) {
    DocumentPicker(isPresented: $showingDocumentPicker) { url in
        viewModel.importBook(from: url)
    }
}

// 修改后：
.sheet(isPresented: $showingDocumentPicker) {
    DocumentPicker { url in
        viewModel.importBook(from: url)
    }
}
.id(sheetId)
```

#### 改动 4：还原 `DocumentPicker`，移除 `@Binding isPresented`（第 423-465 行）

```swift
// 修改后（还原为简洁版本，不需要手动管理 isPresented）：
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            documentTypes: [kUTTypeText as String],
            in: .open
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 不需要手动 dismiss 或重置状态，.id() 机制确保下次弹出时 sheet 全新创建
        }
    }
}
```

### 方案原理

1. **`.id(sheetId)` 放在 `.sheet()` 所在视图上**：当 `sheetId` 变化时，SwiftUI 销毁整个视图（包括 `.sheet` 修饰符的内部状态），然后重建
2. **每次点击 "+" 时生成新 UUID**：确保 sheet 的内部展示状态是全新的
3. **移除 `@Binding isPresented`**：不再需要在 Coordinator 中手动管理状态，避免 `DispatchQueue.main.async` 引入的竞态条件
4. **`UIDocumentPickerViewController` 自行 dismiss 后**：SwiftUI 的 `.sheet` 会自动检测到 UIKit 层面的 dismiss 并将 `showingDocumentPicker` 重置为 `false`。即使这个自动重置有时不可靠，下次点击时 `sheetId` 的变化也会强制重建整个 sheet

### 为什么这个方案更优

| 对比项 | @Binding 方案（上一轮） | .id() 方案（本轮） |
|--------|------------------------|-------------------|
| 解决状态不同步 | ❌ 仅修复外部 binding，不修复 SwiftUI 内部状态 | ✅ 强制重建整个 sheet，内部状态完全重置 |
| 竞态条件风险 | ⚠️ `DispatchQueue.main.async` 可能导致状态合并 | ✅ 无异步操作，无竞态 |
| 代码复杂度 | ⚠️ 需要在 Coordinator 中管理 binding | ✅ DocumentPicker 更简洁 |
| 与切换 Tab 效果等价 | ❌ | ✅ 原理相同（视图重建） |

## 验证步骤

1. 打开应用进入书架页面
2. **Bug1 验证**：点击 "+" → 选择一个 txt 文件导入 → 导入完成后再次点击 "+" → 确认文件选择器正常弹出
3. **Bug2 验证**：点击 "+" → 点击取消 → 再次点击 "+" → 确认文件选择器正常弹出
4. **连续操作验证**：多次重复导入和取消操作，确认不再出现无反应的情况
5. **代码审查**：检查所有 dismiss 路径，确认无遗漏
