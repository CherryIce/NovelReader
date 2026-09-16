import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "app.appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("显示")) {
                    Picker("显示模式", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(header: Text("协议与隐私")) {
                    NavigationLink(destination: LegalDocumentView(document: .privacy)) {
                        Text("隐私协议")
                    }
                    NavigationLink(destination: LegalDocumentView(document: .terms)) {
                        Text("用户协议")
                    }
                }

                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(versionText)
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: AboutAppView(versionText: versionText)) {
                        Text("关于本应用")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "-"
        }
    }
}

private enum LegalDocument {
    case privacy
    case terms

    var title: String {
        switch self {
        case .privacy: return "隐私协议"
        case .terms: return "用户协议"
        }
    }

    var sections: [(title: String, body: String)] {
        switch self {
        case .privacy:
            return [
                ("本地数据", "导入的书籍、阅读进度、书签、划线、笔记和显示偏好保存在你的设备上。"),
                ("WiFi 传书", "只有在你主动开启 WiFi 传书时，应用才会在当前局域网临时提供文件接收服务；退出传书页面后服务会停止。"),
                ("数据管理", "你可以通过删除书籍移除对应内容、阅读进度和笔记。卸载应用也会移除保存在应用沙盒中的数据。")
            ]
        case .terms:
            return [
                ("内容来源", "请仅导入和阅读你有权使用的内容，并遵守相关版权与法律规定。"),
                ("功能说明", "应用提供本地书籍阅读、笔记、书签、听书、统计和局域网传书功能。功能可能随版本更新而调整。"),
                ("使用责任", "请妥善保管原始书籍文件，并在重要数据变更前自行备份。因设备故障、系统清理或卸载造成的数据丢失，应以你的备份为准。")
            ]
        }
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                        Text(section.body)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .lineSpacing(5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .hidesRootTabBar()
    }
}

private struct AboutAppView: View {
    let versionText: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "BookReader")
                .font(.title2.weight(.bold))
            Text("版本 \(versionText)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("专注于本地阅读、记录与回顾。")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .navigationTitle("关于本应用")
        .navigationBarTitleDisplayMode(.inline)
        .hidesRootTabBar()
    }
}
