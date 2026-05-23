import SwiftUI

struct CatalogView: View {
    let chapters: [Chapter]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    ChapterRow(
                        chapter: chapter,
                        isCurrent: index == currentIndex
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(index)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationBarTitle("目录", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    let isCurrent: Bool
    
    var body: some View {
        HStack {
            Text(chapter.title)
                .font(.body)
                .foregroundColor(isCurrent ? .blue : .primary)
            
            Spacer()
            
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
        .background(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
    }
}

struct CatalogView_Previews: PreviewProvider {
    static var previews: some View {
        CatalogView(
            chapters: [
                Chapter(index: 0, title: "第一章", content: ""),
                Chapter(index: 1, title: "第二章", content: ""),
                Chapter(index: 2, title: "第三章", content: "")
            ],
            currentIndex: 0,
            onSelect: { _ in }
        )
    }
}
