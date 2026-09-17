import Foundation

/// App 容器的 UUID 会在重新安装或恢复备份后变化，旧的绝对路径需要指向当前容器。
enum ManagedBookFileLocator {
    static func relocatedPath(for storedPath: String, fileManager: FileManager = .default) -> String? {
        guard !fileManager.fileExists(atPath: storedPath) else { return nil }

        let oldURL = URL(fileURLWithPath: storedPath)
        let booksDirectory = oldURL.deletingLastPathComponent()
        guard booksDirectory.lastPathComponent == "Books",
              booksDirectory.deletingLastPathComponent().lastPathComponent == "Documents",
              let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let currentURL = documentsDirectory
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(oldURL.lastPathComponent, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return currentURL.path
    }
}
