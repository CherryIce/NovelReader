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
        
        let statsPublisher = repository.getAllBookStats()
        let summaryPublisher = repository.getReadingStatsSummary()
        
        Publishers.Zip(statsPublisher, summaryPublisher)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isLoading = false
                    if case .failure(let error) = completion {
                        self?.error = error
                    }
                },
                receiveValue: { [weak self] stats, summary in
                    self?.bookStats = stats
                    self?.summary = summary
                }
            )
            .store(in: &cancellables)
    }
    
    /// 刷新数据
    func refresh() {
        loadStats()
    }
}
