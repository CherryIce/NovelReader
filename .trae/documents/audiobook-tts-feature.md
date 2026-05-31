# 听书功能实现方案（AVSpeechSynthesizer 文字转语音）

## 概述
集成 AVSpeechSynthesizer 实现听书功能，支持从当前页开始朗读、自动翻页连续朗读、暂停/继续、停止，以及语速和音调调节。

## 当前状态分析

### 数据来源
- `Page.content`（String）：已分页的纯文本，直接可用于 AVSpeechUtterance
- `ReaderViewModel.currentPage`：获取当前页数据
- `ReaderViewModel.currentPageIndex`：翻页通过直接设置此属性实现
- `ReaderViewModel.updateProgressForPage()`：翻页后需调用此方法更新进度

### 听书按钮位置
`ReaderView.swift` 第224-237行，`toolbarLayer` 的 ZStack 中，右下角悬浮圆形按钮，当前为 TODO 占位。

### 服务层模式
所有服务遵循：`class XxxService: ObservableObject` + `static let shared` 单例 + `@Published` 属性 + `private init()`。

## 修改方案

### 文件 1：新建 `SpeechService.swift`
**路径：** `BookReader/NovelReader/Core/Services/SpeechService.swift`

**职责：** 封装 AVSpeechSynthesizer，管理语音播放状态和参数。

```swift
import AVFoundation
import Combine

class SpeechService: ObservableObject {
    static let shared = SpeechService()
    
    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate  // 语速
    @Published var pitch: Float = 1.0  // 音调
    
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: (() -> Void)?  // 朗读完毕后的回调（用于翻页继续）
    
    private init() {
        synthesizer.delegate = self  // 需要扩展 AVSpeechSynthesizerDelegate
    }
    
    func speak(_ text: String, completion: (() -> Void)?)
    func pause()
    func resume()
    func stop()
}
```

**关键实现：**
- `speak()`: 创建 `AVSpeechUtterance`，设置 `rate` 和 `pitch`，调用 `synthesizer.speak()`，保存 completion 回调
- `pause()`: 调用 `synthesizer.pauseSpeech(at: .immediate)`，更新 `isPaused = true`
- `resume()`: 调用 `synthesizer.continueSpeaking()`，更新 `isPaused = false`
- `stop()`: 调用 `synthesizer.stopSpeaking(at: .immediate)`，重置状态
- `AVSpeechSynthesizerDelegate.didFinish`: 调用 `continuation?()` 实现自动翻页

### 文件 2：修改 `ReaderViewModel.swift`
**路径：** `BookReader/NovelReader/Presentation/ViewModels/ReaderViewModel.swift`

**新增属性：**
```swift
@Published var isSpeaking: Bool = false
@Published var isPaused: Bool = false
private var speechCancellable: AnyCancellable?
```

**新增方法：**
```swift
// 开始/停止听书
func toggleSpeech()

// 暂停/继续听书
func togglePauseSpeech()

// 朗读当前页内容（内部方法）
private func speakCurrentPage()

// 停止听书（内部方法）
private func stopSpeech()
```

**逻辑：**
- `toggleSpeech()`:
  - 如果未在朗读 → 调用 `speakCurrentPage()`
  - 如果正在朗读或暂停 → 调用 `stopSpeech()`
- `speakCurrentPage()`:
  - 获取 `currentPage?.content`，调用 `SpeechService.shared.speak(text) { [weak self] in ... }`
  - completion 回调中：如果还有下一页，`currentPageIndex += 1`，递归调用 `speakCurrentPage()`
  - 通过 Combine 监听 `SpeechService.shared.$isSpeaking` 同步状态到 ViewModel
- `stopSpeech()`: 调用 `SpeechService.shared.stop()`

### 文件 3：修改 `ReaderView.swift` — 听书按钮
**路径：** `BookReader/NovelReader/Presentation/Views/Reader/ReaderView.swift`

**修改第224-237行的听书按钮：**
- action 回调改为调用 `viewModel.toggleSpeech()`
- 图标根据状态切换：未朗读时显示 `"headphones"`，朗读中显示 `"pause"`，暂停时显示 `"play.fill"`
- 添加长按手势：朗读/暂停状态下长按触发 `viewModel.togglePauseSpeech()`

### 文件 4：修改 `ReaderView.swift` — 添加听书控制面板
**在 `toolbarLayer` 的 ZStack 中，底部工具栏上方添加一个听书控制条：**

当 `viewModel.isSpeaking` 为 true 时，在底部工具栏上方显示一个控制条，包含：
- 暂停/继续按钮
- 语速 Slider（rate: 0.3 ~ 0.8，step 0.1）
- 音调 Slider（pitch: 0.5 ~ 2.0，step 0.1）
- 停止按钮

使用 `.transition(.move(edge: .bottom).combined(with: .opacity))` 实现动画。

### 文件 5：修改 `ReaderView.swift` — 添加 sheet 弹窗
在 ReaderView 的 body 中添加 `.sheet(isPresented: $viewModel.showSpeechSettings)` 绑定听书设置面板。

## 实施步骤

1. **新建 `SpeechService.swift`**：实现 AVSpeechSynthesizer 封装，包含 delegate 回调
2. **修改 `ReaderViewModel.swift`**：添加听书相关属性和方法，实现自动翻页连续朗读
3. **修改 `ReaderView.swift` 听书按钮**：替换 TODO 为实际回调，图标随状态切换
4. **修改 `ReaderView.swift` 控制面板**：在底部工具栏上方添加语速/音调调节和暂停/停止控件
5. **修改 `ReaderView.swift` sheet**：添加听书设置弹窗绑定

## 验证
1. 点击听书按钮开始朗读当前页，图标切换为暂停图标
2. 朗读完当前页自动翻到下一页继续朗读
3. 暂停/继续功能正常
4. 停止功能正常，状态正确重置
5. 语速和音调调节实时生效
6. 朗读到最后一页时自动停止
