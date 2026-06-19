import SwiftUI

struct ReadingStatsView: View {
    @StateObject private var viewModel = ReadingStatsViewModel()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 统计摘要头部
                    statsHeader
                    
                    // 书籍阅读时长列表
                    bookStatsList
                }
                .padding(.vertical)
            }
            .navigationTitle("阅读统计")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                viewModel.refresh()
            }
            .onAppear {
                viewModel.loadStats()
            }
        }
    }
    
    // MARK: - 统计摘要头部
    
    private var statsHeader: some View {
        VStack(spacing: 16) {
            // 总阅读时长
            HStack(spacing: 16) {
                StatCard(
                    title: "总阅读时长",
                    value: viewModel.summary.totalReadingTime.readingTimeString,
                    icon: "clock.fill",
                    color: .blue
                )
                
                StatCard(
                    title: "今日阅读",
                    value: viewModel.summary.todayReadingTime.readingTimeString,
                    icon: "sun.max.fill",
                    color: .orange
                )
            }
            .padding(.horizontal)
            
            // 其他统计信息
            HStack(spacing: 16) {
                StatCard(
                    title: "阅读书籍",
                    value: "\(viewModel.summary.totalBooksRead)本",
                    icon: "books.vertical.fill",
                    color: .green
                )
                
                StatCard(
                    title: "连续阅读",
                    value: "\(viewModel.summary.streakDays)天",
                    icon: "flame.fill",
                    color: .red
                )
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - 书籍阅读时长列表
    
    private var bookStatsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("书籍阅读时长")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            if viewModel.bookStats.isEmpty {
                // 空状态
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    
                    Text("暂无阅读记录")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("开始阅读书籍，这里将显示您的阅读统计")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // 书籍列表
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.bookStats) { stat in
                        BookStatRow(stat: stat)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - 统计卡片

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - 书籍统计行

struct BookStatRow: View {
    let stat: BookReadingStats
    
    var body: some View {
        HStack(spacing: 12) {
            // 书籍图标
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 50, height: 50)
                
                Image(systemName: "book.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            
            // 书籍信息
            VStack(alignment: .leading, spacing: 4) {
                Text(stat.bookTitle)
                    .font(.headline)
                    .lineLimit(1)
                
                Text("阅读时长: \(stat.totalReadingTime.readingTimeString)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let lastReadAt = stat.lastReadAt {
                    Text("最近阅读: \(lastReadAt.formattedRelativeTime)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 时长标签
            Text(stat.totalReadingTime.shortReadingTimeString)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue)
                .cornerRadius(8)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - 日期格式化扩展

extension Date {
    var formattedRelativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - 预览

struct ReadingStatsView_Previews: PreviewProvider {
    static var previews: some View {
        ReadingStatsView()
    }
}
