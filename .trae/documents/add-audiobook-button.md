# 添加听书悬浮按钮方案

## 概述
在阅读页工具栏显示时，添加一个听书悬浮按钮，位于底部工具栏右下方，与底部工具栏和右侧边缘各保持10pt间距，出现/消失与上下工具栏同步。

## 当前状态
- 工具栏通过 `viewModel.showToolbar` 控制显示/隐藏（第23行 `if viewModel.showToolbar`）
- 工具栏层 `toolbarLayer`（第172-222行）使用 `VStack` 布局：顶部工具栏 → Spacer → 底部工具栏
- 底部工具栏使用 `.padding()` 作为内边距

## 修改方案

### 修改文件
`BookReader/NovelReader/Presentation/Views/Reader/ReaderView.swift`

### 步骤 1：在 `toolbarLayer` 中添加听书悬浮按钮

在 `toolbarLayer` 的 `VStack` 外层包裹一个 `ZStack`，将听书按钮以 `.overlay` 或 `ZStack` 方式定位在右下角。

**具体位置：** 在第172行 `toolbarLayer` 中，将现有 `VStack` 包裹在 `ZStack` 中，并添加悬浮按钮：

```swift
private var toolbarLayer: some View {
    ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            // 现有顶部工具栏和底部工具栏代码不变...
        }
        
        // 听书悬浮按钮
        Button(action: {
            // TODO: 听书功能回调
        }) {
            Image(systemName: "headphones")
                .font(.system(size: 20))
                .foregroundColor(themeService.currentTheme.textColor)
                .padding(12)
                .background(themeService.currentTheme.backgroundColor)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        }
        .padding(.trailing, 10)   // 距右侧10pt
        .padding(.bottom, 10)     // 距底部工具栏底部10pt
    }
}
```

**关键点：**
- 使用 `ZStack(alignment: .bottomTrailing)` 实现右下角定位
- `.padding(.trailing, 10)` + `.padding(.bottom, 10)` 确保距右侧和底部工具栏各10pt
- 按钮样式：圆形背景 + 耳机图标，与当前主题颜色一致
- 出现/消失逻辑：按钮在 `toolbarLayer` 内部，自动跟随 `viewModel.showToolbar` 控制

## 验证
1. 确认听书按钮在工具栏显示时出现，隐藏时消失
2. 确认按钮位置：距底部工具栏底部10pt，距右侧边缘10pt
3. 确认按钮样式与主题颜色一致
