import Foundation

/// 章节实体
struct Chapter: Identifiable, Codable, Equatable {
    let id: UUID
    var index: Int
    var title: String
    var content: String
    var startLocation: Int // 在全文的起始位置
    var length: Int // 章节字符数
    
    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        content: String = "",
        startLocation: Int = 0,
        length: Int = 0
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.content = content
        self.startLocation = startLocation
        self.length = length
    }
    
    /// 章节结束位置
    var endLocation: Int {
        return startLocation + length
    }
}

extension Chapter {
    /// 示例章节
    static var sample: Chapter {
        Chapter(
            index: 0,
            title: "第一章 开始",
            content: "这是第一章的内容...",
            startLocation: 0,
            length: 1000
        )
    }
}
