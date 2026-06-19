import Foundation
import Combine

/// 阅读时长追踪器
class ReadingTimeTracker {
    static let shared = ReadingTimeTracker()
    
    private var currentSession: ReadingSession?
    private var startTime: Date?
    private var bookId: UUID?
    private var bookTitle: String?
    private var timer: Timer?
    private let repository: ReadingStatsRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()
    
    /// 当前阅读时长（实时更新）
    @Published var currentReadingTime: TimeInterval = 0
    
    /// 是否正在阅读
    var isReading: Bool {
        return startTime != nil
    }
    
    private init(repository: ReadingStatsRepositoryProtocol = ReadingStatsRepository()) {
        self.repository = repository
    }
    
    /// 开始阅读
    func startReading(bookId: UUID, bookTitle: String) {
        // 如果已经在阅读，先结束当前会话
        if isReading {
            stopReading()
        }
        
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.startTime = Date()
        self.currentReadingTime = 0
        
        // 启动定时器，每秒更新当前阅读时长
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.currentReadingTime = Date().timeIntervalSince(startTime)
        }
        
        // 监听应用进入后台通知
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.pauseReading()
            }
            .store(in: &cancellables)
        
        // 监听应用回到前台通知
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.resumeReading()
            }
            .store(in: &cancellables)
        
        // 监听应用终止通知
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.stopReading()
            }
            .store(in: &cancellables)
    }
    
    /// 停止阅读并保存会话
    func stopReading() {
        guard let startTime = startTime,
              let bookId = bookId,
              let bookTitle = bookTitle else {
            return
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        // 只有阅读时长超过5秒才记录
        guard duration >= 5 else {
            reset()
            return
        }
        
        let session = ReadingSession(
            bookId: bookId,
            bookTitle: bookTitle,
            startTime: startTime,
            endTime: endTime
        )
        
        repository.saveReadingSession(session)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("保存阅读会话失败: \(error)")
                    }
                },
                receiveValue: { _ in
                    print("阅读会话已保存: \(bookTitle), 时长: \(duration.readingTimeString)")
                }
            )
            .store(in: &cancellables)
        
        reset()
    }
    
    /// 暂停阅读（应用进入后台时）
    private func pauseReading() {
        // 保存当前会话
        guard let startTime = startTime,
              let bookId = bookId,
              let bookTitle = bookTitle else {
            return
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        guard duration >= 5 else {
            return
        }
        
        let session = ReadingSession(
            bookId: bookId,
            bookTitle: bookTitle,
            startTime: startTime,
            endTime: endTime
        )
        
        repository.saveReadingSession(session)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
        
        // 记录暂停时间，用于恢复时计算
        self.startTime = nil
        timer?.invalidate()
        timer = nil
    }
    
    /// 恢复阅读（应用回到前台时）
    private func resumeReading() {
        guard let bookId = bookId, let bookTitle = bookTitle else { return }
        
        // 开始新的会话
        self.startTime = Date()
        self.currentReadingTime = 0
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.currentReadingTime = Date().timeIntervalSince(startTime)
        }
    }
    
    /// 重置状态
    private func reset() {
        startTime = nil
        bookId = nil
        bookTitle = nil
        currentReadingTime = 0
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
    }
}
