import Foundation
import Combine
import UIKit

/// 阅读时长追踪器
@MainActor
final class ReadingTimeTracker: NSObject, ObservableObject {
    static let shared = ReadingTimeTracker()

    private var startTime: Date?
    private var bookId: UUID?
    private var bookTitle: String?
    private var timer: Timer?
    private let repository: ReadingStatsRepositoryProtocol
    private let now: () -> Date
    private let minimumSessionDuration: TimeInterval
    private let notificationCenter: NotificationCenter
    private var lifecycleCancellables = Set<AnyCancellable>()
    private var saveCancellables = Set<AnyCancellable>()
    
    /// 当前阅读时长（实时更新）
    @Published var currentReadingTime: TimeInterval = 0
    
    /// 是否正在阅读
    var isReading: Bool {
        return startTime != nil
    }
    
    init(
        repository: ReadingStatsRepositoryProtocol = ReadingStatsRepository(),
        now: @escaping () -> Date = Date.init,
        minimumSessionDuration: TimeInterval = 5,
        notificationCenter: NotificationCenter = .default
    ) {
        self.repository = repository
        self.now = now
        self.minimumSessionDuration = minimumSessionDuration
        self.notificationCenter = notificationCenter
        super.init()
        observeApplicationLifecycle()
    }
    
    /// 开始阅读
    func startReading(bookId: UUID, bookTitle: String) {
        if self.bookId != nil {
            stopReading()
        }

        self.bookId = bookId
        self.bookTitle = bookTitle
        self.startTime = now()
        self.currentReadingTime = 0
        startTimer()
    }

    private func observeApplicationLifecycle() {
        notificationCenter.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pauseReading()
            }
            .store(in: &lifecycleCancellables)

        notificationCenter.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resumeReading()
            }
            .store(in: &lifecycleCancellables)

        notificationCenter.publisher(for: UIApplication.willTerminateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.stopReading()
            }
            .store(in: &lifecycleCancellables)
    }
    
    /// 停止阅读并保存会话
    func stopReading() {
        timer?.invalidate()
        timer = nil

        if let startTime,
           let bookId,
           let bookTitle {
            saveSessionIfNeeded(
                bookId: bookId,
                bookTitle: bookTitle,
                startTime: startTime,
                endTime: now()
            )
        }

        resetSession()
    }
    
    /// 暂停阅读（应用进入后台时）
    func pauseReading() {
        guard let startTime = startTime,
              let bookId = bookId,
              let bookTitle = bookTitle else {
            return
        }

        saveSessionIfNeeded(
            bookId: bookId,
            bookTitle: bookTitle,
            startTime: startTime,
            endTime: now()
        )
        self.startTime = nil
        timer?.invalidate()
        timer = nil
    }
    
    /// 恢复阅读（应用回到前台时）
    func resumeReading() {
        guard bookId != nil, bookTitle != nil, startTime == nil else { return }

        self.startTime = now()
        self.currentReadingTime = 0
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(updateReadingTime), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func updateReadingTime() {
        guard let startTime else { return }
        currentReadingTime = now().timeIntervalSince(startTime)
    }

    private func saveSessionIfNeeded(
        bookId: UUID,
        bookTitle: String,
        startTime: Date,
        endTime: Date
    ) {
        guard endTime.timeIntervalSince(startTime) >= minimumSessionDuration else { return }
        let session = ReadingSession(
            bookId: bookId,
            bookTitle: bookTitle,
            startTime: startTime,
            endTime: endTime
        )

        repository.saveReadingSession(session)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &saveCancellables)
    }

    private func resetSession() {
        startTime = nil
        bookId = nil
        bookTitle = nil
        currentReadingTime = 0
        timer?.invalidate()
        timer = nil
    }
}
