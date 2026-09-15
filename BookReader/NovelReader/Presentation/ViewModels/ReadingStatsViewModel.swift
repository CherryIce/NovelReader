import Foundation
import Combine

/// 阅读统计视图模型
class ReadingStatsViewModel: ObservableObject {
    @Published var bookStats: [BookReadingStats] = []
    @Published var summary: ReadingStatsSummary = ReadingStatsSummary()
    @Published var isLoading: Bool = false
    @Published var error: Error?
    
    private let repository: ReadingStatsRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()
    
    init(repository: ReadingStatsRepositoryProtocol = ReadingStatsRepository()) {
        self.repository = repository
    }
    
    /// 加载所有统计数据
    func loadStats() {
        isLoading = true
        error = nil
        
        repository.getDashboardStats()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isLoading = false
                    if case .failure(let error) = completion {
                        self?.error = error
                    }
                },
                receiveValue: { [weak self] dashboard in
                    self?.bookStats = dashboard.bookStats
                    self?.summary = dashboard.summary
                }
            )
            .store(in: &cancellables)
    }
    
    /// 刷新数据
    func refresh() {
        loadStats()
    }
}
