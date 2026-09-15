import SwiftUI
import UniformTypeIdentifiers

struct ReaderSettingsView: View {
    let showsDoneButton: Bool
    @ObservedObject private var themeService = ThemeService.shared
    @ObservedObject private var fontService = FontService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingFontPicker = false
    @State private var fontImportFailed = false
    @State private var pendingFontURL: URL?

    init(showsDoneButton: Bool = true) {
        self.showsDoneButton = showsDoneButton
    }
    
    var body: some View {
        NavigationView {
            Form {
                // 主题选择
                Section(header: Text("主题")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(ReaderTheme.allCases) { theme in
                                ThemeButton(
                                    theme: theme,
                                    isSelected: themeService.currentTheme == theme
                                ) {
                                    themeService.setTheme(theme)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                
                // 字体大小
                Section(header: Text("字体大小")) {
                    HStack {
                        Button(action: { themeService.decreaseFontSize() }) {
                            Image(systemName: "textformat.size.smaller")
                        }
                        
                        Slider(
                            value: .init(
                                get: { Double(themeService.fontSize) },
                                set: { themeService.setFontSize(CGFloat($0)) }
                            ),
                            in: 12...32,
                            step: 1
                        )
                        
                        Button(action: { themeService.increaseFontSize() }) {
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                    
                    Text("预览文字大小")
                        .font(readerFont)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
                
                // 行间距
                Section(header: Text("行间距")) {
                    Slider(
                        value: .init(
                            get: { Double(themeService.lineSpacing) },
                            set: { themeService.setLineSpacing(CGFloat($0)) }
                        ),
                        in: 0...20,
                        step: 1
                    )
                }
                
                // 字体选择
                Section(header: Text("字体")) {
                    Picker("字体", selection: .init(
                        get: { fontService.currentFont },
                        set: { fontService.setFont($0) }
                    )) {
                        ForEach(fontService.availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }

                    Button(action: { showingFontPicker = true }) {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("导入 TTF/OTF 字体")
                        }
                    }
                }
            }
            .navigationBarTitle("阅读设置", displayMode: .inline)
            .navigationBarItems(trailing: Group {
                if showsDoneButton {
                    Button("完成") {
                        dismiss()
                    }
                }
            })
            .sheet(isPresented: $showingFontPicker, onDismiss: {
                guard let url = pendingFontURL else { return }
                pendingFontURL = nil
                if !fontService.importFont(from: url) {
                    fontImportFailed = true
                }
            }) {
                DocumentPicker(isPresented: $showingFontPicker, contentTypes: [.font]) { url in
                    pendingFontURL = url
                }
            }
            .alert(isPresented: $fontImportFailed) {
                Alert(
                    title: Text("字体导入失败"),
                    message: Text("请选择有效且尚未导入的 TTF 或 OTF 字体文件。"),
                    dismissButton: .default(Text("确定"))
                )
            }
        }
    }

    private var readerFont: Font {
        if fontService.currentFont == "System" {
            return .system(size: themeService.fontSize)
        }
        return .custom(fontService.currentFont, size: themeService.fontSize)
    }
}

struct ThemeButton: View {
    let theme: ReaderTheme
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.backgroundColor)
                    .frame(width: 60, height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.gray, lineWidth: isSelected ? 2 : 1)
                    )
                
                Text(theme.displayName)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
        }
    }
}

struct ReaderSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ReaderSettingsView()
    }
}
