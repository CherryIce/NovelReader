import SwiftUI
import Foundation

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text("书架")
                    }
                }
            
            BookSearchView()
                .tabItem {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("搜索")
                    }
                }

            ReadingStatsView()
                .tabItem {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                        Text("统计")
                    }
                }
            
            ReaderSettingsView(showsDoneButton: false)
                .tabItem {
                    HStack {
                        Image(systemName: "gear")
                        Text("设置")
                    }
                }
        }
    }
}

struct BookSearchView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var selectedBook: Book?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                SearchBar(text: $viewModel.searchQuery)
                    .padding()

                if viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("输入书名或作者进行搜索")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.books.isEmpty {
                    Text("未找到相关书籍")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.books) { book in
                        Button(action: {
                            selectedBook = book
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(book.title)
                                        .foregroundColor(.primary)
                                    if let author = book.author, !author.isEmpty {
                                        Text(author)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if book.isFavorite {
                                    Image(systemName: "heart.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarTitle("搜索", displayMode: .inline)
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .alert(item: $viewModel.error) { error in
                Alert(
                    title: Text("错误"),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text("确定"))
                )
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
