import CoreData
import Combine

final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    @Published private(set) var isStoreLoaded = false
    @Published private(set) var storeLoadError: NSError?
    private var isLoadingStore = false

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "BookReader")

        if inMemory, let description = container.persistentStoreDescriptions.first {
            description.url = URL(fileURLWithPath: "/dev/null")
        }

        // 配置轻量级自动迁移，支持模型版本升级
        let description = container.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        loadPersistentStores()
    }

    /// 持久化存储加载失败时允许界面重试，而不是让应用直接崩溃。
    func retryLoadingPersistentStore() {
        guard !isLoadingStore else { return }
        storeLoadError = nil
        isStoreLoaded = false
        loadPersistentStores()
    }

    private func loadPersistentStores() {
        guard !isLoadingStore else { return }
        isLoadingStore = true

        container.loadPersistentStores { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingStore = false
                if let error = error as NSError? {
                    self.storeLoadError = error
                    self.isStoreLoaded = false
                } else {
                    self.storeLoadError = nil
                    self.isStoreLoaded = true
                }
            }
        }
    }
    
    func save() {
        guard storeLoadError == nil else { return }
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                print("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }
}
