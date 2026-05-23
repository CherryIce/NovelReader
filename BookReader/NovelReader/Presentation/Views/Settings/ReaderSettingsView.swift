import SwiftUI

struct ReaderSettingsView: View {
    @ObservedObject private var themeService = ThemeService.shared
    @ObservedObject private var fontService = FontService.shared
    @Environment(\.presentationMode) var presentationMode
    
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
                        .font(.system(size: themeService.fontSize))
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
                }
            }
            .navigationBarTitle("阅读设置", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") {
                presentationMode.wrappedValue.dismiss()
            })
        }
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
